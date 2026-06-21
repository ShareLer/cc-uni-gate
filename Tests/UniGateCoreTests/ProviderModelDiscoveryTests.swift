import UniGateCore
import Foundation
import Testing

struct ProviderModelDiscoveryTests {
    @Test
    func buildsModelsURLCandidatesForAnthropicCompatBaseURL() {
        let urls = ProviderModelDiscovery.modelURLCandidates(
            baseURL: "https://api.deepseek.com/anthropic"
        ).map(\.absoluteString)

        #expect(urls == [
            "https://api.deepseek.com/anthropic/v1/models",
            "https://api.deepseek.com/v1/models",
            "https://api.deepseek.com/models"
        ])
    }

    @Test
    func buildsModelsURLCandidatesForVersionedBaseURL() {
        let urls = ProviderModelDiscovery.modelURLCandidates(
            baseURL: "https://open.bigmodel.cn/api/coding/paas/v4"
        ).map(\.absoluteString)

        #expect(urls == [
            "https://open.bigmodel.cn/api/coding/paas/v4/models",
            "https://open.bigmodel.cn/api/coding/paas/v4/v1/models"
        ])
    }

    @Test
    func buildsModelFetchPlanWithBearerAuthForAnthropicApiKey() throws {
        let provider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "Desktop Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.example.com/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_API_KEY": .string("claude-key")])],
            meta: [:]
        )

        let plan = try #require(ProviderModelDiscovery.fetchPlan(for: provider))

        #expect(plan.headers == ["authorization": "Bearer claude-key"])
        #expect(plan.urls.map(\.absoluteString) == [
            "https://api.example.com/anthropic/v1/models",
            "https://api.example.com/v1/models",
            "https://api.example.com/models"
        ])
    }

    @Test
    func parsesModelIDsFromOpenAICompatibleResponses() {
        let data = Data("""
        {
          "data": [
            {"id": "deepseek-v4-pro", "owned_by": "deepseek"},
            {"id": "deepseek-v4-flash", "owned_by": "deepseek"},
            {"id": "deepseek-v4-pro", "owned_by": "deepseek"}
          ]
        }
        """.utf8)

        #expect(ProviderModelDiscovery.modelIDs(from: data) == [
            "deepseek-v4-flash",
            "deepseek-v4-pro"
        ])
    }

    @Test
    func configuredClaudeDesktopModelsUseUpstreamModelAndIgnoreCustomAliases() {
        let provider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.deepseek.com/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let baseCandidate = ModelCandidate(
            logicalModel: "claude-sonnet-4-6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-pro[1M]",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "DeepSeek V4 Pro",
            supportsLongContext: true
        )
        let customCandidate = ModelCandidate(
            logicalModel: "uni-model",
            providerRef: ProviderRef(appType: "claude-desktop", id: "custom"),
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-pro[1M]",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "自定义：claude-sonnet-4-6",
            supportsLongContext: true,
            upstreamProviderRef: provider.ref
        )
        let catalog = ProviderCatalog(
            providers: [provider],
            candidates: [baseCandidate, customCandidate]
        )

        #expect(ProviderModelDiscovery.configuredUpstreamModelIDs(
            from: catalog,
            appType: "claude-desktop"
        ) == ["deepseek-v4-pro"])
    }
}
