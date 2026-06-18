import ApiManagerCore
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
}
