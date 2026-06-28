import UniGateCore
import Testing

struct UniGateAppRegistryTests {
    @Test
    func scopedAppsDriveRouteVisibility() {
        #expect(UniGateAppRegistry.uniGateScopedAppTypes == [
            "codex",
            "claude",
            "claude-desktop"
        ])
        for appType in UniGateAppRegistry.uniGateScopedAppTypes {
            #expect(ModelRouteVisibility.isUniGateScopedApp(appType))
        }
        #expect(!ModelRouteVisibility.isUniGateScopedApp("gemini"))
    }

    @Test
    func claudeLikeAppsShareProtocolAndTransformRules() {
        for appType in [UniGateAppRegistry.claudeCode, UniGateAppRegistry.claudeDesktop] {
            #expect(UniGateAppRegistry.isClaudeLike(appType))
            #expect(UniGateAppRegistry.clientProtocol(for: appType) == .anthropicMessages)
            #expect(UniGateAppRegistry.requiresTransform(appType: appType, apiFormat: .anthropic) == false)
            #expect(UniGateAppRegistry.requiresTransform(appType: appType, apiFormat: .openaiResponses) == true)
        }
    }

    @Test
    func codexUsesResponsesProtocolAndOpenAITransformRules() {
        #expect(!UniGateAppRegistry.isClaudeLike(UniGateAppRegistry.codex))
        #expect(UniGateAppRegistry.clientProtocol(for: UniGateAppRegistry.codex) == .codexResponses)
        #expect(UniGateAppRegistry.requiresTransform(appType: UniGateAppRegistry.codex, apiFormat: .openaiResponses) == false)
        #expect(UniGateAppRegistry.requiresTransform(appType: UniGateAppRegistry.codex, apiFormat: .openaiChat) == false)
        #expect(UniGateAppRegistry.requiresTransform(appType: UniGateAppRegistry.codex, apiFormat: .anthropic) == true)
    }

    @Test
    func nonScopedAppsDoNotInheritUniGateProtocolRules() {
        #expect(!UniGateAppRegistry.isUniGateScoped("gemini"))
        #expect(UniGateAppRegistry.clientProtocol(for: "gemini") == nil)
        #expect(UniGateAppRegistry.requiresTransform(appType: "gemini", apiFormat: .geminiNative) == nil)
    }

    @Test
    func customCandidatesSeedVisibleRouteKeys() {
        let provider = ImportedProvider(
            id: "custom",
            appType: "codex",
            name: "Custom Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["env": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [
            ModelCandidate(
                logicalModel: "uni",
                providerRef: provider.ref,
                providerName: provider.name,
                appType: provider.appType,
                clientProtocol: .codexResponses,
                apiFormat: .openaiResponses,
                upstreamModel: "uni",
                baseURL: provider.baseURL,
                requiresTransform: false,
                label: nil,
                supportsLongContext: false,
                source: .custom
            )
        ])

        let routeKeys = ModelRouteVisibility.configuredBaseRouteKeys(
            catalog: catalog,
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope()
        )

        #expect(routeKeys.map(\.description) == ["codex:uni"])
    }

    @Test
    func proxyRequestPathsUseSharedAppTypeDefaults() {
        #expect(ProxyRequestPath("/v1/messages") == .proxy(
            protocolKind: .anthropicMessages,
            appType: UniGateAppRegistry.claudeCode
        ))
        #expect(ProxyRequestPath("/claude-desktop/v1/messages") == .proxy(
            protocolKind: .anthropicMessages,
            appType: UniGateAppRegistry.claudeDesktop
        ))
        #expect(ProxyRequestPath("/responses") == .proxy(
            protocolKind: .codexResponses,
            appType: UniGateAppRegistry.codex
        ))
        #expect(ProxyRequestPath("/openai/v1/models") == .models(appType: UniGateAppRegistry.codex))
    }
}
