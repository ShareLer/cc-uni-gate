import UniGateCore
import Foundation
import Testing

struct CustomModelStoreTests {
    @Test
    func expandsCustomModelTargetsIntoSyntheticCandidates() throws {
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
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let baseCandidate = ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "upstream-gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: true
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [baseCandidate])
        let state = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [
                    CustomModelTarget(
                        routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5"),
                        providerRef: provider.ref
                    )
                ]
            )
        ])

        let expanded = state.expandedCandidates(from: catalog)
        let candidate = try #require(expanded.first)

        #expect(candidate.logicalModel == "customer_model")
        #expect(candidate.upstreamModel == "upstream-gpt-5.5")
        #expect(candidate.upstreamProviderRef == provider.ref)
        #expect(candidate.supportsLongContext)
    }

    @Test
    func persistsCustomModelState() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("custom-models.json")
        let store = CustomModelStore(fileURL: tmp)
        let target = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "claude", logicalModel: "deepseek-v4-pro"),
            providerRef: ProviderRef(appType: "claude", id: "p1")
        )
        let state = CustomModelState(models: [
            CustomModelDefinition(
                appType: "claude",
                name: "customer_model",
                targets: [target],
                selectedTargetID: target.id
            )
        ])

        try store.save(state)
        let loaded = try store.load()

        #expect(loaded.models == state.models)
    }

    @Test
    func expandsAllSelectedTargetsForCustomModel() throws {
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
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let fast = ModelCandidate(
            logicalModel: "fast",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "fast-upstream",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let pro = ModelCandidate(
            logicalModel: "pro",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "pro-upstream",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let fastTarget = CustomModelTarget(routeKey: fast.routeKey, providerRef: provider.ref)
        let proTarget = CustomModelTarget(routeKey: pro.routeKey, providerRef: provider.ref)
        let catalog = ProviderCatalog(providers: [provider], candidates: [fast, pro])
        let state = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [fastTarget, proTarget],
                selectedTargetID: proTarget.id
            )
        ])

        let expanded = state.expandedCandidates(from: catalog)

        #expect(expanded.count == 2)
        #expect(expanded.first?.upstreamModel == "pro-upstream")
        #expect(expanded.last?.upstreamModel == "fast-upstream")
    }
}
