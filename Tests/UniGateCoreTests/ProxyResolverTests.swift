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
        #expect(resolved.headers["authorization"] == "Bearer key-1")
        #expect(resolved.outboundModel == "gpt-5.5")
        let outbound = try JSONSerialization.jsonObject(with: resolved.body) as? [String: Any]
        #expect(outbound?["model"] as? String == "gpt-5.5")
        #expect(outbound?["input"] as? String == "hello")
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
    func failsClosedWhenTransformIsRequired() throws {
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
        let candidate = candidate(provider: provider, requiresTransform: true)
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let routes = RouteStore.defaultState(candidates: catalog.candidates)

        #expect(throws: ProxyResolverError.transformRequired(
            model: "gpt-5.5",
            provider: "Provider 1",
            apiFormat: .openaiChat
        )) {
            try ProxyResolver.resolveRoute(
                catalog: catalog,
                routes: routes,
                protocolKind: .codexResponses,
                path: "/openai/v1/responses",
                body: Data(#"{"model":"gpt-5.5"}"#.utf8)
            )
        }
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
            logicalModel: "claude-sonnet-4-6",
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
            body: Data(#"{"model":"claude-sonnet-4-6","messages":[]}"#.utf8)
        )

        #expect(resolved.upstreamURL.absoluteString == "https://desktop.example.com/v1/messages")
    }

    @Test
    func parsesCcSwitchStyleProxyPaths() {
        #expect(ProxyRequestPath("/v1/responses") == .proxy(protocolKind: .codexResponses, appType: "codex"))
        #expect(ProxyRequestPath("/v1/v1/responses") == .proxy(protocolKind: .codexResponses, appType: "codex"))
        #expect(ProxyRequestPath("/v1/chat/completions") == .proxy(protocolKind: .openaiChat, appType: "codex"))
        #expect(ProxyRequestPath("/v1/messages") == .proxy(protocolKind: .anthropicMessages, appType: "claude"))
        #expect(ProxyRequestPath("/claude-desktop/v1/messages") == .proxy(protocolKind: .anthropicMessages, appType: "claude-desktop"))
        #expect(ProxyRequestPath("/v1/models") == .models)
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

    private func candidate(provider: ImportedProvider, requiresTransform: Bool) -> ModelCandidate {
        ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: provider.apiFormat,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: requiresTransform,
            label: nil,
            supportsLongContext: false
        )
    }
}
