import UniGateCore
import Foundation
import Testing

struct ConfigurationHealthTests {
    @Test
    func acceptsCurrentCodexUniGateProviderWithoutPinnedModels() {
        let report = ConfigurationHealthReport.build(
            databasePath: "/tmp/cc-switch.db",
            databaseExists: true,
            catalogLoadError: nil,
            proxySeverity: .ok,
            proxyDetail: "running",
            catalog: ProviderCatalog(providers: [], candidates: []),
            routes: RouteState(),
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope(),
            integration: CcSwitchIntegrationSnapshot(
                databasePath: "/tmp/cc-switch.db",
                providers: [
                    CcSwitchProviderSummary(
                        id: "unigate-old",
                        appType: "codex",
                        name: "UniGate Old",
                        isCurrent: false,
                        isUniGateProvider: true,
                        baseURL: "http://127.0.0.1:17888/codex",
                        configuredModels: ["old-pinned"],
                        hasClaudeDesktopRoutes: false
                    ),
                    CcSwitchProviderSummary(
                        id: "unigate-current",
                        appType: "codex",
                        name: "UniGate",
                        isCurrent: true,
                        isUniGateProvider: true,
                        baseURL: "http://127.0.0.1:17888/codex",
                        configuredModels: [],
                        hasClaudeDesktopRoutes: false
                    )
                ]
            ),
            now: Date(timeIntervalSince1970: 0)
        )

        let codexHealth = report.items.first { $0.id == "unigate-provider-codex" }
        #expect(codexHealth?.severity == .ok)
        #expect(codexHealth?.detail == "未配置固定模型，将使用供应商探测结果")
        #expect(codexHealth?.actionTitle == nil)
        #expect(!report.items.contains { $0.id == "unigate-current-codex" })
        #expect(!report.items.contains { $0.id == "scope-empty-codex" })
        #expect(report.items.contains { $0.id == "scope-empty-claude" })
    }

    @Test
    func existingCodexCustomAliasDoesNotBecomeAConflictWhenBaseModelAppears() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let baseCandidate = ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let target = CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
        let report = ConfigurationHealthReport.build(
            databasePath: "/tmp/cc-switch.db",
            databaseExists: true,
            catalogLoadError: nil,
            proxySeverity: .ok,
            proxyDetail: "running",
            catalog: ProviderCatalog(providers: [provider], candidates: [baseCandidate]),
            routes: RouteState(),
            customModels: CustomModelState(models: [
                CustomModelDefinition(
                    appType: "codex",
                    name: "gpt-5.5",
                    targets: [target],
                    selectedTargetID: target.id
                )
            ]),
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            integration: CcSwitchIntegrationSnapshot(databasePath: "/tmp/cc-switch.db", providers: []),
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(!report.items.contains {
            $0.id == "custom-name-conflict-codex:gpt-5.5"
        })
    }

    @Test
    func reportsMissingDesktopRoutesAndCustomModelIssues() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let report = ConfigurationHealthReport.build(
            databasePath: "/tmp/cc-switch.db",
            databaseExists: true,
            catalogLoadError: nil,
            proxySeverity: .ok,
            proxyDetail: "running",
            catalog: ProviderCatalog(providers: [provider], candidates: [candidate]),
            routes: RouteState(),
            customModels: CustomModelState(models: [
                CustomModelDefinition(
                    appType: "codex",
                    name: "uni",
                    targets: [
                        CustomModelTarget(
                            routeKey: ModelRouteKey(appType: "codex", logicalModel: "missing"),
                            providerRef: provider.ref
                        )
                    ]
                )
            ]),
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            integration: CcSwitchIntegrationSnapshot(databasePath: "/tmp/cc-switch.db", providers: []),
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(report.worstSeverity == .error)
        #expect(report.items.contains { $0.id == "desktop-routes-missing" })
        #expect(report.items.contains { $0.id == "custom-target-missing-codex:uni" })
        #expect(!report.items.contains { $0.id == "custom-unconfigured-codex:uni" })
    }

