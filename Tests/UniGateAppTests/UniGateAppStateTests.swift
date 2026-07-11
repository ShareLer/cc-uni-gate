@testable import UniGateApp
import UniGateCore
import Testing

@MainActor
struct UniGateAppStateTests {
    @Test
    func customModelBaseCandidatesHideConfiguredModelsMissingFromCurrentDiscovery() {
        let provider = codexProvider()
        let staleConfigured = candidate(provider: provider, logicalModel: "gpt-5.5")
        let discovered = [
            candidate(provider: provider, logicalModel: "gpt-5.4", source: .discovered),
            candidate(provider: provider, logicalModel: "gpt-5.4-mini", source: .discovered)
        ]
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(
            providers: [provider],
            candidates: [staleConfigured] + discovered
        )

        let candidates = state.customModelBaseCandidates()

        #expect(candidates.map(\.logicalModel) == ["gpt-5.4", "gpt-5.4-mini"])
    }

    @Test
    func customModelBaseCandidatesPreserveExistingTargetsMissingFromCurrentDiscovery() {
        let provider = codexProvider()
        let staleConfigured = candidate(provider: provider, logicalModel: "gpt-5.5")
        let discovered = candidate(provider: provider, logicalModel: "gpt-5.4", source: .discovered)
        let target = CustomModelTarget(routeKey: staleConfigured.routeKey, providerRef: provider.ref)
        let definition = CustomModelDefinition(
            appType: "codex",
            name: "uni",
            targets: [target],
            selectedTargetID: target.id
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(
            providers: [provider],
            candidates: [staleConfigured, discovered]
        )
        state.customModels = CustomModelState(models: [definition])

        let candidates = state.customModelBaseCandidates(preserving: definition)

        #expect(candidates.map(\.logicalModel) == ["gpt-5.5", "gpt-5.4"])
    }

    @Test
    func customModelBaseCandidatesIncludeBaseTargetsWhoseRouteKeyMatchesAnotherCustomModel() {
        let provider = codexProvider(id: "ahoo", name: "ahoo-gpt-plus")
        let discovered = candidate(provider: provider, logicalModel: "gpt-5.5", source: .discovered)
        let editingDefinition = CustomModelDefinition(
            appType: "codex",
            name: "gpt-5.4",
            forceEnabled: true,
            targets: []
        )
        let otherCustomDefinition = CustomModelDefinition(
            appType: "codex",
            name: "gpt-5.5",
            targets: []
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(providers: [provider], candidates: [discovered])
        state.customModels = CustomModelState(models: [
            editingDefinition,
            otherCustomDefinition
        ])

        let candidates = state.customModelBaseCandidates(preserving: editingDefinition)

        #expect(candidates.map(\.providerName) == ["ahoo-gpt-plus"])
        #expect(candidates.map(\.logicalModel) == ["gpt-5.5"])
    }

    @Test
    func customModelBaseCandidatesIncludeClaudeCodeTargetsWhoseRouteKeyMatchesAnotherCustomModel() {
        let provider = provider(id: "claude-upstream", appType: "claude", name: "Claude Upstream")
        let discovered = candidate(provider: provider, logicalModel: "deepseek-v4-pro", source: .discovered)
        let editingDefinition = CustomModelDefinition(
            appType: "claude",
            name: "daily-router",
            targets: []
        )
        let otherCustomDefinition = CustomModelDefinition(
            appType: "claude",
            name: "deepseek-v4-pro",
            targets: []
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(providers: [provider], candidates: [discovered])
        state.customModels = CustomModelState(models: [
            editingDefinition,
            otherCustomDefinition
        ])

        let candidates = state.customModelBaseCandidates(preserving: editingDefinition)

        #expect(candidates.map(\.providerName) == ["Claude Upstream"])
        #expect(candidates.map(\.logicalModel) == ["deepseek-v4-pro"])
    }

    @Test
    func customModelBaseCandidatesIncludeClaudeDesktopTargetsWhoseRouteKeyMatchesAnotherCustomModel() {
        let provider = provider(id: "desktop-upstream", appType: "claude-desktop", name: "Desktop Upstream")
        let discovered = candidate(provider: provider, logicalModel: "auto", source: .discovered)
        let editingDefinition = CustomModelDefinition(
            appType: "claude-desktop",
            name: "union-model",
            targets: []
        )
        let otherCustomDefinition = CustomModelDefinition(
            appType: "claude-desktop",
            name: "auto",
            targets: []
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(providers: [provider], candidates: [discovered])
        state.customModels = CustomModelState(models: [
            editingDefinition,
            otherCustomDefinition
        ])

        let candidates = state.customModelBaseCandidates(preserving: editingDefinition)

        #expect(candidates.map(\.providerName) == ["Desktop Upstream"])
        #expect(candidates.map(\.logicalModel) == ["auto"])
    }

    @Test
    func saveCustomModelRejectsNameMatchingVisibleBaseModel() {
        let provider = codexProvider()
        let baseCandidate = candidate(provider: provider, logicalModel: "gpt-5.5")
        let target = CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(providers: [provider], candidates: [baseCandidate])
        state.uniGateModelScope = UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]])
        var didPersist = false
        state.onSaveSettings = { _, _ in didPersist = true }

        let didSave = state.saveCustomModel(CustomModelDefinition(
            appType: "codex",
            name: "gpt-5.5",
            targets: [target],
            selectedTargetID: target.id
        ))

        #expect(!didSave)
        #expect(!didPersist)
    }

    @Test
    func existingNameConflictIsShownOnceAndCannotBeOperated() throws {
        let provider = codexProvider()
        let baseCandidate = candidate(provider: provider, logicalModel: "gpt-5.5")
        let target = CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(providers: [provider], candidates: [baseCandidate])
        state.uniGateModelScope = UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]])
        state.customModels = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "gpt-5.5",
                targets: [target],
                selectedTargetID: target.id
            )
        ])

        let groups = state.displayRouteGroups.filter { $0.routeKey == baseCandidate.routeKey }
        let group = try #require(groups.first)

        #expect(groups.count == 1)
        if case .nameConflict = state.customModelAvailability(for: baseCandidate.routeKey) {
            #expect(!state.isRouteOperable(group))
        } else {
            Issue.record("Expected custom model name conflict")
        }
    }

    @Test
    func saveCustomModelRejectsAnotherCustomModelWithSameRouteKey() {
        let provider = codexProvider()
        let baseCandidate = candidate(provider: provider, logicalModel: "gpt-5.5")
        let target = CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
        let existing = CustomModelDefinition(
            appType: "codex",
            name: "customer_model",
            targets: [target],
            selectedTargetID: target.id
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(providers: [provider], candidates: [baseCandidate])
        state.customModels = CustomModelState(models: [existing])
        var didPersist = false
        state.onSaveSettings = { _, _ in didPersist = true }

        let didSave = state.saveCustomModel(CustomModelDefinition(
            appType: "codex",
            name: "customer_model",
            targets: [target],
            selectedTargetID: target.id
        ))

        #expect(!didSave)
        #expect(!didPersist)
    }

    private func codexProvider(id: String = "p1", name: String = "Provider 1") -> ImportedProvider {
        provider(id: id, appType: "codex", name: name)
    }

    private func provider(id: String, appType: String, name: String) -> ImportedProvider {
        ImportedProvider(
            id: id,
            appType: appType,
            name: name,
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: appType == "codex" ? .openaiResponses : .anthropic,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
    }

    private func candidate(
        provider: ImportedProvider,
        logicalModel: String,
        source: ModelCandidateSource = .configured
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: logicalModel,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: provider.appType == "codex" ? .codexResponses : .anthropicMessages,
            apiFormat: provider.apiFormat,
            upstreamModel: logicalModel,
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: source
        )
    }
}
