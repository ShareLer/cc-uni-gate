import Foundation

public enum CodexRouteTargetMode: String, Codable, Sendable {
    case automaticSameName
    case explicit
}

public struct CodexVisibilityMigrationState: Codable, Equatable, Sendable {
    public var legacyVisibleModels: Set<String>
    public var pendingProviderRefs: Set<ProviderRef>
    public var migratedRouteKeys: Set<ModelRouteKey>

    public init(
        legacyVisibleModels: Set<String>,
        pendingProviderRefs: Set<ProviderRef>,
        migratedRouteKeys: Set<ModelRouteKey> = []
    ) {
        self.legacyVisibleModels = legacyVisibleModels
        self.pendingProviderRefs = pendingProviderRefs
        self.migratedRouteKeys = migratedRouteKeys
    }
}

public struct CodexModelRoutePolicy: Codable, Hashable, Identifiable, Sendable {
    public var routeKey: ModelRouteKey
    public var targetMode: CodexRouteTargetMode
    public var targets: [CustomModelTarget]
    public var selectedTargetID: UUID?
    public var isDisabled: Bool

    public var id: String {
        routeKey.description
    }

    public init(
        routeKey: ModelRouteKey,
        targetMode: CodexRouteTargetMode = .automaticSameName,
        targets: [CustomModelTarget] = [],
        selectedTargetID: UUID? = nil,
        isDisabled: Bool = false
    ) {
        self.routeKey = routeKey
        self.targetMode = targetMode
        self.targets = targets
        self.selectedTargetID = selectedTargetID
        self.isDisabled = isDisabled
    }

    public var selectedTarget: CustomModelTarget? {
        guard let selectedTargetID else {
            return nil
        }
        return targets.first { $0.id == selectedTargetID }
    }
}

