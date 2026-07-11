import Foundation

public struct CustomModelTarget: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var routeKey: ModelRouteKey
    public var providerRef: ProviderRef

    public init(id: UUID = UUID(), routeKey: ModelRouteKey, providerRef: ProviderRef) {
        self.id = id
        self.routeKey = routeKey
        self.providerRef = providerRef
    }
}

public struct CustomModelDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var appType: String
    public var name: String
    public var forceEnabled: Bool
    public var targets: [CustomModelTarget]
    public var selectedTargetID: UUID?

    public init(
        id: UUID = UUID(),
        appType: String,
        name: String,
        forceEnabled: Bool = false,
        targets: [CustomModelTarget] = [],
        selectedTargetID: UUID? = nil
    ) {
        self.id = id
        self.appType = appType
        self.name = name
        self.forceEnabled = forceEnabled
        self.targets = targets
        self.selectedTargetID = selectedTargetID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case appType
        case name
        case forceEnabled
        case targets
        case selectedTargetID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.appType = try container.decode(String.self, forKey: .appType)
        self.name = try container.decode(String.self, forKey: .name)
        self.forceEnabled = try container.decodeIfPresent(Bool.self, forKey: .forceEnabled) ?? false
        self.targets = try container.decodeIfPresent([CustomModelTarget].self, forKey: .targets) ?? []
        self.selectedTargetID = try container.decodeIfPresent(UUID.self, forKey: .selectedTargetID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appType, forKey: .appType)
        try container.encode(name, forKey: .name)
        try container.encode(forceEnabled, forKey: .forceEnabled)
        try container.encode(targets, forKey: .targets)
        try container.encodeIfPresent(selectedTargetID, forKey: .selectedTargetID)
    }

    public var selectedTarget: CustomModelTarget? {
        guard let selectedTargetID else {
            return nil
        }
        return targets.first(where: { $0.id == selectedTargetID })
    }

    public func hasSelectedTarget(in catalog: ProviderCatalog) -> Bool {
        selectedTargetCandidate(in: catalog) != nil
    }

    public func selectedTargetCandidate(in catalog: ProviderCatalog) -> ModelCandidate? {
        guard let selectedTarget else {
            return nil
        }
        return catalog.candidates.first {
            $0.appType == selectedTarget.routeKey.appType
                && $0.logicalModel == selectedTarget.routeKey.logicalModel
                && $0.providerRef == selectedTarget.providerRef
        }
    }
}

public enum CustomModelNameConflict: Sendable, Equatable {
    case baseModel
    case customModel
}

public struct CustomModelState: Codable, Sendable {
    public var models: [CustomModelDefinition]

    public init(models: [CustomModelDefinition] = []) {
        self.models = Self.deduplicatedModels(models)
    }

    private enum CodingKeys: String, CodingKey {
        case models
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let models = try container.decodeIfPresent([CustomModelDefinition].self, forKey: .models) ?? []
        self.models = Self.deduplicatedModels(models)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(models, forKey: .models)
    }

    public func normalized() -> CustomModelState {
        CustomModelState(models: models)
    }

    public static func targetID(for candidate: ModelCandidate) -> String {
        "\(candidate.routeKey.description)|\(candidate.providerRef.description)"
    }

    public static func targetID(for target: CustomModelTarget) -> String {
        "\(target.routeKey.description)|\(target.providerRef.description)"
    }

    public static func syntheticProviderRef(
        appType: String,
        target: CustomModelTarget
    ) -> ProviderRef {
        ProviderRef(
            appType: appType,
            id: "\(target.providerRef.description)|\(target.routeKey.description)"
        )
    }

    public func definition(for routeKey: ModelRouteKey) -> CustomModelDefinition? {
        models.first {
            $0.appType == routeKey.appType && $0.name == routeKey.logicalModel
        }
    }

    public func preferredProviderRefsByRouteKey() -> [String: ProviderRef] {
        Dictionary(uniqueKeysWithValues: models.compactMap { definition in
            guard
                let selectedTargetID = definition.selectedTargetID,
                let target = definition.targets.first(where: { $0.id == selectedTargetID })
            else {
                return nil
            }
            let routeKey = ModelRouteKey(appType: definition.appType, logicalModel: definition.name)
            return (
                routeKey.description,
                Self.syntheticProviderRef(appType: definition.appType, target: target)
            )
        })
    }

