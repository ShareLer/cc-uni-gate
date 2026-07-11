@testable import UniGateApp
import Foundation
import UniGateCore
import Testing

@MainActor
struct UniGateAppStateTests {
    @Test
    func appTypesIncludeProvidersThatDoNotHaveModelsYet() {
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(
            providers: [codexProvider(id: "official", name: "Codex 官方")],
            candidates: []
        )

        #expect(state.appTypes == [UniGateAppRegistry.codex])
        #expect(state.currentModelDiscoveryItems.map(\.provider.id) == ["official"])
    }

    @Test
    func defaultAppPrefersAnAppWithRoutesOverAProviderOnlyApp() {
        let official = ImportedProvider(
            id: "official",
            appType: UniGateAppRegistry.codex,
            name: "Codex 官方",
            category: "official",
            sortIndex: nil,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: CodexOfficial.backendBaseURLString,
            hasSecret: false,
            settings: [:],
            meta: [:],
            backendKind: .codexOfficial
        )
        let providerOnly = ImportedProvider(
            id: "claude-provider-only",
            appType: UniGateAppRegistry.claudeCode,
            name: "Claude Provider",
            category: nil,
            sortIndex: nil,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [:],
            meta: [:]
        )
        let discovered = candidate(
            provider: official,
            logicalModel: "gpt-5.5-codex",
            source: .discovered
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(
            providers: [providerOnly, official],
            candidates: [discovered]
        )

        #expect(state.appTypes.contains(providerOnly.appType))
        #expect(state.currentAppType == UniGateAppRegistry.codex)
    }

    @Test
    func officialCodexDiscoveredCandidatesRemainSelectableWithoutCcSwitchScope() throws {
        let provider = ImportedProvider(
            id: "official",
            appType: UniGateAppRegistry.codex,
            name: "Codex 官方",
            category: "official",
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: CodexOfficial.backendBaseURLString,
            hasSecret: false,
            settings: [:],
            meta: [:],
            backendKind: .codexOfficial
        )
        let discovered = candidate(
            provider: provider,
            logicalModel: "gpt-5.5-codex",
            source: .discovered
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(providers: [provider], candidates: [discovered])
        state.uniGateModelScope = UniGateModelScope()

        let group = try #require(state.displayRouteGroups.first)

        #expect(group.routeKey == discovered.routeKey)
        #expect(state.candidates(for: group).map(\.providerRef) == [provider.ref])
        #expect(state.customModelBaseCandidates().map(\.providerRef) == [provider.ref])
    }

    @Test
    func officialCodexRouteShowsSameNameThirdPartyCandidatesWithoutCcSwitchScope() throws {
        let official = ImportedProvider(
            id: "official",
            appType: UniGateAppRegistry.codex,
            name: "Codex 官方",
            category: "official",
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: CodexOfficial.backendBaseURLString,
            hasSecret: false,
            settings: [:],
            meta: [:],
            backendKind: .codexOfficial
        )
        let thirdParty = codexProvider(id: "ahoo-gpt", name: "ahoo-gpt")
        let officialCandidate = candidate(
            provider: official,
            logicalModel: "gpt-5.6-luna",
            source: .discovered
        )
        let thirdPartyCandidate = candidate(
            provider: thirdParty,
            logicalModel: "gpt-5.6-luna",
            source: .discovered
        )
        let state = UniGateAppState()
        state.catalog = ProviderCatalog(
            providers: [official, thirdParty],
            candidates: [officialCandidate, thirdPartyCandidate]
        )
        state.uniGateModelScope = UniGateModelScope()

        let group = try #require(state.displayRouteGroups.first)

        #expect(Set(state.candidates(for: group).map(\.providerRef)) == [official.ref, thirdParty.ref])
    }

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

    @Test
    func codexOAuthStateDefaultsToSignedOutAndAcceptsUpdates() {
        let state = UniGateAppState()
        let providerRef = ProviderRef(appType: "codex", id: "official")

        #expect(state.codexOAuthState(for: providerRef) == .signedOut)

        state.updateCodexOAuthState(.signedIn(email: "user@example.com"), for: providerRef)

        #expect(state.codexOAuthState(for: providerRef) == .signedIn(email: "user@example.com"))
        #expect(state.codexOAuthError(for: providerRef) == nil)
    }

    @Test
    func loginCodexOfficialPublishesReturnedStateAndClearsProgress() async {
        let state = UniGateAppState()
        let providerRef = ProviderRef(appType: "codex", id: "official")
        var receivedProviderRef: ProviderRef?
        state.onLoginCodexOfficial = { ref in
            receivedProviderRef = ref
            return .signedIn(email: "user@example.com")
        }

        await state.loginCodexOfficial(providerRef)

        #expect(receivedProviderRef == providerRef)
        #expect(state.codexOAuthState(for: providerRef) == .signedIn(email: "user@example.com"))
        #expect(state.codexOAuthOperation(for: providerRef) == nil)
        #expect(state.codexOAuthError(for: providerRef) == nil)
    }

    @Test
    func loginCodexOfficialPublishesErrorsWithoutDiscardingExistingState() async {
        let state = UniGateAppState()
        let providerRef = ProviderRef(appType: "codex", id: "official")
        state.updateCodexOAuthState(.expired(email: "user@example.com"), for: providerRef)
        state.onLoginCodexOfficial = { _ in
            throw OAuthTestError.loginFailed
        }

        await state.loginCodexOfficial(providerRef)

        #expect(state.codexOAuthState(for: providerRef) == .expired(email: "user@example.com"))
        #expect(state.codexOAuthOperation(for: providerRef) == nil)
        #expect(state.codexOAuthError(for: providerRef) == "登录失败")
    }

    @Test
    func logoutCodexOfficialPublishesSignedOutState() async {
        let state = UniGateAppState()
        let providerRef = ProviderRef(appType: "codex", id: "official")
        var receivedProviderRef: ProviderRef?
        state.updateCodexOAuthState(.signedIn(email: "user@example.com"), for: providerRef)
        state.onLogoutCodexOfficial = { ref in
            receivedProviderRef = ref
        }

        await state.logoutCodexOfficial(providerRef)

        #expect(receivedProviderRef == providerRef)
        #expect(state.codexOAuthState(for: providerRef) == .signedOut)
        #expect(state.codexOAuthOperation(for: providerRef) == nil)
        #expect(state.codexOAuthError(for: providerRef) == nil)
    }

    private enum OAuthTestError: LocalizedError {
        case loginFailed

        var errorDescription: String? {
            "登录失败"
        }
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