    @Test
    func reportsMissingCustomModelTargetEvenWhenAnotherTargetStillExists() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let activeTarget = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "present"),
            providerRef: provider.ref
        )
        let staleTarget = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "missing"),
            providerRef: provider.ref
        )
        let report = ConfigurationHealthReport.build(
            databasePath: "/tmp/cc-switch.db",
            databaseExists: true,
            catalogLoadError: nil,
            proxySeverity: .ok,
            proxyDetail: "running",
            catalog: ProviderCatalog(providers: [provider], candidates: [
                ModelCandidate(
                    logicalModel: "present",
                    providerRef: provider.ref,
                    providerName: provider.name,
                    appType: provider.appType,
                    clientProtocol: .codexResponses,
                    apiFormat: .openaiResponses,
                    upstreamModel: "present",
                    baseURL: provider.baseURL,
                    requiresTransform: false,
                    label: nil,
                    supportsLongContext: false
                )
            ]),
            routes: RouteState(),
            customModels: CustomModelState(models: [
                CustomModelDefinition(
                    appType: "codex",
                    name: "uni",
                    targets: [staleTarget, activeTarget],
                    selectedTargetID: staleTarget.id
                )
            ]),
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["uni"]]),
            integration: CcSwitchIntegrationSnapshot(databasePath: "/tmp/cc-switch.db", providers: []),
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(report.items.contains { $0.id == "custom-target-missing-codex:uni" })
    }

    @Test
    func reportsStaleCustomModelTargetWhenForceEnabled() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let staleCandidate = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: routeKey.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .staleDiscovered
        )
        let target = CustomModelTarget(
            routeKey: routeKey,
            providerRef: provider.ref
        )
        let report = ConfigurationHealthReport.build(
            databasePath: "/tmp/cc-switch.db",
            databaseExists: true,
            catalogLoadError: nil,
            proxySeverity: .ok,
            proxyDetail: "running",
            catalog: ProviderCatalog(providers: [provider], candidates: [staleCandidate]),
            routes: RouteState(),
            customModels: CustomModelState(models: [
                CustomModelDefinition(
                    appType: "codex",
                    name: "uni",
                    forceEnabled: true,
                    targets: [target],
                    selectedTargetID: target.id
                )
            ]),
            uniGateModelScope: UniGateModelScope(modelsByApp: [:]),
            integration: CcSwitchIntegrationSnapshot(databasePath: "/tmp/cc-switch.db", providers: []),
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(report.items.contains { $0.id == "custom-target-stale-codex:uni" })
        #expect(!report.items.contains { $0.id == "custom-unconfigured-codex:uni" })
    }

    @Test
    func reportsDiscoveryStaleTargetsAndRoutes() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let staleCandidate = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: routeKey.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .staleDiscovered
        )
        let selectedTarget = CustomModelTarget(
            routeKey: routeKey,
            providerRef: provider.ref
        )
        let report = ConfigurationHealthReport.build(
            databasePath: "/tmp/cc-switch.db",
            databaseExists: true,
            catalogLoadError: nil,
            proxySeverity: .ok,
            proxyDetail: "running",
            catalog: ProviderCatalog(providers: [provider], candidates: [staleCandidate]),
            routes: RouteState(routes: [
                routeKey.description: ActiveRoute(
                    appType: routeKey.appType,
                    logicalModel: routeKey.logicalModel,
                    providerRef: provider.ref,
                    updatedAt: Date(timeIntervalSince1970: 1)
                )
            ]),
            customModels: CustomModelState(models: [
                CustomModelDefinition(
                    appType: "codex",
                    name: "uni",
                    targets: [selectedTarget],
                    selectedTargetID: selectedTarget.id
                )
            ]),
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            integration: CcSwitchIntegrationSnapshot(databasePath: "/tmp/cc-switch.db", providers: []),
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(report.items.contains { $0.id == "route-stale-codex:gpt-5.5" })
        #expect(report.items.contains { $0.id == "custom-target-stale-codex:uni" })
        #expect(!report.items.contains { $0.id == "route-invalid-codex:gpt-5.5" })
        #expect(!report.items.contains { $0.id == "custom-target-missing-codex:uni" })
    }

    @Test
    func validCodexExplicitRouteIsCheckedAgainstEffectiveProxyCandidates() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: UniGateAppRegistry.codex,
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let upstream = ModelCandidate(
            logicalModel: "gpt-5.6-sol",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.6-sol",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .discovered
        )
        let routeKey = ModelRouteKey(appType: UniGateAppRegistry.codex, logicalModel: "gpt-5.5")
        let target = CustomModelTarget(routeKey: upstream.routeKey, providerRef: provider.ref)
        var customModels = CustomModelState()
        customModels.setCodexExplicitRoute(
            routeKey: routeKey,
            targets: [target],
            selectedTargetID: target.id
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [upstream])
        let proxyCatalog = catalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: customModels
        )
        let routes = RouteStore.defaultState(
            candidates: proxyCatalog.candidates,
            preferredProviderRefsByRouteKey: customModels.preferredProviderRefsByRouteKey(
                availableIn: proxyCatalog
            )
        )
        _ = try #require(routes.routes[routeKey.description])

        let report = ConfigurationHealthReport.build(
            databasePath: "/tmp/cc-switch.db",
            databaseExists: true,
            catalogLoadError: nil,
            proxySeverity: .ok,
            proxyDetail: "running",
            catalog: catalog,
            routes: routes,
            customModels: customModels,
            uniGateModelScope: UniGateModelScope(),
            integration: CcSwitchIntegrationSnapshot(databasePath: "/tmp/cc-switch.db", providers: []),
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(!report.items.contains { $0.id == "route-invalid-\(routeKey.description)" })
    }
}
