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
    func discoveredCandidatesUseProviderConfigAndStripLogicalModel() throws {
        let provider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.deepseek.example/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let result = ProviderModelDiscoveryResult(
            providerRef: provider.ref,
            appType: provider.appType,
            providerName: provider.name,
            modelIDs: ["deepseek-v4-pro[1M]", "auto", "auto"],
            errorMessage: nil,
            sourceURL: nil,
            configurationFingerprint: ProviderModelDiscoveryFingerprint.value(for: provider)
        )
        let state = ProviderModelDiscoveryState(results: [provider.ref.description: result])
        let catalog = ProviderCatalog(providers: [provider], candidates: [])

        let candidates = ProviderModelDiscovery.discoveredCandidates(from: state, catalog: catalog)

        #expect(candidates.map(\.logicalModel) == ["auto", "deepseek-v4-pro"])
        let pro = try #require(candidates.first { $0.logicalModel == "deepseek-v4-pro" })
        #expect(pro.source == .discovered)
        #expect(pro.providerRef == provider.ref)
        #expect(pro.upstreamProviderRef == provider.ref)
        #expect(pro.providerName == provider.name)
        #expect(pro.appType == "claude-desktop")
        #expect(pro.clientProtocol == .anthropicMessages)
        #expect(pro.apiFormat == .anthropic)
        #expect(pro.upstreamModel == "deepseek-v4-pro[1M]")
        #expect(pro.supportsLongContext)
        #expect(pro.requiresTransform == false)
        #expect(pro.baseURL == provider.baseURL)
    }

    @Test
    func discoveredCandidatesIgnoreStaleProviderConfigurationFingerprint() {
        let currentProvider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.current.example/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let oldProvider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.old.example/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let result = ProviderModelDiscoveryResult(
            providerRef: currentProvider.ref,
            appType: currentProvider.appType,
            providerName: currentProvider.name,
            modelIDs: ["stale-model"],
            errorMessage: nil,
            sourceURL: nil,
            configurationFingerprint: ProviderModelDiscoveryFingerprint.value(for: oldProvider)
        )
        let state = ProviderModelDiscoveryState(results: [currentProvider.ref.description: result])
        let catalog = ProviderCatalog(providers: [currentProvider], candidates: [])

        #expect(ProviderModelDiscovery.discoveredCandidates(from: state, catalog: catalog).isEmpty)
    }

    @Test
    func disabledDiscoveryDoesNotMakeStaleFingerprintCandidatesAvailable() {
        let currentProvider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.current.example/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let oldProvider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.old.example/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let result = ProviderModelDiscoveryResult(
            providerRef: currentProvider.ref,
            appType: currentProvider.appType,
            providerName: currentProvider.name,
            modelIDs: ["stale-model"],
            errorMessage: nil,
            sourceURL: nil,
            configurationFingerprint: ProviderModelDiscoveryFingerprint.value(for: oldProvider)
        )
        let state = ProviderModelDiscoveryState(results: [currentProvider.ref.description: result])
        let catalog = ProviderCatalog(providers: [currentProvider], candidates: [])

        var preferences = AppPreferences()
        preferences.setModelDiscoveryEnabled(false, for: currentProvider.ref)

        #expect(!preferences.isModelDiscoveryEnabled(for: currentProvider.ref))
        #expect(ProviderModelDiscovery.discoveredCandidates(from: state, catalog: catalog).isEmpty)
    }

    @Test
    func discoveredCandidatesKeepLastSuccessfulModelsWhenDiscoveryFails() throws {
        let provider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.deepseek.example/anthropic",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let fingerprint = ProviderModelDiscoveryFingerprint.value(for: provider)
        let succeeded = ProviderModelDiscoveryResult(
            providerRef: provider.ref,
            appType: provider.appType,
            providerName: provider.name,
            modelIDs: ["auto", "deepseek-v4-pro"],
            errorMessage: nil,
            sourceURL: "https://api.deepseek.example/v1/models",
            updatedAt: Date(timeIntervalSince1970: 1),
            configurationFingerprint: fingerprint
        )
        var state = ProviderModelDiscoveryState(results: [provider.ref.description: succeeded])
        state.upsert(ProviderModelDiscoveryResult(
            providerRef: provider.ref,
            appType: provider.appType,
            providerName: provider.name,
            modelIDs: [],
            errorMessage: "timeout",
            sourceURL: "https://api.deepseek.example/v1/models",
            updatedAt: Date(timeIntervalSince1970: 2),
            configurationFingerprint: fingerprint
        ))

        let catalog = ProviderCatalog(providers: [provider], candidates: [])
        let candidates = ProviderModelDiscovery.discoveredCandidates(from: state, catalog: catalog)

        #expect(state.results[provider.ref.description]?.modelIDs == ["auto", "deepseek-v4-pro"])
        #expect(candidates.map(\.logicalModel) == ["auto", "deepseek-v4-pro"])
        #expect(candidates.allSatisfy { $0.source == .staleDiscovered })
    }
}
