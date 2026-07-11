import Foundation
import Testing
import UniGateCore

struct CustomProviderDefinitionTests {
    @Test
    func decodesLegacyProviderAsStandardBackend() throws {
        let data = Data("""
        {
          "id": "legacy-provider",
          "appType": "codex",
          "name": "Legacy",
          "baseURL": "https://api.example.com/v1",
          "apiFormat": "openai_responses"
        }
        """.utf8)

        let definition = try JSONDecoder().decode(CustomProviderDefinition.self, from: data)

        #expect(definition.backendKind == .standard)
        #expect(definition.baseURL == "https://api.example.com/v1")
        #expect(definition.enableDiscovery)
    }

    @Test
    func codexOfficialFactoryUsesCanonicalConfigurationAndPersistsBackendKind() throws {
        let definition = CustomProviderDefinition.codexOfficial(
            id: "official-provider",
            name: "  My Codex Subscription  "
        )
        let decoded = try JSONDecoder().decode(
            CustomProviderDefinition.self,
            from: JSONEncoder().encode(definition)
        )

        #expect(decoded.id == "official-provider")
        #expect(decoded.name == "My Codex Subscription")
        #expect(decoded.backendKind == .codexOfficial)
        #expect(decoded.appType == UniGateAppRegistry.codex)
        #expect(decoded.baseURL == CodexOfficial.backendBaseURLString)
        #expect(decoded.apiFormat == .openaiResponses)
        #expect(decoded.category == "official")
        #expect(decoded.enableDiscovery)
        #expect(!decoded.hasSecret)
    }

    @Test
    func normalizingOfficialProviderDiscardsEditableUpstreamAndStaticSecretConfiguration() {
        let definition = CustomProviderDefinition(
            id: "official-provider",
            appType: "claude",
            name: "Official",
            baseURL: "https://evil.example.com",
            apiFormat: .anthropic,
            category: "custom",
            enableDiscovery: false,
            apiKeyIdentifier: "legacy-secret",
            isFullUrl: true,
            modelsUrl: "https://evil.example.com/models",
            customUserAgent: "custom-agent",
            backendKind: .codexOfficial
        )

        let normalized = definition.normalized()
        let imported = definition.toImportedProvider(apiKey: "must-not-be-used")

        #expect(normalized.appType == UniGateAppRegistry.codex)
        #expect(normalized.baseURL == CodexOfficial.backendBaseURLString)
        #expect(normalized.apiFormat == .openaiResponses)
        #expect(normalized.category == "official")
        #expect(normalized.enableDiscovery)
        #expect(normalized.apiKeyIdentifier == nil)
        #expect(!normalized.isFullUrl)
        #expect(normalized.modelsUrl == nil)
        #expect(normalized.customUserAgent == nil)
        #expect(imported.backendKind == .codexOfficial)
        #expect(imported.baseURL == CodexOfficial.backendBaseURLString)
        #expect(!imported.hasSecret)
        #expect(imported.settings.isEmpty)
    }
}
