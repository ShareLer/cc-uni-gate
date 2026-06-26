@testable import UniGateCore
import Testing

struct ProviderCredentialsTests {
    @Test
    func resolvesClaudeSecretPriority() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: [
                "env": .object([
                    "ANTHROPIC_AUTH_TOKEN": .string("auth-token"),
                    "ANTHROPIC_API_KEY": .string("api-key")
                ])
            ],
            meta: [:]
        )

        let secret = try #require(ProviderCredentials.secret(for: provider))

        #expect(secret.field == "env.ANTHROPIC_AUTH_TOKEN")
        #expect(secret.value == "auth-token")
    }

    @Test
    func usesAnthropicApiKeyHeaderForProxyRequests() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "Claude Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_API_KEY": .string("api-key")])],
            meta: [:]
        )

        #expect(ProviderCredentials.proxyAuthHeaders(for: provider) == [
            "x-api-key": "api-key"
        ])
    }

    @Test
    func usesBearerProxyHeaderForClaudeOpenAIChatProviders() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude",
            name: "OpenAI Chat Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiChat,
            baseURL: "https://api.example.com/v1/chat/completions",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_API_KEY": .string("api-key")])],
            meta: [:]
        )

        #expect(ProviderCredentials.proxyAuthHeaders(for: provider) == [
            "authorization": "Bearer api-key"
        ])
    }

    @Test
    func usesBearerHeaderForModelFetchEvenWithAnthropicApiKey() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "claude-desktop",
            name: "Desktop Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .anthropic,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["env": .object(["ANTHROPIC_API_KEY": .string("api-key")])],
            meta: [:]
        )

        #expect(ProviderCredentials.modelFetchHeaders(for: provider) == [
            "authorization": "Bearer api-key"
        ])
    }

    @Test
    func detectsCodexEnvSecret() {
        #expect(ProviderCredentials.hasSecret(
            appType: "codex",
            settings: ["env": .object(["OPENAI_API_KEY": .string("codex-key")])]
        ))
    }
}
