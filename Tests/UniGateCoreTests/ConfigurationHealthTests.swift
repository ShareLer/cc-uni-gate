import UniGateCore
import Foundation
import Testing

struct ConfigurationHealthTests {
    @Test
    func reportsCustomModelNameConflictWithVisibleBaseModel() {
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

        #expect(report.items.contains {
            $0.id == "custom-name-conflict-codex:gpt-5.5" && $0.severity == .warning
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
        #expect(report.items.contains { $0.id == "custom-unconfigured-codex:uni" })
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
}
