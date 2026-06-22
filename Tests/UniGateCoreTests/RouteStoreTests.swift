import UniGateCore
import Foundation
import Testing

struct RouteStoreTests {
    @Test
    func switchesModelProvider() throws {
        let candidates = [
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "codex", id: "p1"),
                providerName: "Provider 1",
                appType: "codex",
                clientProtocol: .codexResponses,
                apiFormat: .openaiResponses,
                upstreamModel: "gpt-5.5",
                baseURL: "https://p1.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            ),
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "codex", id: "p2"),
                providerName: "Provider 2",
                appType: "codex",
                clientProtocol: .codexResponses,
                apiFormat: .openaiResponses,
                upstreamModel: "gpt-5.5",
                baseURL: "https://p2.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            )
        ]
        let catalog = ProviderCatalog(providers: [], candidates: candidates)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        let key = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5").description

        let initial = try store.load(catalog: catalog)
        #expect(initial.routes[key]?.providerRef == ProviderRef(appType: "codex", id: "p1"))

        let switched = try store.switchRoute(
            initial,
            catalog: catalog,
            appType: "codex",
            logicalModel: "gpt-5.5",
            providerRef: ProviderRef(appType: "codex", id: "p2"),
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(switched.routes[key]?.providerRef == ProviderRef(appType: "codex", id: "p2"))
    }

    @Test
    func switchesGroupedModelProvidersTogether() throws {
        let provider1 = ProviderRef(appType: "claude-desktop", id: "p1")
        let provider2 = ProviderRef(appType: "claude-desktop", id: "p2")
        let flash = ModelRouteKey(appType: "claude-desktop", logicalModel: "deepseek-v4-flash")
        let pro = ModelRouteKey(appType: "claude-desktop", logicalModel: "deepseek-v4-pro")
        let candidates = [
            candidate(routeKey: flash, providerRef: provider1, providerName: "Provider 1"),
            candidate(routeKey: pro, providerRef: provider1, providerName: "Provider 1"),
            candidate(routeKey: flash, providerRef: provider2, providerName: "Provider 2"),
            candidate(routeKey: pro, providerRef: provider2, providerName: "Provider 2")
        ]
        let catalog = ProviderCatalog(providers: [], candidates: candidates)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        let initial = RouteStore.defaultState(candidates: candidates)

        let switched = try store.switchRoutes(
            initial,
            catalog: catalog,
            routeKeys: [flash, pro],
            providerRef: provider2,
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(switched.routes[flash.description]?.providerRef == provider2)
        #expect(switched.routes[pro.description]?.providerRef == provider2)
    }

    @Test
    func loadDropsRoutesOutsideProxyScopedCatalog() throws {
        let dasu = ProviderRef(appType: "codex", id: "dasu")
        let free = ProviderRef(appType: "codex", id: "free")
        let rawCatalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.4"),
                providerRef: dasu,
                providerName: "dasu-gpt-plus-0.077"
            ),
            candidate(
                routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5"),
                providerRef: free,
                providerName: "gpt-free"
            )
        ])
        let scopedCatalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            customModels: CustomModelState()
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            "codex:gpt-5.4": ActiveRoute(
                appType: "codex",
                logicalModel: "gpt-5.4",
                providerRef: dasu,
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            "codex:gpt-5.5": ActiveRoute(
                appType: "codex",
                logicalModel: "gpt-5.5",
                providerRef: free,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))

        let loaded = try store.load(catalog: scopedCatalog)

        #expect(loaded.routes["codex:gpt-5.4"] == nil)
        #expect(loaded.routes["codex:gpt-5.5"]?.providerRef == free)
    }

    @Test
    func loadKeepsRoutesWhenSelectedTargetDisappearsButRouteKeyStillExists() throws {
        let stale = ProviderRef(appType: "codex", id: "stale")
        let active = ProviderRef(appType: "codex", id: "active")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "customer_model")
        let catalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                routeKey: routeKey,
                providerRef: active,
                providerName: "Active Provider"
            )
        ])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            routeKey.description: ActiveRoute(
                appType: routeKey.appType,
                logicalModel: routeKey.logicalModel,
                providerRef: stale,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))

        let loaded = try store.load(catalog: catalog)

        #expect(loaded.routes[routeKey.description]?.providerRef == stale)
    }

    @Test
    func keepsSameModelSeparateAcrossApps() {
        let candidates = [
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "codex", id: "p1"),
                providerName: "Codex Provider",
                appType: "codex",
                clientProtocol: .codexResponses,
                apiFormat: .openaiResponses,
                upstreamModel: "gpt-5.5",
                baseURL: "https://codex.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            ),
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "claude", id: "p2"),
                providerName: "Claude Provider",
                appType: "claude",
                clientProtocol: .anthropicMessages,
                apiFormat: .anthropic,
                upstreamModel: "gpt-5.5",
                baseURL: "https://claude.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            )
        ]

        let state = RouteStore.defaultState(candidates: candidates)

        #expect(state.routes["codex:gpt-5.5"]?.providerRef == ProviderRef(appType: "codex", id: "p1"))
        #expect(state.routes["claude:gpt-5.5"]?.providerRef == ProviderRef(appType: "claude", id: "p2"))
    }

    private func candidate(
        routeKey: ModelRouteKey,
        providerRef: ProviderRef,
        providerName: String
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: providerRef,
            providerName: providerName,
            appType: routeKey.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-flash",
            baseURL: "https://api.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
    }

}