public extension CustomModelState {
    func codexRoutePolicy(for routeKey: ModelRouteKey) -> CodexModelRoutePolicy? {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return nil
        }
        return codexRoutePolicies.first { $0.routeKey == routeKey }
    }

    func isCodexRouteDisabled(
        _ routeKey: ModelRouteKey,
        pinnedScope: UniGateModelScope
    ) -> Bool {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return false
        }
        if pinnedScope.contains(routeKey) {
            return false
        }
        return codexRoutePolicy(for: routeKey)?.isDisabled == true
    }

    mutating func setCodexRouteDisabled(_ isDisabled: Bool, routeKey: ModelRouteKey) {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return
        }
        var policy = codexRoutePolicy(for: routeKey)
            ?? CodexModelRoutePolicy(routeKey: routeKey)
        policy.isDisabled = isDisabled
        replaceCodexRoutePolicy(policy)
    }

    mutating func setCodexExplicitRoute(
        routeKey: ModelRouteKey,
        targets: [CustomModelTarget],
        selectedTargetID: UUID?
    ) {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return
        }
        var policy = codexRoutePolicy(for: routeKey)
            ?? CodexModelRoutePolicy(routeKey: routeKey)
        policy.targetMode = .explicit
        policy.targets = targets.filter { $0.routeKey.appType == UniGateAppRegistry.codex }
        policy.selectedTargetID = selectedTargetID.flatMap { selectedID in
            policy.targets.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        replaceCodexRoutePolicy(policy)
    }

    mutating func restoreCodexAutomaticRoute(routeKey: ModelRouteKey) {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return
        }
        var policy = codexRoutePolicy(for: routeKey)
            ?? CodexModelRoutePolicy(routeKey: routeKey)
        policy.targetMode = .automaticSameName
        policy.targets = []
        policy.selectedTargetID = nil
        replaceCodexRoutePolicy(policy)
    }

    mutating func removeCodexRoutePolicy(routeKey: ModelRouteKey) {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return
        }
        codexRoutePolicies.removeAll { $0.routeKey == routeKey }
    }

    mutating func migrateLegacyCodexVisibility(
        visibleModels: Set<String>?,
        catalog: ProviderCatalog,
        readyProviderRefs: Set<ProviderRef>,
        pinnedScope: UniGateModelScope
    ) -> Bool {
        guard !codexVisibilityMigrated else {
            return false
        }
        guard let visibleModels else {
            codexVisibilityMigrated = true
            codexVisibilityMigration = nil
            return true
        }

        let currentProviderRefs = Set(catalog.providers.compactMap { provider -> ProviderRef? in
            provider.appType == UniGateAppRegistry.codex ? provider.ref : nil
        })
        let existingCustomRouteKeys = Set(models.compactMap { definition -> ModelRouteKey? in
            guard definition.appType == UniGateAppRegistry.codex else {
                return nil
            }
            return ModelRouteKey(appType: definition.appType, logicalModel: definition.name)
        })

        let isInitializing = codexVisibilityMigration == nil
        var migration = codexVisibilityMigration ?? CodexVisibilityMigrationState(
            legacyVisibleModels: visibleModels,
            pendingProviderRefs: currentProviderRefs
        )
        var didChange = isInitializing

        let retainedPendingProviderRefs = migration.pendingProviderRefs.intersection(currentProviderRefs)
        if retainedPendingProviderRefs != migration.pendingProviderRefs {
            migration.pendingProviderRefs = retainedPendingProviderRefs
            didChange = true
        }

        var routeKeysToMigrate = Set(catalog.candidates.compactMap { candidate -> ModelRouteKey? in
            guard candidate.appType == UniGateAppRegistry.codex,
                  candidate.providerRef == candidate.upstreamProviderRef,
                  migration.pendingProviderRefs.contains(candidate.providerRef) else {
                return nil
            }
            return candidate.routeKey
        })
        if isInitializing {
            routeKeysToMigrate.formUnion(existingCustomRouteKeys)
        }

        var routeKeysToDisable: [ModelRouteKey] = []
        for routeKey in routeKeysToMigrate where !migration.migratedRouteKeys.contains(routeKey) {
            migration.migratedRouteKeys.insert(routeKey)
            didChange = true
            let wasVisible = migration.legacyVisibleModels.contains(routeKey.description)
                || migration.legacyVisibleModels.contains(routeKey.logicalModel)
            if !wasVisible,
               !pinnedScope.contains(routeKey),
               codexRoutePolicy(for: routeKey) == nil {
                routeKeysToDisable.append(routeKey)
            }
        }

        let completedProviderRefs = migration.pendingProviderRefs.intersection(readyProviderRefs)
        if !completedProviderRefs.isEmpty {
            migration.pendingProviderRefs.subtract(completedProviderRefs)
            didChange = true
        }

        if migration.pendingProviderRefs.isEmpty {
            codexVisibilityMigrated = true
            codexVisibilityMigration = nil
        } else {
            codexVisibilityMigration = migration
        }
        for routeKey in routeKeysToDisable {
            setCodexRouteDisabled(true, routeKey: routeKey)
        }
        return didChange || !routeKeysToDisable.isEmpty
    }

    func codexDisplayCandidates(
        for routeKey: ModelRouteKey,
        from catalog: ProviderCatalog
    ) -> [ModelCandidate] {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return []
        }
        guard let policy = codexRoutePolicy(for: routeKey), policy.targetMode == .explicit else {
            return codexAutomaticCandidates(for: routeKey, from: catalog, includeStale: true)
        }
        return codexExpandedCandidates(for: policy, from: catalog, includeMissing: true, includeStale: true)
    }

    func codexRoutingCandidates(
        for routeKey: ModelRouteKey,
        from catalog: ProviderCatalog
    ) -> [ModelCandidate] {
        guard routeKey.appType == UniGateAppRegistry.codex else {
            return []
        }
        guard let policy = codexRoutePolicy(for: routeKey), policy.targetMode == .explicit else {
            return codexAutomaticCandidates(for: routeKey, from: catalog, includeStale: false)
        }
        return codexExpandedCandidates(for: policy, from: catalog, includeMissing: false, includeStale: false)
    }

    private mutating func replaceCodexRoutePolicy(_ policy: CodexModelRoutePolicy) {
        codexRoutePolicies.removeAll { $0.routeKey == policy.routeKey }
        if policy.targetMode == .explicit || policy.isDisabled {
            codexRoutePolicies.append(policy)
        }
        self = normalized()
    }

    private func codexAutomaticCandidates(
        for routeKey: ModelRouteKey,
        from catalog: ProviderCatalog,
        includeStale: Bool
    ) -> [ModelCandidate] {
        let candidates = catalog.candidates.filter { candidate in
            candidate.appType == UniGateAppRegistry.codex
                && candidate.routeKey == routeKey
                && candidate.providerRef == candidate.upstreamProviderRef
                && (includeStale || candidate.source != .staleDiscovered)
        }
        return Self.deduplicatedTargetCandidates(candidates, preferLongContext: true)
    }

    private func codexExpandedCandidates(
        for policy: CodexModelRoutePolicy,
        from catalog: ProviderCatalog,
        includeMissing: Bool,
        includeStale: Bool
    ) -> [ModelCandidate] {
        var matchedTargets: [(CustomModelTarget, ModelCandidate)] = []
        var missingTargets: [CustomModelTarget] = []
        let availableCandidates = Self.deduplicatedTargetCandidates(
            catalog.candidates.filter {
                $0.appType == UniGateAppRegistry.codex
                    && $0.providerRef == $0.upstreamProviderRef
                    && (includeStale || $0.source != .staleDiscovered)
            },
            preferLongContext: true
        )

        for target in policy.targets where target.routeKey.appType == UniGateAppRegistry.codex {
            guard let candidate = availableCandidates.first(where: {
                $0.routeKey == target.routeKey
                    && $0.providerRef == target.providerRef
            }) else {
                missingTargets.append(target)
                continue
            }
            matchedTargets.append((target, candidate))
        }

        if let selectedTargetID = policy.selectedTargetID,
           let index = matchedTargets.firstIndex(where: { $0.0.id == selectedTargetID }) {
            let selected = matchedTargets.remove(at: index)
            matchedTargets.insert(selected, at: 0)
        }

        var candidates = matchedTargets.map { target, candidate in
            codexSyntheticCandidate(routeKey: policy.routeKey, target: target, candidate: candidate)
        }
        if includeMissing {
            candidates.append(contentsOf: missingTargets.map {
                codexMissingTargetCandidate(routeKey: policy.routeKey, target: $0, catalog: catalog)
            })
        }
        return Self.deduplicatedTargetCandidates(candidates, preferLongContext: true)
    }

    private func codexSyntheticCandidate(
        routeKey: ModelRouteKey,
        target: CustomModelTarget,
        candidate: ModelCandidate
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: Self.syntheticProviderRef(appType: UniGateAppRegistry.codex, target: target),
            providerName: candidate.providerName,
            appType: UniGateAppRegistry.codex,
            clientProtocol: .codexResponses,
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

    private func codexMissingTargetCandidate(
        routeKey: ModelRouteKey,
        target: CustomModelTarget,
        catalog: ProviderCatalog
    ) -> ModelCandidate {
        let provider = catalog.providers.first { $0.ref == target.providerRef }
        let apiFormat = provider?.apiFormat ?? .unknown
        return ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: Self.syntheticProviderRef(appType: UniGateAppRegistry.codex, target: target),
            providerName: provider?.name ?? target.providerRef.description,
            appType: UniGateAppRegistry.codex,
            clientProtocol: .codexResponses,
            apiFormat: apiFormat,
            upstreamModel: target.routeKey.logicalModel,
            baseURL: provider?.baseURL,
            requiresTransform: UniGateAppRegistry.requiresTransform(
                appType: UniGateAppRegistry.codex,
                apiFormat: apiFormat
            ) ?? false,
            label: target.routeKey.logicalModel,
            supportsLongContext: ModelNameNormalizer.hasOneMMarker(target.routeKey.logicalModel),
            upstreamProviderRef: target.providerRef,
            source: .staleDiscovered
        )
    }
}
