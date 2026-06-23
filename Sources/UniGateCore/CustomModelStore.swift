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

public struct CustomModelState: Codable, Sendable {
    public var models: [CustomModelDefinition]

    public init(models: [CustomModelDefinition] = []) {
        self.models = models
    }

    public static func targetID(for candidate: ModelCandidate) -> String {
        "\(candidate.routeKey.description)|\(candidate.providerRef.description)"
    }

    public static func targetID(for target: CustomModelTarget) -> String {
        "\(target.routeKey.description)|\(target.providerRef.description)"
    }

    public func definition(for routeKey: ModelRouteKey) -> CustomModelDefinition? {
        models.first {
            $0.appType == routeKey.appType && $0.name == routeKey.logicalModel
        }
    }

    public func baseCandidates(
        from catalog: ProviderCatalog,
        preserving targets: [CustomModelTarget] = []
    ) -> [ModelCandidate] {
        let customRouteKeys = Set(models.map {
            ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
        })
        let baseCandidates = catalog.candidates.filter { candidate in
            candidate.providerRef == candidate.upstreamProviderRef
                && !customRouteKeys.contains(candidate.routeKey)
        }
        return Self.deduplicatedTargetCandidates(
            baseCandidates,
            preservingTargetIDs: Set(targets.map { Self.targetID(for: $0) })
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

        return matchedTargets.map { _, candidate in
            ModelCandidate(
                logicalModel: definition.name,
                providerRef: ProviderRef(appType: definition.appType, id: "\(candidate.providerRef.description)|\(candidate.routeKey.description)"),
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
            return candidate.source == .configured
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
        return try decoder.decode(CustomModelState.self, from: data)
    }

    public func save(_ state: CustomModelState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
