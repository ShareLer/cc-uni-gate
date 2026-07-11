@testable import UniGateCore
import Testing

struct CodexConfigParserTests {
    @Test
    func parsesActiveProviderValues() {
        let config = CodexConfigParser.parse(
            """
            model_provider = "custom"
            model = "gpt-5.5"

            [model_providers.custom]
            base_url = "https://api.example.com"
            wire_api = "responses"
            experimental_bearer_token = "client-token"
            """
        )

        #expect(config.model == "gpt-5.5")
        #expect(config.baseURL == "https://api.example.com")
        #expect(config.wireAPI == "responses")
        #expect(config.experimentalBearerToken == "client-token")
    }
}