    public func preferredProviderRefsByRouteKey(
        availableIn catalog: ProviderCatalog
    ) -> [String: ProviderRef] {
        preferredProviderRefsByRouteKey().filter { key, providerRef in
            guard let routeKey = ModelRouteKey(description: key) else {
                return false
            }
            return catalog.candidates.contains {
                $0.routeKey == routeKey && $0.providerRef == providerRef
            }
        }
    }

    public func nameConflict(
        for definition: CustomModelDefinition,
        in catalog: ProviderCatalog,
        uniGateModelScope: UniGateModelScope
    ) -> CustomModelNameConflict? {
        let routeKey = ModelRouteKey(appType: definition.appType, logicalModel: definition.name)
        if models.contains(where: { existing in
            existing.id != definition.id
                && existing.appType == routeKey.appType
                && existing.name == routeKey.logicalModel
        }) {
            return .customModel
        }
        if catalog.candidates.contains(where: { candidate in
            candidate.routeKey == routeKey
                && candidate.providerRef == candidate.upstreamProviderRef
                && ModelRouteVisibility.isCandidateSelectable(
                    candidate,
                    catalog: catalog,
                    uniGateModelScope: uniGateModelScope
                )
        }) {
            return .baseModel
        }
        return nil
    }

    public func baseCandidates(
        from catalog: ProviderCatalog,
        preserving targets: [CustomModelTarget] = [],
        preservingRouteKeys: Set<ModelRouteKey> = [],
        includeCandidate: (ModelCandidate) -> Bool = { _ in true }
    ) -> [ModelCandidate] {
        let preservingTargetIDs = Set(targets.map { Self.targetID(for: $0) })
        let baseCandidates = catalog.candidates.filter { candidate in
            let shouldPreserve = preservingTargetIDs.contains(Self.targetID(for: candidate))
                || preservingRouteKeys.contains(candidate.routeKey)
            guard includeCandidate(candidate) || shouldPreserve else {
                return false
            }
            return candidate.providerRef == candidate.upstreamProviderRef
        }
        return Self.deduplicatedTargetCandidates(
            baseCandidates,
            preservingTargetIDs: preservingTargetIDs
        )
    }

    public func expandedCandidates(from catalog: ProviderCatalog) -> [ModelCandidate] {
        models.flatMap { definition in
            expandedCandidates(for: definition, from: catalog)
        }
    }

    public func expandedCandidates(
        for definition: CustomModelDefinition,
        from catalog: ProviderCatalog
    ) -> [ModelCandidate] {
        let preferredTargetID = definition.selectedTarget?.id
        var matchedTargets: [(CustomModelTarget, ModelCandidate)] = []

        for target in definition.targets where target.routeKey.appType == definition.appType {
            guard let candidate = catalog.candidates.first(where: {
                $0.appType == target.routeKey.appType
                    && $0.logicalModel == target.routeKey.logicalModel
                    && $0.providerRef == target.providerRef
            }) else {
                continue
            }
            matchedTargets.append((target, candidate))
        }

        if let preferredTargetID,
           let index = matchedTargets.firstIndex(where: { $0.0.id == preferredTargetID }) {
            let preferred = matchedTargets.remove(at: index)
            matchedTargets.insert(preferred, at: 0)
        }

        return matchedTargets.map { target, candidate in
            ModelCandidate(
                logicalModel: definition.name,
                providerRef: Self.syntheticProviderRef(appType: definition.appType, target: target),
                providerName: candidate.providerName,
                appType: definition.appType,
                clientProtocol: candidate.clientProtocol,
                apiFormat: candidate.apiFormat,
                upstreamModel: candidate.upstreamModel,
                baseURL: candidate.baseURL,
                requiresTransform: candidate.requiresTransform,
                label: candidate.logicalModel,
                supportsLongContext: candidate.supportsLongContext,
                upstreamProviderRef: candidate.providerRef,
                source: candidate.source
            )
        }
    }

    public func displayCandidates(
        for definition: CustomModelDefinition,
        from catalog: ProviderCatalog
    ) -> [ModelCandidate] {
        var candidates = expandedCandidates(for: definition, from: catalog)
        let candidateProviderRefs = Set(candidates.map(\.providerRef))
        let missingTargets = definition.targets
            .filter { $0.routeKey.appType == definition.appType }
            .compactMap { target -> ModelCandidate? in
                let providerRef = Self.syntheticProviderRef(appType: definition.appType, target: target)
                guard !candidateProviderRefs.contains(providerRef) else {
                    return nil
                }
                return missingTargetCandidate(definition: definition, target: target, catalog: catalog)
            }
        candidates.append(contentsOf: missingTargets)
        return candidates
    }

