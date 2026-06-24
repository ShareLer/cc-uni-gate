import UniGateCore
import Foundation
import Testing

struct ProxyResolverTests {
    @Test
    func resolvesProtocolPreservingCodexRoute() throws {
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
        let candidate = candidate(provider: provider, requiresTransform: false)
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            path: "/openai/v1/responses",
            body: Data(#"{"model":"gpt-5.5","input":"hello"}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://api.example.com/v1/responses")
        #expect(resolved.requestedModel == "gpt-5.5")
        #expect(resolved.routeKey.description == "codex:gpt-5.5")
        #expect(resolved.headers["authorization"] == "Bearer key-1")
        #expect(resolved.outboundModel == "gpt-5.5")
        let outbound = try JSONSerialization.jsonObject(with: resolved.body) as? [String: Any]
        #expect(outbound?["model"] as? String == "gpt-5.5")
        #expect(outbound?["input"] as? String == "hello")
    }

    @Test
    func scopedProxyCatalogRejectsCodexModelOutsideUniGateScope() throws {
        let dasu = ImportedProvider(
            id: "dasu",
            appType: "codex",
            name: "dasu-gpt-plus-0.077",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://dasuapi.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("dasu-key")])],
            meta: [:]
        )
        let free = ImportedProvider(
            id: "gpt-free",
            appType: "codex",
            name: "gpt-free",
            category: nil,
            sortIndex: 2,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://free.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("free-key")])],
            meta: [:]
        )
        let rawCatalog = ProviderCatalog(providers: [dasu, free], candidates: [
            candidate(provider: dasu, logicalModel: "gpt-5.4"),
            candidate(provider: free, logicalModel: "gpt-5.5")
        ])
        let scopedCatalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            customModels: CustomModelState()
        )
        let routes = RouteStore.defaultState(candidates: scopedCatalog.candidates)

        #expect(scopedCatalog.routeKeys.map { $0.description } == ["codex:gpt-5.5"])
        #expect(routes.routes["codex:gpt-5.4"] == nil)
        #expect(throws: ProxyResolverError.self) {
            try ProxyResolver.resolveRoute(
                catalog: scopedCatalog,
                routes: routes,
                protocolKind: .codexResponses,
                appType: "codex",
                path: "/codex/responses",
                body: Data(#"{"model":"gpt-5.4","input":"hello"}"#.utf8)
            )
        }
    }

    @Test
    func modelListingUsesFullCatalogWhileProxyUsesScopedCatalog() throws {
        let configured = ImportedProvider(
            id: "configured",
            appType: "codex",
            name: "Configured Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://configured.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("configured-key")])],
            meta: [:]
        )
        let discovered = ImportedProvider(
            id: "discovered",
            appType: "codex",
            name: "Discovered Provider",
            category: nil,
            sortIndex: 2,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://discovered.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("discovered-key")])],
            meta: [:]
        )
        let fullCatalog = ProviderCatalog(providers: [configured, discovered], candidates: [
            candidate(provider: configured, logicalModel: "gpt-5.5"),
            ModelCandidate(
                logicalModel: "qwen3.6",
                providerRef: discovered.ref,
                providerName: discovered.name,
                appType: discovered.appType,
                clientProtocol: .codexResponses,
                apiFormat: discovered.apiFormat,
                upstreamModel: "qwen3.6",
                baseURL: discovered.baseURL,
                requiresTransform: false,
                label: nil,
                supportsLongContext: false,
                source: .discovered
            )
        ])
        let scopedCatalog = fullCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            customModels: CustomModelState()
        )

