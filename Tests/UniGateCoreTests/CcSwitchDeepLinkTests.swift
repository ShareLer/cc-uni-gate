import Foundation
import Testing
import UniGateCore

struct CcSwitchDeepLinkTests {
    @Test
    func buildsCodexProviderImportURL() throws {
        let url = try #require(CcSwitchDeepLink.providerImportURL(
            app: "codex",
            endpoint: "http://127.0.0.1:17888/codex",
            model: "gpt-5.5"
        ))

        let params = try queryParams(url)

        #expect(url.scheme == "ccswitch")
        #expect(url.host == "v1")
        #expect(url.path == "/import")
        #expect(params["resource"] == "provider")
        #expect(params["app"] == "codex")
        #expect(params["name"] == "UniGate")
        #expect(params["endpoint"] == "http://127.0.0.1:17888/codex")
        #expect(params["apiKey"] == CcSwitchDeepLink.localAPIKey)
        #expect(params["model"] == "gpt-5.5")
        #expect(params["enabled"] == "true")
        #expect(params["notes"]?.contains("UniGate") == true)
        #expect(params["homepage"] == nil)
    }

    @Test
    func buildsClaudeProviderImportURL() throws {
        let url = try #require(CcSwitchDeepLink.providerImportURL(
            app: "claude",
            endpoint: "http://127.0.0.1:17888/claude-code",
            model: "auto",
            homepage: "http://127.0.0.1:17888"
        ))

        let params = try queryParams(url)

        #expect(params["resource"] == "provider")
        #expect(params["app"] == "claude")
        #expect(params["endpoint"] == "http://127.0.0.1:17888/claude-code")
        #expect(params["homepage"] == "http://127.0.0.1:17888")
        #expect(params["apiKey"] == CcSwitchDeepLink.localAPIKey)
        #expect(params["model"] == "auto")
        #expect(params["enabled"] == "true")
    }

    private func queryParams(_ url: URL) throws -> [String: String] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}
