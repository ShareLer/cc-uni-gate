import UniGateCore
import Foundation
import Testing

struct ConfigurationHealthTests {
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
}
