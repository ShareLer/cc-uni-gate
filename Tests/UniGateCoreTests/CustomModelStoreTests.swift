import UniGateCore
import Foundation
import Testing

struct CustomModelStoreTests {
    @Test
    func selectedTargetDoesNotFallBackWhenSelectionIsMissing() {
        let target1 = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5"),
            providerRef: ProviderRef(appType: "codex", id: "p1")
        )
        let target2 = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.6"),
            providerRef: ProviderRef(appType: "codex", id: "p1")
        )
        let definition = CustomModelDefinition(
            appType: "codex",
            name: "customer_model",
            targets: [target1, target2],
            selectedTargetID: UUID()
        )

        #expect(definition.selectedTarget == nil)
    }

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
    func selectedTargetMatchesRealCatalogCandidates() throws {
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
        let target = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5"),
            providerRef: provider.ref
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
        let syntheticCandidate = ModelCandidate(
            logicalModel: "customer_model",
            providerRef: ProviderRef(appType: "codex", id: "synthetic"),
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "gpt-5.5",
            supportsLongContext: false,
            upstreamProviderRef: provider.ref
        )
        let definition = CustomModelDefinition(
            appType: "codex",
            name: "customer_model",
            targets: [target],
            selectedTargetID: target.id
        )

        #expect(definition.hasSelectedTarget(in: ProviderCatalog(providers: [provider], candidates: [baseCandidate])))
        #expect(!definition.hasSelectedTarget(in: ProviderCatalog(providers: [provider], candidates: [syntheticCandidate])))
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

    @Test
    func expandedCustomModelCandidatesPreserveStaleDiscoverySource() throws {
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
        let staleBase = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .staleDiscovered
        )
        let target = CustomModelTarget(routeKey: staleBase.routeKey, providerRef: provider.ref)
        let catalog = ProviderCatalog(providers: [provider], candidates: [staleBase])
        let state = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [target],
                selectedTargetID: target.id
            )
        ])

        let expanded = state.expandedCandidates(from: catalog)
        let candidate = try #require(expanded.first)

        #expect(candidate.source == .staleDiscovered)
        #expect(candidate.isDiscoveryStale(in: ProviderCatalog(
            providers: [provider],
            candidates: catalog.candidates + expanded
        )))
    }

    @Test
    func baseCandidatesDeduplicateClaudeDesktopRoutesByUpstreamTarget() throws {
        let provider = ImportedProvider(
            id: "desktop",
            appType: "claude-desktop",
            name: "DeepSeek Desktop",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.deepseek.example",
            hasSecret: true,
            settings: ["auth": .object(["ANTHROPIC_AUTH_TOKEN": .string("key-1")])],
            meta: [:]
        )
        let flash = ModelCandidate(
            logicalModel: "deepseek-v4-flash",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-flash",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "DeepSeek V4 Flash",
            supportsLongContext: true
        )
        let pro = ModelCandidate(
            logicalModel: "deepseek-v4-pro",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-pro",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "DeepSeek V4 Pro",
            supportsLongContext: true
        )
        let catalog = ProviderCatalog(
            providers: [provider],
            candidates: [flash, pro]
        )

        let baseCandidates = CustomModelState().baseCandidates(from: catalog)

        #expect(baseCandidates.map(\.upstreamModel) == ["deepseek-v4-flash", "deepseek-v4-pro"])
        #expect(baseCandidates.map(\.logicalModel) == ["deepseek-v4-flash", "deepseek-v4-pro"])
    }

    @Test
    func baseCandidatesPreferConfiguredCandidateOverDiscoveredDuplicate() throws {
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
        let discovered = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: true,
            source: .discovered
        )
        let configured = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "Configured Qwen",
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(
            providers: [provider],
            candidates: [discovered, configured]
        )

        let baseCandidates = CustomModelState().baseCandidates(from: catalog)

        #expect(baseCandidates.count == 1)
        #expect(baseCandidates.first?.source == .configured)
        #expect(baseCandidates.first?.label == "Configured Qwen")
    }

    @Test
    func baseCandidatesIncludeDiscoveredOnlyTargetsForCustomModels() throws {
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
        let discovered = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .discovered
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [discovered])

        let baseCandidates = CustomModelState().baseCandidates(from: catalog)

        #expect(baseCandidates.map(\.logicalModel) == ["qwen3.6"])
        #expect(baseCandidates.first?.source == .discovered)
    }
}