    public static func deduplicatedTargetCandidates(
        _ candidates: [ModelCandidate],
        preservingTargetIDs: Set<String> = []
    ) -> [ModelCandidate] {
        var orderedKeys: [ModelCandidateTargetIdentity] = []
        var candidatesByKey: [ModelCandidateTargetIdentity: ModelCandidate] = [:]

        for candidate in candidates {
            let key = ModelCandidateTargetIdentity(candidate: candidate)
            if let existing = candidatesByKey[key] {
                if shouldPrefer(
                    candidate,
                    over: existing,
                    preservingTargetIDs: preservingTargetIDs
                ) {
                    candidatesByKey[key] = candidate
                }
            } else {
                orderedKeys.append(key)
                candidatesByKey[key] = candidate
            }
        }

        return orderedKeys.compactMap { candidatesByKey[$0] }
    }

    private static func shouldPrefer(
        _ candidate: ModelCandidate,
        over existing: ModelCandidate,
        preservingTargetIDs: Set<String>
    ) -> Bool {
        let candidateIsPreserved = preservingTargetIDs.contains(targetID(for: candidate))
        let existingIsPreserved = preservingTargetIDs.contains(targetID(for: existing))
        if candidateIsPreserved != existingIsPreserved {
            return candidateIsPreserved
        }
        if candidate.source != existing.source {
            return sourcePriority(candidate.source) < sourcePriority(existing.source)
        }
        if candidate.supportsLongContext != existing.supportsLongContext {
            return candidate.supportsLongContext
        }

        let candidateRank = ClaudeRouteRole.rank(for: candidate.routeKey)
        let existingRank = ClaudeRouteRole.rank(for: existing.routeKey)
        if candidateRank != existingRank {
            return candidateRank < existingRank
        }

        return candidate.logicalModel.localizedStandardCompare(existing.logicalModel) == .orderedAscending
    }

    private static func sourcePriority(_ source: ModelCandidateSource) -> Int {
        switch source {
        case .configured:
            return 0
        case .custom:
            return 1
        case .discovered:
            return 2
        case .staleDiscovered:
            return 3
        }
    }

    private func missingTargetCandidate(
        definition: CustomModelDefinition,
        target: CustomModelTarget,
        catalog: ProviderCatalog
    ) -> ModelCandidate {
        let provider = catalog.providers.first(where: { $0.ref == target.providerRef })
        let apiFormat = provider?.apiFormat ?? .unknown
        return ModelCandidate(
            logicalModel: definition.name,
            providerRef: Self.syntheticProviderRef(appType: definition.appType, target: target),
            providerName: provider?.name ?? target.providerRef.description,
            appType: definition.appType,
            clientProtocol: clientProtocol(for: target.routeKey.appType),
            apiFormat: apiFormat,
            upstreamModel: target.routeKey.logicalModel,
            baseURL: provider?.baseURL,
            requiresTransform: requiresTransform(appType: target.routeKey.appType, apiFormat: apiFormat),
            label: target.routeKey.logicalModel,
            supportsLongContext: false,
            upstreamProviderRef: target.providerRef,
            source: .staleDiscovered
        )
    }

    private func clientProtocol(for appType: String) -> ClientProtocolKind {
        switch appType {
        case "gemini":
            return .geminiNative
        default:
            return UniGateAppRegistry.clientProtocol(for: appType) ?? .openaiChat
        }
    }

    private func requiresTransform(appType: String, apiFormat: ApiFormat) -> Bool {
        switch appType {
        case "gemini":
            return apiFormat != .geminiNative
        default:
            return UniGateAppRegistry.requiresTransform(appType: appType, apiFormat: apiFormat) ?? false
        }
    }

    private static func deduplicatedModels(_ models: [CustomModelDefinition]) -> [CustomModelDefinition] {
        var seen: Set<ModelRouteKey> = []
        var result: [CustomModelDefinition] = []
        for definition in models.reversed() {
            let routeKey = ModelRouteKey(appType: definition.appType, logicalModel: definition.name)
            guard !seen.contains(routeKey) else {
                continue
            }
            seen.insert(routeKey)
            result.insert(definition, at: 0)
        }
        return result
    }
}

public final class CustomModelStore: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = CustomModelStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultFileURL() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("custom-models.json", isDirectory: false)
    }

    public func load() throws -> CustomModelState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CustomModelState()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(CustomModelState.self, from: data).normalized()
    }

    public func save(_ state: CustomModelState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state.normalized())
        try data.write(to: fileURL, options: .atomic)
    }
}
