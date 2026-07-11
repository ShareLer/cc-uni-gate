import UniGateCore
import Foundation
import Testing

struct ModelRouteGroupingTests {
    @Test
    func groupsRoutesWithEquivalentProviderTargets() {
        let providerRef = ProviderRef(appType: "claude-desktop", id: "deepseek")
        let candidates = [
            candidate(
                logicalModel: "deepseek-v4-flash",
                upstreamModel: "deepseek-v4-flash",
                providerRef: providerRef
            ),
            candidate(
                logicalModel: "deepseek-v4-flash-fast",
                upstreamModel: "deepseek-v4-flash",
                providerRef: providerRef
            ),
            candidate(
                logicalModel: "deepseek-v4-pro",
                upstreamModel: "deepseek-v4-pro",
                providerRef: providerRef
            )
        ]
        let routeKeys = candidates.map(\.routeKey)

        let groups = ModelRouteGrouping.groups(routeKeys: routeKeys, candidates: candidates)

        #expect(groups.count == 2)
        #expect(groups[0].routeKey.logicalModel == "deepseek-v4-flash")
        #expect(Set(groups[0].routeKeys.map(\.logicalModel)) == [
            "deepseek-v4-flash",
            "deepseek-v4-flash-fast"
        ])
        #expect(groups[1].routeKey.logicalModel == "deepseek-v4-pro")
    }

    @Test
    func groupsOneMAliasWithCanonicalModelName() {
        let providerRef = ProviderRef(appType: "claude", id: "deepseek")
        let canonical = candidate(
            logicalModel: "deepseek-v4-pro",
            upstreamModel: "deepseek-v4-pro",
            providerRef: providerRef,
            appType: "claude"
        )
        let oneM = candidate(
            logicalModel: "deepseek-v4-pro[1M]",
            upstreamModel: "deepseek-v4-pro[1M]",
            providerRef: providerRef,
            appType: "claude",
            supportsLongContext: true
        )

        let groups = ModelRouteGrouping.groups(
            routeKeys: [oneM.routeKey, canonical.routeKey],
            candidates: [oneM, canonical]
        )

        #expect(groups.count == 1)
        #expect(groups[0].routeKey.logicalModel == "deepseek-v4-pro")
        #expect(Set(groups[0].routeKeys.map(\.logicalModel)) == [
            "deepseek-v4-pro",
            "deepseek-v4-pro[1M]"
        ])
    }

    @Test
    func displayIdentityUsesUpstreamModelWithoutProviderOrOneMMarker() {
        let provider1 = ProviderRef(appType: "claude-desktop", id: "p1")
        let provider2 = ProviderRef(appType: "claude-desktop", id: "p2")
        let first = candidate(
            logicalModel: "auto",
            upstreamModel: "auto[1M]",
            providerRef: provider1
        )
        let second = candidate(
            logicalModel: "auto",
            upstreamModel: "auto",
            providerRef: provider2
        )
        let other = candidate(
            logicalModel: "auto",
            upstreamModel: "claude-opus-4-7",
            providerRef: provider2
        )

        #expect(ModelDisplayIdentity(candidate: first) == ModelDisplayIdentity(candidate: second))
        #expect(ModelDisplayIdentity(candidate: first) != ModelDisplayIdentity(candidate: other))
    }

    @Test
    func displayCandidatesExcludeOtherUpstreamModelsForActiveClaudeDesktopRoute() {
        let autoProvider1 = ProviderRef(appType: "claude-desktop", id: "auto-1")
        let autoProvider2 = ProviderRef(appType: "claude-desktop", id: "auto-2")
        let opusProvider = ProviderRef(appType: "claude-desktop", id: "opus")
        let candidates = [
            candidate(
                logicalModel: "auto",
                upstreamModel: "auto",
                providerRef: autoProvider1
            ),
            candidate(
                logicalModel: "auto",
                upstreamModel: "auto[1M]",
                providerRef: autoProvider2
            ),
            candidate(
                logicalModel: "auto",
                upstreamModel: "claude-opus-4-7",
                providerRef: opusProvider
            )
        ]

        let displayCandidates = ModelRouteGrouping.displayCandidates(
            candidates,
            activeProviderRef: autoProvider1
        )

        #expect(Set(displayCandidates.map(\.providerRef)) == [autoProvider1, autoProvider2])
        #expect(displayCandidates.allSatisfy { $0.upstreamModelDisplayName == "auto" })
    }

    @Test
    func displayCandidatesCanKeepDifferentUpstreamModelsForCustomRoutes() {
        let autoProvider = ProviderRef(appType: "claude-desktop", id: "auto")
        let deepseekProvider = ProviderRef(appType: "claude-desktop", id: "deepseek")
        let opusProvider = ProviderRef(appType: "claude-desktop", id: "opus")
        let candidates = [
            candidate(
                logicalModel: "my-router",
                upstreamModel: "auto",
                providerRef: autoProvider
            ),
            candidate(
                logicalModel: "my-router",
                upstreamModel: "deepseek-v4-pro",
                providerRef: deepseekProvider
            ),
            candidate(
                logicalModel: "my-router",
                upstreamModel: "claude-opus-4-7",
                providerRef: opusProvider
            )
        ]

        let displayCandidates = ModelRouteGrouping.displayCandidates(
            candidates,
            activeProviderRef: autoProvider,
            restrictToActiveDisplayIdentity: false
        )

        #expect(Set(displayCandidates.map(\.providerRef)) == [
            autoProvider,
            deepseekProvider,
            opusProvider
        ])
        #expect(Set(displayCandidates.map(\.upstreamModelDisplayName)) == [
            "auto",
            "deepseek-v4-pro",
            "claude-opus-4-7"
        ])
    }

    @Test
    func visibleConfiguredBaseRouteKeysUseSameEntryPointForAllApps() {
        let codexProvider = ProviderRef(appType: "codex", id: "codex")
        let claudeProvider = ProviderRef(appType: "claude", id: "claude")
        let desktopProvider = ProviderRef(appType: "claude-desktop", id: "desktop")
        let catalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                logicalModel: "gpt-5.5",
                upstreamModel: "gpt-5.5",
                providerRef: codexProvider,
                appType: "codex"
            ),
            candidate(
                logicalModel: "deepseek-v4-pro",
                upstreamModel: "deepseek-v4-pro",
                providerRef: claudeProvider,
                appType: "claude"
            ),
            candidate(
                logicalModel: "claude-opus-4-8",
                upstreamModel: "union-model",
                providerRef: desktopProvider
            )
        ])
        let scope = UniGateModelScope(modelsByApp: [
            "codex": ["gpt-5.5"],
            "claude": ["deepseek-v4-pro"],
            "claude-desktop": ["union-model"]
        ])

        let routeKeys = ModelRouteVisibility.visibleConfiguredBaseRouteKeys(
            catalog: catalog,
            customModels: CustomModelState(),
            uniGateModelScope: scope,
            preferences: AppPreferences()
        )

        #expect(Set(routeKeys.map(\.description)) == [
            "codex:gpt-5.5",
            "claude:deepseek-v4-pro",
            "claude-desktop:claude-opus-4-8"
        ])
    }

    @Test
    func visibleConfiguredBaseRouteKeysMatchDesktopScopeByUpstreamModel() {
        let providerRef = ProviderRef(appType: "claude-desktop", id: "desktop")
        let catalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                logicalModel: "claude-opus-4-8",
                upstreamModel: "union-model",
                providerRef: providerRef
            ),
            candidate(
                logicalModel: "claude-sonnet-4-6",
                upstreamModel: "deepseek-v4-pro",
                providerRef: providerRef
            )
        ])
        let scope = UniGateModelScope(modelsByApp: [
            "claude-desktop": ["union-model"]
        ])

        let routeKeys = ModelRouteVisibility.visibleConfiguredBaseRouteKeys(
            catalog: catalog,
            customModels: CustomModelState(),
            uniGateModelScope: scope,
            preferences: AppPreferences()
        )

        #expect(routeKeys.map(\.description) == [
            "claude-desktop:claude-opus-4-8"
        ])
    }

    @Test
    func visibleConfiguredBaseRouteKeysExcludeDiscoveredModels() {
        let providerRef = ProviderRef(appType: "codex", id: "codex")
        let catalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                logicalModel: "gpt-5.5",
                upstreamModel: "gpt-5.5",
                providerRef: providerRef,
                appType: "codex"
            ),
            candidate(
                logicalModel: "qwen3.6",
                upstreamModel: "qwen3.6",
                providerRef: providerRef,
                appType: "codex",
                source: .discovered
            )
        ])
        let scope = UniGateModelScope(modelsByApp: [
            "codex": ["gpt-5.5", "qwen3.6"]
        ])

        let routeKeys = ModelRouteVisibility.visibleConfiguredBaseRouteKeys(
            catalog: catalog,
            customModels: CustomModelState(),
            uniGateModelScope: scope,
            preferences: AppPreferences()
        )

        #expect(routeKeys.map(\.description) == [
            "codex:gpt-5.5"
        ])
    }

    @Test
    func visibleConfiguredBaseRouteKeysExcludeCustomProviderDiscoveredModels() {
        let configuredRef = ProviderRef(appType: "codex", id: "configured")
        let customRef = ProviderRef(appType: "codex", id: "unigate-custom")
        let catalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                logicalModel: "gpt-5.5",
                upstreamModel: "gpt-5.5",
                providerRef: configuredRef,
                appType: "codex"
            ),
            candidate(
                logicalModel: "qwen3.6",
                upstreamModel: "qwen3.6",
                providerRef: customRef,
                appType: "codex",
                source: .discovered
            )
        ])
        let scope = UniGateModelScope(modelsByApp: [
            "codex": ["gpt-5.5", "qwen3.6"]
        ])

        let routeKeys = ModelRouteVisibility.visibleConfiguredBaseRouteKeys(
            catalog: catalog,
            customModels: CustomModelState(),
            uniGateModelScope: scope,
            preferences: AppPreferences()
        )

        #expect(routeKeys.map(\.description) == [
            "codex:gpt-5.5"
        ])
    }

    @Test
    func officialCodexDiscoveredModelsSeedRoutesWithoutCcSwitchModelScope() {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let provider = ImportedProvider(
            id: providerRef.id,
            appType: providerRef.appType,
            name: "Codex Official",
            category: "official",
            sortIndex: nil,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: CodexOfficial.backendBaseURLString,
            hasSecret: false,
            settings: [:],
            meta: [:],
            backendKind: .codexOfficial
        )
        let discovered = candidate(
            logicalModel: "gpt-5.5",
            upstreamModel: "gpt-5.5",
            providerRef: providerRef,
            appType: "codex",
            source: .discovered
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [discovered])

        let routeKeys = ModelRouteVisibility.visibleConfiguredBaseRouteKeys(
            catalog: catalog,
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope(),
            preferences: AppPreferences()
        )
        let proxyCatalog = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: CustomModelState()
        )

        #expect(routeKeys.map(\.description) == ["codex:gpt-5.5"])
        #expect(proxyCatalog.candidates.map(\.logicalModel) == ["gpt-5.5"])
    }

    @Test
    func officialCodexRouteIncludesSameNameThirdPartyCandidatesWithoutCcSwitchScope() throws {
        let officialRef = ProviderRef(appType: "codex", id: "official")
        let thirdPartyRef = ProviderRef(appType: "codex", id: "ahoo-gpt")
        let official = ImportedProvider(
            id: officialRef.id,
            appType: officialRef.appType,
            name: "Codex Official",
            category: "official",
            sortIndex: nil,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: CodexOfficial.backendBaseURLString,
            hasSecret: false,
            settings: [:],
            meta: [:],
            backendKind: .codexOfficial
        )
        let thirdParty = ImportedProvider(
            id: thirdPartyRef.id,
            appType: thirdPartyRef.appType,
            name: "ahoo-gpt",
            category: nil,
            sortIndex: nil,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.ahoo.example",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let catalog = ProviderCatalog(
            providers: [official, thirdParty],
            candidates: [
                candidate(
                    logicalModel: "gpt-5.6-luna",
                    upstreamModel: "gpt-5.6-luna",
                    providerRef: officialRef,
                    appType: "codex",
                    source: .discovered
                ),
                candidate(
                    logicalModel: "gpt-5.6-luna",
                    upstreamModel: "gpt-5.6-luna",
                    providerRef: thirdPartyRef,
                    appType: "codex",
                    source: .discovered
                ),
                candidate(
                    logicalModel: "gpt-5.6-terra",
                    upstreamModel: "gpt-5.6-terra",
                    providerRef: thirdPartyRef,
                    appType: "codex",
                    source: .discovered
                )
            ]
        )

        let proxyCatalog = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: CustomModelState()
        )

        #expect(proxyCatalog.candidates.map(\.providerRef) == [officialRef, thirdPartyRef])

        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.6-luna")
        let store = RouteStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("routes.json")
        )
        let switched = try store.switchRoute(
            RouteStore.defaultState(candidates: proxyCatalog.candidates),
            catalog: proxyCatalog,
            appType: routeKey.appType,
            logicalModel: routeKey.logicalModel,
            providerRef: thirdPartyRef,
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(switched.routes[routeKey.description]?.providerRef == thirdPartyRef)
    }

    @Test
    func protocolOverridesDoNotChangeOfficialCodexBackend() throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let provider = ImportedProvider(
            id: providerRef.id,
            appType: providerRef.appType,
            name: "Codex Official",
            category: "official",
            sortIndex: nil,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: CodexOfficial.backendBaseURLString,
            hasSecret: false,
            settings: [:],
            meta: [:],
            backendKind: .codexOfficial
        )
        let discovered = candidate(
            logicalModel: "gpt-5.5",
            upstreamModel: "gpt-5.5",
            providerRef: providerRef,
            appType: "codex",
            source: .discovered
        )
        let overridden = ProviderCatalog(providers: [provider], candidates: [discovered])
            .applyingProtocolOverrides([providerRef.description: .openaiChat])

        #expect(try #require(overridden.providers.first).apiFormat == .openaiResponses)
        #expect(try #require(overridden.candidates.first).apiFormat == .openaiResponses)
    }

    private func candidate(
        logicalModel: String,
        upstreamModel: String,
        providerRef: ProviderRef,
        appType: String = "claude-desktop",
        supportsLongContext: Bool = false,
        source: ModelCandidateSource = .configured
    ) -> ModelCandidate {
        let isCodex = appType == "codex"
        return ModelCandidate(
            logicalModel: logicalModel,
            providerRef: providerRef,
            providerName: "DeepSeek",
            appType: appType,
            clientProtocol: isCodex ? .codexResponses : .anthropicMessages,
            apiFormat: isCodex ? .openaiResponses : .anthropic,
            upstreamModel: upstreamModel,
            baseURL: "https://api.deepseek.example",
            requiresTransform: false,
            label: nil,
            supportsLongContext: supportsLongContext,
            source: source
        )
    }
}
