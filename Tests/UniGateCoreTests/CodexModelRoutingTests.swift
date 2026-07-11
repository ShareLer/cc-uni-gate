import UniGateCore
import Foundation
import Testing

struct CodexModelRoutingTests {
    @Test
    func allCodexDiscoveredModelsSeedRoutesWithoutOfficialProvider() {
        let firstProvider = provider(id: "first", name: "First Provider")
        let secondProvider = provider(id: "second", name: "Second Provider")
        let catalog = ProviderCatalog(
            providers: [firstProvider, secondProvider],
            candidates: [
                candidate(provider: firstProvider, model: "gpt-5.6-luna"),
                candidate(provider: secondProvider, model: "gpt-5.6-sol")
            ]
        )

        let routeKeys = ModelRouteVisibility.configuredBaseRouteKeys(
            catalog: catalog,
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope()
        )
        let scoped = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: CustomModelState()
        )

        #expect(routeKeys.map(\.description) == [
            "codex:gpt-5.6-luna",
            "codex:gpt-5.6-sol"
        ])
        #expect(scoped.routeKeys.map(\.description) == routeKeys.map(\.description))
    }

    @Test
    func automaticSameNameAggregatesOfficialAndThirdPartyTargets() {
        let official = provider(
            id: "official",
            name: "Codex Official",
            backendKind: .codexOfficial
        )
        let thirdParty = provider(id: "ahoo-gpt", name: "ahoo-gpt")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.6-luna")
        let catalog = ProviderCatalog(
            providers: [official, thirdParty],
            candidates: [
                candidate(provider: official, model: routeKey.logicalModel),
                candidate(provider: thirdParty, model: routeKey.logicalModel)
            ]
        )
        let state = CustomModelState()

        let candidates = state.codexRoutingCandidates(for: routeKey, from: catalog)
        let scoped = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: state
        )

        #expect(Set(candidates.map(\.providerRef)) == [official.ref, thirdParty.ref])
        #expect(Set(scoped.candidates(for: routeKey).map(\.providerRef)) == [official.ref, thirdParty.ref])
        #expect(candidates.allSatisfy { $0.upstreamModel == routeKey.logicalModel })
    }

    @Test
    func explicitRouteRemovesSameNameTargetAndAddsCrossModelTarget() {
        let official = provider(
            id: "official",
            name: "Codex Official",
            backendKind: .codexOfficial
        )
        let thirdParty = provider(id: "ahoo-gpt", name: "ahoo-gpt")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let officialSameName = candidate(provider: official, model: routeKey.logicalModel)
        let thirdPartySameName = candidate(provider: thirdParty, model: routeKey.logicalModel)
        let thirdPartyCrossModel = candidate(provider: thirdParty, model: "gpt-5.6-sol")
        let catalog = ProviderCatalog(
            providers: [official, thirdParty],
            candidates: [officialSameName, thirdPartySameName, thirdPartyCrossModel]
        )
        let officialTarget = CustomModelTarget(
            routeKey: officialSameName.routeKey,
            providerRef: official.ref
        )
        let crossModelTarget = CustomModelTarget(
            routeKey: thirdPartyCrossModel.routeKey,
            providerRef: thirdParty.ref
        )
        var state = CustomModelState()
        state.setCodexExplicitRoute(
            routeKey: routeKey,
            targets: [officialTarget, crossModelTarget],
            selectedTargetID: crossModelTarget.id
        )

        let candidates = state.codexRoutingCandidates(for: routeKey, from: catalog)

        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.upstreamModel)) == ["gpt-5.5", "gpt-5.6-sol"])
        #expect(candidates.allSatisfy { $0.routeKey == routeKey })
        #expect(!candidates.contains {
            $0.upstreamProviderRef == thirdParty.ref && $0.upstreamModel == "gpt-5.5"
        })
        #expect(candidates.first?.upstreamModel == "gpt-5.6-sol")
    }

    @Test
    func explicitTargetsDistinguishDifferentUpstreamModelsOnSameProvider() {
        let thirdParty = provider(id: "ahoo-gpt", name: "ahoo-gpt")
        let fast = candidate(provider: thirdParty, model: "gpt-5.5-fast")
        let pro = candidate(provider: thirdParty, model: "gpt-5.5-pro")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let fastTarget = CustomModelTarget(routeKey: fast.routeKey, providerRef: thirdParty.ref)
        let proTarget = CustomModelTarget(routeKey: pro.routeKey, providerRef: thirdParty.ref)
        let catalog = ProviderCatalog(
            providers: [thirdParty],
            candidates: [fast, pro]
        )
        var state = CustomModelState()
        state.setCodexExplicitRoute(
            routeKey: routeKey,
            targets: [fastTarget, proTarget],
            selectedTargetID: proTarget.id
        )

        let candidates = state.codexRoutingCandidates(for: routeKey, from: catalog)

        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.providerRef)).count == 2)
        #expect(Set(candidates.map(\.upstreamProviderRef)) == [thirdParty.ref])
        #expect(Set(candidates.map(\.upstreamModel)) == ["gpt-5.5-fast", "gpt-5.5-pro"])
        #expect(
            state.preferredProviderRefsByRouteKey()[routeKey.description]
                == CustomModelState.syntheticProviderRef(appType: "codex", target: proTarget)
        )
    }

    @Test
    func restoringAutomaticRouteDropsExplicitTargetsAndRejoinsSameNameProviders() {
        let firstProvider = provider(id: "first", name: "First Provider")
        let secondProvider = provider(id: "second", name: "Second Provider")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let firstSameName = candidate(provider: firstProvider, model: routeKey.logicalModel)
        let secondSameName = candidate(provider: secondProvider, model: routeKey.logicalModel)
        let crossModel = candidate(provider: secondProvider, model: "gpt-5.6-sol")
        let catalog = ProviderCatalog(
            providers: [firstProvider, secondProvider],
            candidates: [firstSameName, secondSameName, crossModel]
        )
        let crossModelTarget = CustomModelTarget(
            routeKey: crossModel.routeKey,
            providerRef: secondProvider.ref
        )
        var state = CustomModelState()
        state.setCodexExplicitRoute(
            routeKey: routeKey,
            targets: [crossModelTarget],
            selectedTargetID: crossModelTarget.id
        )
        #expect(state.codexRoutingCandidates(for: routeKey, from: catalog).map(\.upstreamModel) == ["gpt-5.6-sol"])

        state.restoreCodexAutomaticRoute(routeKey: routeKey)
        let restored = state.codexRoutingCandidates(for: routeKey, from: catalog)

        #expect(state.codexRoutePolicy(for: routeKey) == nil)
        #expect(Set(restored.map(\.providerRef)) == [firstProvider.ref, secondProvider.ref])
        #expect(restored.allSatisfy { $0.upstreamModel == routeKey.logicalModel })
    }

    @Test
    func disabledRouteIsExcludedFromProxyUnlessPinned() {
        let upstream = provider(id: "upstream", name: "Upstream")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let catalog = ProviderCatalog(
            providers: [upstream],
            candidates: [candidate(provider: upstream, model: routeKey.logicalModel)]
        )
        var state = CustomModelState()
        state.setCodexRouteDisabled(true, routeKey: routeKey)

        let disabled = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: state
        )
        let pinnedScope = UniGateModelScope(modelsByApp: ["codex": [routeKey.logicalModel]])
        let pinned = catalog.scopedForProxy(
            uniGateModelScope: pinnedScope,
            customModels: state
        )

        #expect(disabled.candidates(for: routeKey).isEmpty)
        #expect(state.isCodexRouteDisabled(routeKey, pinnedScope: UniGateModelScope()))
        #expect(pinned.candidates(for: routeKey).count == 1)
        #expect(!state.isCodexRouteDisabled(routeKey, pinnedScope: pinnedScope))
    }

    @Test
    func pinnedCodexCustomAliasKeepsItsExplicitTarget() {
        let upstream = provider(id: "upstream", name: "Upstream")
        let upstreamCandidate = candidate(provider: upstream, model: "qwen3.6")
        let aliasRouteKey = ModelRouteKey(appType: "codex", logicalModel: "customer_model")
        let target = CustomModelTarget(
            routeKey: upstreamCandidate.routeKey,
            providerRef: upstream.ref
        )
        let state = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: aliasRouteKey.logicalModel,
                targets: [target],
                selectedTargetID: target.id
            )
        ])
        let catalog = ProviderCatalog(
            providers: [upstream],
            candidates: [upstreamCandidate]
        )

        let scoped = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(modelsByApp: [
                "codex": [aliasRouteKey.logicalModel]
            ]),
            customModels: state
        )

        let aliasCandidates = scoped.candidates(for: aliasRouteKey)
        #expect(aliasCandidates.count == 1)
        #expect(aliasCandidates.first?.upstreamModel == "qwen3.6")
        #expect(aliasCandidates.first?.upstreamProviderRef == upstream.ref)
    }

    @Test
    func legacyVisibilityMigrationIsIdempotentAndFutureModelsDefaultVisible() {
        let upstream = provider(id: "upstream", name: "Upstream")
        let visible = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let hidden = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.6-luna")
        let pinned = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.6-sol")
        let future = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.7")
        let pinnedScope = UniGateModelScope(modelsByApp: ["codex": [pinned.logicalModel]])
        let initialCatalog = ProviderCatalog(
            providers: [upstream],
            candidates: [visible, hidden, pinned].map {
                candidate(provider: upstream, model: $0.logicalModel)
            }
        )
        var state = CustomModelState()

        let migrated = state.migrateLegacyCodexVisibility(
            visibleModels: [visible.description],
            catalog: initialCatalog,
            readyProviderRefs: [upstream.ref],
            pinnedScope: pinnedScope
        )
        let migratedAgain = state.migrateLegacyCodexVisibility(
            visibleModels: [visible.description],
            catalog: ProviderCatalog(
                providers: [upstream],
                candidates: initialCatalog.candidates + [
                    candidate(provider: upstream, model: future.logicalModel)
                ]
            ),
            readyProviderRefs: [upstream.ref],
            pinnedScope: pinnedScope
        )

        #expect(migrated)
        #expect(!migratedAgain)
        #expect(!state.isCodexRouteDisabled(visible, pinnedScope: pinnedScope))
        #expect(state.isCodexRouteDisabled(hidden, pinnedScope: pinnedScope))
        #expect(!state.isCodexRouteDisabled(pinned, pinnedScope: pinnedScope))
        #expect(!state.isCodexRouteDisabled(future, pinnedScope: pinnedScope))
    }

    @Test
    func legacyVisibilityMigrationWaitsForMissingProviderBeforeFinalizing() {
        let official = provider(
            id: "official",
            name: "Codex Official",
            backendKind: .codexOfficial
        )
        let hidden = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.6-luna")
        let future = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.7")
        var state = CustomModelState()

        let initialized = state.migrateLegacyCodexVisibility(
            visibleModels: [],
            catalog: ProviderCatalog(providers: [official], candidates: []),
            readyProviderRefs: [],
            pinnedScope: UniGateModelScope()
        )

        #expect(initialized)
        #expect(!state.codexVisibilityMigrated)
        #expect(state.codexVisibilityMigration?.pendingProviderRefs == [official.ref])

        let recoveredCatalog = ProviderCatalog(
            providers: [official],
            candidates: [candidate(provider: official, model: hidden.logicalModel)]
        )
        let completed = state.migrateLegacyCodexVisibility(
            visibleModels: [],
            catalog: recoveredCatalog,
            readyProviderRefs: [official.ref],
            pinnedScope: UniGateModelScope()
        )

        #expect(completed)
        #expect(state.codexVisibilityMigrated)
        #expect(state.codexVisibilityMigration == nil)
        #expect(state.isCodexRouteDisabled(hidden, pinnedScope: UniGateModelScope()))

        let futureCatalog = ProviderCatalog(
            providers: [official],
            candidates: recoveredCatalog.candidates + [
                candidate(provider: official, model: future.logicalModel)
            ]
        )
        let migratedFuture = state.migrateLegacyCodexVisibility(
            visibleModels: [],
            catalog: futureCatalog,
            readyProviderRefs: [official.ref],
            pinnedScope: UniGateModelScope()
        )
        #expect(!migratedFuture)
        #expect(!state.isCodexRouteDisabled(future, pinnedScope: UniGateModelScope()))
    }

    @Test
    func legacyVisibilityMigrationWithNoExistingCodexProviderDoesNotHideFutureProviders() {
        var state = CustomModelState()
        let migrated = state.migrateLegacyCodexVisibility(
            visibleModels: [],
            catalog: ProviderCatalog(providers: [], candidates: []),
            readyProviderRefs: [],
            pinnedScope: UniGateModelScope()
        )
        let futureProvider = provider(id: "future", name: "Future Provider")
        let futureRouteKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-6")

        #expect(migrated)
        #expect(state.codexVisibilityMigrated)
        #expect(!state.isCodexRouteDisabled(futureRouteKey, pinnedScope: UniGateModelScope()))
        #expect(ProviderCatalog(
            providers: [futureProvider],
            candidates: [candidate(provider: futureProvider, model: futureRouteKey.logicalModel)]
        ).scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: state
        ).candidates(for: futureRouteKey).count == 1)
    }

    @Test
    func existingCodexCustomAliasWinsOverLaterSameNameDiscovery() {
        let upstream = provider(id: "upstream", name: "Upstream")
        let aliasRouteKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let aliasTargetCandidate = candidate(provider: upstream, model: "qwen3.6")
        let target = CustomModelTarget(
            routeKey: aliasTargetCandidate.routeKey,
            providerRef: upstream.ref
        )
        let state = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: aliasRouteKey.logicalModel,
                targets: [target],
                selectedTargetID: target.id
            )
        ])
        let catalog = ProviderCatalog(
            providers: [upstream],
            candidates: [
                candidate(provider: upstream, model: aliasRouteKey.logicalModel),
                aliasTargetCandidate
            ]
        )

        let scoped = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: state
        )
        let candidates = scoped.candidates(for: aliasRouteKey)

        #expect(candidates.count == 1)
        #expect(candidates.first?.providerRef == CustomModelState.syntheticProviderRef(
            appType: "codex",
            target: target
        ))
        #expect(candidates.first?.upstreamModel == aliasTargetCandidate.upstreamModel)
    }

    @Test
    func codexTargetPrefersLongContextDiscoveryOverSameProviderConfiguredDuplicate() {
        let upstream = provider(id: "upstream", name: "Upstream")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.6")
        let configured = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: upstream.ref,
            providerName: upstream.name,
            appType: "codex",
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: routeKey.logicalModel,
            baseURL: upstream.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .configured
        )
        let discovered = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: upstream.ref,
            providerName: upstream.name,
            appType: "codex",
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "\(routeKey.logicalModel) [1m]",
            baseURL: upstream.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: true,
            source: .discovered
        )
        let catalog = ProviderCatalog(providers: [upstream], candidates: [configured, discovered])
        let target = CustomModelTarget(routeKey: routeKey, providerRef: upstream.ref)
        var state = CustomModelState()
        state.setCodexExplicitRoute(
            routeKey: routeKey,
            targets: [target],
            selectedTargetID: target.id
        )

        let automatic = CustomModelState().codexRoutingCandidates(for: routeKey, from: catalog)
        let explicit = state.codexRoutingCandidates(for: routeKey, from: catalog)

        #expect(automatic.count == 1)
        #expect(automatic.first?.supportsLongContext == true)
        #expect(automatic.first?.upstreamModel == discovered.upstreamModel)
        #expect(explicit.count == 1)
        #expect(explicit.first?.supportsLongContext == true)
        #expect(explicit.first?.upstreamModel == discovered.upstreamModel)
    }

    @Test
    func codexRoutingPolicyDoesNotChangeClaudeDiscoveryScoping() {
        let codexProvider = provider(id: "codex", name: "Codex Provider")
        let claudeProvider = provider(
            id: "claude",
            appType: "claude",
            name: "Claude Provider",
            apiFormat: .anthropic
        )
        let catalog = ProviderCatalog(
            providers: [codexProvider, claudeProvider],
            candidates: [
                candidate(provider: codexProvider, model: "gpt-5.5"),
                candidate(provider: claudeProvider, model: "deepseek-v4-pro")
            ]
        )

        let scoped = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: CustomModelState()
        )

        #expect(scoped.routeKeys.map(\.description) == ["codex:gpt-5.5"])
    }

    private func provider(
        id: String,
        appType: String = "codex",
        name: String,
        apiFormat: ApiFormat = .openaiResponses,
        backendKind: ProviderBackendKind = .standard
    ) -> ImportedProvider {
        ImportedProvider(
            id: id,
            appType: appType,
            name: name,
            category: backendKind == .codexOfficial ? "official" : nil,
            sortIndex: nil,
            isCurrent: false,
            apiFormat: apiFormat,
            baseURL: backendKind == .codexOfficial
                ? CodexOfficial.backendBaseURLString
                : "https://\(id).example.com",
            hasSecret: backendKind == .standard,
            settings: backendKind == .standard
                ? ["auth": .object(["OPENAI_API_KEY": .string("key-\(id)")])]
                : [:],
            meta: [:],
            backendKind: backendKind
        )
    }

    private func candidate(
        provider: ImportedProvider,
        model: String,
        source: ModelCandidateSource = .discovered
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: model,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: provider.appType == "codex" ? .codexResponses : .anthropicMessages,
            apiFormat: provider.apiFormat,
            upstreamModel: model,
            baseURL: provider.baseURL,
            requiresTransform: provider.appType == "codex"
                ? provider.apiFormat != .openaiResponses
                : provider.apiFormat != .anthropic,
            label: nil,
            supportsLongContext: false,
            source: source
        )
    }
}