        #expect(ProviderModelListing.routeKeys(from: fullCatalog, appType: "codex").map(\.logicalModel) == [
            "gpt-5.5",
            "qwen3.6"
        ])
        #expect(scopedCatalog.routeKeys.map(\.logicalModel) == ["gpt-5.5"])
    }

    @Test
    func scopedProxyCatalogIncludesForceEnabledCustomModelsOutsideUniGateScope() throws {
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
        let baseCandidate = candidate(provider: provider, logicalModel: "qwen3.6")
        let target = CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
        let rawCatalog = ProviderCatalog(providers: [provider], candidates: [baseCandidate])
        let customModels = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                forceEnabled: true,
                targets: [target],
                selectedTargetID: target.id
            )
        ])

        let scopedCatalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            customModels: customModels
        )
        let routes = RouteStore.defaultState(candidates: scopedCatalog.candidates)

        #expect(scopedCatalog.routeKeys.map(\.description) == ["codex:customer_model"])
        #expect(routes.routes["codex:customer_model"] != nil)
    }

    @Test
    func scopedProxyCatalogExcludesUnconfiguredCustomModelsWithoutForceEnabled() throws {
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
        let baseCandidate = candidate(provider: provider, logicalModel: "qwen3.6")
        let target = CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
        let rawCatalog = ProviderCatalog(providers: [provider], candidates: [baseCandidate])
        let customModels = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [target],
                selectedTargetID: target.id
            )
        ])

        let scopedCatalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            customModels: customModels
        )

        #expect(scopedCatalog.routeKeys.isEmpty)
    }

    @Test
    func resolvesCcSwitchStyleCodexRootPath() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com/v1",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let candidate = candidate(provider: provider, requiresTransform: false)
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            appType: "codex",
            path: "/v1/responses",
            body: Data(#"{"model":"gpt-5.5","input":"hello"}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://api.example.com/v1/responses")
    }

    @Test
    func resolvesExplicitCodexPrefixPath() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com/v1",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let candidate = candidate(provider: provider, requiresTransform: false)
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            appType: "codex",
            path: "/codex/responses",
            body: Data(#"{"model":"gpt-5.5","input":"hello"}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://api.example.com/v1/responses")
    }

    @Test
    func bridgesCodexResponsesRequestToOpenAIChatUpstream() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiChat,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let candidate = candidate(provider: provider, requiresTransform: false)
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            path: "/openai/v1/responses",
            body: Data(#"{"model":"gpt-5.5","input":"hello","max_output_tokens":8}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(resolved.responseTransform == .openAIChatToCodexResponse)
        let outbound = try JSONSerialization.jsonObject(with: resolved.body) as? [String: Any]
        #expect(outbound?["model"] as? String == "gpt-5.5")
        #expect(outbound?["max_tokens"] as? Int == 8)
        let messages = try #require(outbound?["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "hello")
    }

    @Test
    func convertsOpenAIChatResponseToCodexResponsesShape() throws {
        let response = try CodexChatBridge.responsesBody(
            from: [
                "id": "chatcmpl-1",
                "created": 1_781_845_352,
                "model": "deepseek-v4-flash",
                "choices": [[
                    "message": ["role": "assistant", "content": "OK"],
                    "finish_reason": "stop"
                ]],
                "usage": [
                    "prompt_tokens": 7,
                    "completion_tokens": 1,
                    "total_tokens": 8
                ]
            ],
            fallbackModel: "deepseek-v4-flash"
        )

        #expect(response["id"] as? String == "chatcmpl-1")
        #expect(response["object"] as? String == "response")
        #expect(response["output_text"] as? String == "OK")
        let output = try #require(response["output"] as? [[String: Any]])
        #expect(output.first?["role"] as? String == "assistant")
        let usage = try #require(response["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 7)
        #expect(usage["output_tokens"] as? Int == 1)
    }

    @Test
    func usesAnthropicApiKeyHeader() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://anthropic.example.com/v1",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_API_KEY": .string("claude-key")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "claude-sonnet-4-6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "upstream-sonnet",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            path: "/anthropic/v1/messages",
            body: Data(#"{"model":"claude-sonnet-4-6","messages":[]}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://anthropic.example.com/v1/messages")
        #expect(resolved.headers["x-api-key"] == "claude-key")
        let outbound = try JSONSerialization.jsonObject(with: resolved.body) as? [String: Any]
        #expect(outbound?["model"] as? String == "upstream-sonnet")
    }

    @Test
    func resolvesCcSwitchStyleClaudeRootPath() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://anthropic.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("claude-token")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "claude-sonnet-4-6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "upstream-sonnet",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            appType: "claude",
            path: "/v1/messages",
            body: Data(#"{"model":"claude-sonnet-4-6","messages":[]}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://anthropic.example.com/v1/messages")
        #expect(resolved.headers["authorization"] == "Bearer claude-token")
    }

    @Test
    func resolvesExplicitClaudeCodePrefixPath() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://anthropic.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("claude-token")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "claude-sonnet-4-6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "upstream-sonnet",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            appType: "claude",
            path: "/claude-code/v1/messages",
            body: Data(#"{"model":"claude-sonnet-4-6","messages":[]}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://anthropic.example.com/v1/messages")
    }

    @Test
    func resolvesExplicitClaudeDesktopPath() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude-desktop",
            name: "Desktop Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://desktop.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("desktop-token")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "desktop-sonnet",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "desktop-sonnet",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            appType: "claude-desktop",
            path: "/claude-desktop/v1/messages",
            body: Data(#"{"model":"desktop-sonnet","messages":[]}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://desktop.example.com/v1/messages")
    }

    @Test
    func resolvesClaudeDesktopRequestByConfiguredUpstreamModel() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude-desktop",
            name: "Desktop Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://desktop.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("desktop-token")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "deepseek-v4-pro",
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
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            appType: "claude-desktop",
            path: "/claude-desktop/v1/messages",
            body: Data(#"{"model":"deepseek-v4-pro","messages":[]}"#.utf8)
        )

        #expect(resolved.outboundModel == "deepseek-v4-pro")
        let outbound = try JSONSerialization.jsonObject(with: resolved.body) as? [String: Any]
        #expect(outbound?["model"] as? String == "deepseek-v4-pro")
    }

    @Test
    func rejectsClaudeDesktopRequestWhenRealModelRouteIsNotConfigured() throws {
        let dcc = ImportedProvider(
            id: "dcc",
            appType: "claude-desktop",
            name: "DCC",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://dcc.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("dcc-token")])],
            meta: [:]
        )
        let deepseek = ImportedProvider(
            id: "deepseek",
            appType: "claude-desktop",
            name: "DeepSeek",
            category: nil,
            sortIndex: 2,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://deepseek.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("deepseek-token")])],
            meta: [:]
        )
        let routeKey = ModelRouteKey(appType: "claude-desktop", logicalModel: "auto-max")
        let stale = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: dcc.ref,
            providerName: dcc.name,
            appType: routeKey.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "auto-max",
            baseURL: dcc.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let target = ModelCandidate(
            logicalModel: "deepseek-v4-flash",
            providerRef: deepseek.ref,
            providerName: deepseek.name,
            appType: routeKey.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-flash",
            baseURL: deepseek.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: true
        )
        let catalog = ProviderCatalog(providers: [dcc, deepseek], candidates: [stale, target])
        let routes = RouteState(routes: [
            routeKey.description: ActiveRoute(
                appType: routeKey.appType,
                logicalModel: routeKey.logicalModel,
                providerRef: dcc.ref,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ])

        #expect(throws: ProxyResolverError.self) {
            try ProxyResolver.resolveRoute(
                catalog: catalog,
                routes: routes,
                protocolKind: .anthropicMessages,
                appType: "claude-desktop",
                path: "/claude-desktop/v1/messages",
                body: Data(#"{"model":"deepseek-v4-flash","messages":[]}"#.utf8)
            )
        }
    }

    @Test
    func mapsClaudeRoleRequestToConfiguredRouteAndStripsOneMSuffix() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://anthropic.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("claude-token")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "claude-sonnet-4-6",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-pro[1M]",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: true
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            appType: "claude",
            path: "/claude-code/v1/messages",
            body: Data(#"{"model":"claude-sonnet-4-6-20260101[1M]","messages":[]}"#.utf8)
        )

        #expect(resolved.outboundModel == "deepseek-v4-pro")
        let outbound = try JSONSerialization.jsonObject(with: resolved.body) as? [String: Any]
        #expect(outbound?["model"] as? String == "deepseek-v4-pro")
    }

    @Test
    func resolvesClaudeRequestToCanonicalOneMRouteAlias() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://anthropic.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("claude-token")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "deepseek-v4-pro",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-pro[1M]",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: true
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let plain = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            appType: "claude",
            path: "/claude-code/v1/messages",
            body: Data(#"{"model":"deepseek-v4-pro","messages":[]}"#.utf8)
        )
        let marked = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .anthropicMessages,
            appType: "claude",
            path: "/claude-code/v1/messages",
            body: Data(#"{"model":"deepseek-v4-pro[1M]","messages":[]}"#.utf8)
        )

        #expect(plain.outboundModel == "deepseek-v4-pro")
        #expect(marked.outboundModel == "deepseek-v4-pro")
    }

    @Test
    func resolvesCustomModelAliasToSelectedTargetUpstreamModel() throws {
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
            upstreamModel: "real-gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let imported = ProviderCatalog(providers: [provider], candidates: [baseCandidate])
        let custom = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [
                    CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
                ]
            )
        ])
        let catalog = ProviderCatalog(
            providers: imported.providers,
            candidates: imported.candidates + custom.expandedCandidates(from: imported)
        )
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            appType: "codex",
            path: "/codex/responses",
            body: Data(#"{"model":"customer_model","input":"hello"}"#.utf8)
        )

        #expect(resolved.outboundModel == "real-gpt-5.5")
        let outbound = try JSONSerialization.jsonObject(with: resolved.body) as? [String: Any]
        #expect(outbound?["model"] as? String == "real-gpt-5.5")
    }

    @Test
    func resolvesCustomModelAliasTargetsFromSameProviderIndependently() throws {
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
        let imported = ProviderCatalog(providers: [provider], candidates: [fast, pro])
        let custom = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [fastTarget, proTarget],
                selectedTargetID: proTarget.id
            )
        ])
        let catalog = ProviderCatalog(
            providers: imported.providers,
            candidates: imported.candidates + custom.expandedCandidates(from: imported)
        )
        let customCandidates = catalog.candidates(for: ModelRouteKey(appType: "codex", logicalModel: "customer_model"))
        let fastCandidate = try #require(customCandidates.first { $0.upstreamModel == "fast-upstream" })
        var routes = RouteStore.defaultState(candidates: catalog.candidates)
        routes.routes["codex:customer_model"] = ActiveRoute(
            appType: "codex",
            logicalModel: "customer_model",
            providerRef: fastCandidate.providerRef,
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            appType: "codex",
            path: "/codex/responses",
            body: Data(#"{"model":"customer_model","input":"hello"}"#.utf8)
        )

        #expect(customCandidates.count == 2)
        #expect(RouteStore.defaultState(candidates: catalog.candidates).routes["codex:customer_model"]?.providerRef != fastCandidate.providerRef)
        #expect(resolved.outboundModel == "fast-upstream")
    }

    @Test
    func rejectsRequestsWhenConfiguredCustomModelTargetIsUnavailable() throws {
        let staleProvider = ImportedProvider(
            id: "stale",
            appType: "codex",
            name: "Stale Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://stale.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("stale-key")])],
            meta: [:]
        )
        let activeProvider = ImportedProvider(
            id: "active",
            appType: "codex",
            name: "Active Provider",
            category: nil,
            sortIndex: 2,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://active.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("active-key")])],
            meta: [:]
        )
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "customer_model")
        let activeCandidate = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: activeProvider.ref,
            providerName: activeProvider.name,
            appType: routeKey.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "active-upstream",
            baseURL: activeProvider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(providers: [staleProvider, activeProvider], candidates: [activeCandidate])
        let routes = RouteState(routes: [
            routeKey.description: ActiveRoute(
                appType: routeKey.appType,
                logicalModel: routeKey.logicalModel,
                providerRef: staleProvider.ref,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ])

        do {
            _ = try ProxyResolver.resolveRoute(
                catalog: catalog,
                routes: routes,
                protocolKind: .codexResponses,
                appType: "codex",
                path: "/codex/responses",
                body: Data(#"{"model":"customer_model","input":"hello"}"#.utf8)
            )
            #expect(Bool(false))
        } catch let error as ProxyResolverError {
            guard case let .unavailableRouteTarget(actualRouteKey, actualProviderRef) = error else {
                #expect(Bool(false))
                return
            }
            #expect(actualRouteKey == routeKey.description)
            #expect(actualProviderRef == staleProvider.ref.description)
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func resolvesExistingRoutesForStaleDiscoveredCandidates() throws {
        let provider = ImportedProvider(
            id: "discovered",
            appType: "codex",
            name: "Discovered Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://discovered.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("discovered-key")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
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
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteState(routes: [
            candidate.routeKey.description: ActiveRoute(
                appType: candidate.appType,
                logicalModel: candidate.logicalModel,
                providerRef: candidate.providerRef,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ])

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            appType: "codex",
            path: "/codex/responses",
            body: Data(#"{"model":"qwen3.6","input":"hello"}"#.utf8)
        )

        #expect(resolved.candidate.source == .staleDiscovered)
        #expect(resolved.outboundModel == "qwen3.6")
    }

    @Test
    func rejectsClaudeRoleFallbackWhenFableRouteIsAbsentForClaudeCode() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://anthropic.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_AUTH_TOKEN": .string("desktop-token")])],
            meta: [:]
        )
        let candidate = ModelCandidate(
            logicalModel: "claude-opus-4-8",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "opus-upstream",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        #expect(throws: ProxyResolverError.self) {
            try ProxyResolver.resolveRoute(
                catalog: catalog,
                routes: routes,
                protocolKind: .anthropicMessages,
                appType: "claude",
                path: "/claude-code/v1/messages",
                body: Data(#"{"model":"claude-fable-5","messages":[]}"#.utf8)
            )
        }
    }

    @Test
    func parsesCcSwitchStyleProxyPaths() {
        #expect(ProxyRequestPath("/v1/responses") == .proxy(protocolKind: .codexResponses, appType: "codex"))
        #expect(ProxyRequestPath("/v1/v1/responses") == .proxy(protocolKind: .codexResponses, appType: "codex"))
        #expect(ProxyRequestPath("/v1/chat/completions") == .proxy(protocolKind: .openaiChat, appType: "codex"))
        #expect(ProxyRequestPath("/v1/messages") == .proxy(protocolKind: .anthropicMessages, appType: "claude"))
        #expect(ProxyRequestPath("/codex/responses") == .proxy(protocolKind: .codexResponses, appType: "codex"))
        #expect(ProxyRequestPath("/codex/v1/chat/completions") == .proxy(protocolKind: .openaiChat, appType: "codex"))
        #expect(ProxyRequestPath("/claude-code/v1/messages") == .proxy(protocolKind: .anthropicMessages, appType: "claude"))
        #expect(ProxyRequestPath("/claude-desktop/v1/messages") == .proxy(protocolKind: .anthropicMessages, appType: "claude-desktop"))
        #expect(ProxyRequestPath("/v1/models") == .models(appType: nil))
        #expect(ProxyRequestPath("/codex/v1/models") == .models(appType: "codex"))
        #expect(ProxyRequestPath("/claude-code/v1/models") == .models(appType: "claude"))
        #expect(ProxyRequestPath("/claude-desktop/v1/models") == .models(appType: "claude-desktop"))
    }

    @Test
    func catalogAppliesProtocolOverrides() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiChat,
            baseURL: "https://api.example.com",
            hasSecret: false,
            settings: [:],
            meta: [:]
        )
        let catalog = ProviderCatalog(
            providers: [provider],
            candidates: [candidate(provider: provider, requiresTransform: true)]
        )

        let updated = catalog.applyingProtocolOverrides([
            provider.ref.description: .openaiResponses
        ])

        #expect(updated.providers.first?.apiFormat == .openaiResponses)
        #expect(updated.candidates.first?.apiFormat == .openaiResponses)
        #expect(updated.candidates.first?.requiresTransform == false)
    }

    @Test
    func resolvesRouteToDiscoveredProviderForConfiguredModel() throws {
        let discoveredProvider = ImportedProvider(
            id: "discovered",
            appType: "codex",
            name: "Discovered Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://discovered.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("discovered-key")])],
            meta: [:]
        )
        let configuredProvider = ImportedProvider(
            id: "configured",
            appType: "codex",
            name: "Configured Provider",
            category: nil,
            sortIndex: 2,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://configured.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("configured-key")])],
            meta: [:]
        )
        let discoveredCandidate = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: discoveredProvider.ref,
            providerName: discoveredProvider.name,
            appType: discoveredProvider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: discoveredProvider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .discovered
        )
        let configuredCandidate = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: configuredProvider.ref,
            providerName: configuredProvider.name,
            appType: configuredProvider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: configuredProvider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(
            providers: [discoveredProvider, configuredProvider],
            candidates: [configuredCandidate, discoveredCandidate]
        )
        let routeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        defer {
            try? FileManager.default.removeItem(at: routeFile.deletingLastPathComponent())
        }
        let store = RouteStore(fileURL: routeFile)
        let initial = try store.load(catalog: catalog)
        let routes = try store.switchRoute(
            initial,
            catalog: catalog,
            appType: "codex",
            logicalModel: "qwen3.6",
            providerRef: discoveredProvider.ref
        )

        let resolved = try ProxyResolver.resolveRoute(
            catalog: catalog,
            routes: routes,
            protocolKind: .codexResponses,
            appType: "codex",
            path: "/v1/responses",
            body: Data(#"{"model":"qwen3.6","input":"hello"}"#.utf8)
        )

        #expect(resolved.candidate.source == .discovered)
        #expect(resolved.providerName == discoveredProvider.name)
        #expect(resolved.outboundModel == "qwen3.6")
        #expect(resolved.upstreamURL.absoluteString == "https://discovered.example.com/v1/responses")
        #expect(resolved.headers["authorization"] == "Bearer discovered-key")
    }

    @Test
    func providerDisplayNameIncludesAppType() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude-desktop",
            name: "Dasu-gpt",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: nil,
            hasSecret: false,
            settings: [:],
            meta: [:]
        )

        #expect(provider.displayName == "Dasu-gpt · Claude Desktop")
    }

    private func candidate(
        provider: ImportedProvider,
        logicalModel: String = "gpt-5.5",
        requiresTransform: Bool = false
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: logicalModel,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: provider.apiFormat,
            upstreamModel: logicalModel,
            baseURL: provider.baseURL,
            requiresTransform: requiresTransform,
            label: nil,
            supportsLongContext: false
        )
    }
}
