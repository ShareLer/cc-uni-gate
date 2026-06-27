@testable import UniGateCore
import Testing

struct CodexChatBridgeTests {
    @Test
    func convertsOpenAIErrorBodyToCodexResponsesErrorBody() throws {
        let body = CodexChatBridge.responsesErrorBody(
            fromOpenAIError: [
                "error": [
                    "type": "rate_limit_error",
                    "message": "slow down",
                    "code": "rate_limit_exceeded",
                    "param": "model"
                ]
            ],
            fallbackMessage: "Too Many Requests"
        )

        #expect(body["type"] as? String == "error")
        let error = try #require(body["error"] as? [String: Any])
        #expect(error["type"] as? String == "rate_limit_error")
        #expect(error["message"] as? String == "slow down")
        #expect(error["code"] as? String == "rate_limit_exceeded")
        #expect(error["param"] as? String == "model")
    }

    @Test
    func rejectsUnsupportedInputPartsInsteadOfDroppingThem() {
        let request: [String: Any] = [
            "model": "gpt-5.5",
            "input": [[
                "role": "user",
                "content": [[
                    "type": "input_image",
                    "image_url": "https://example.com/image.png"
                ]]
            ]]
        ]

        #expect(throws: CodexChatBridgeError.unsupportedInputItem("input_image")) {
            _ = try CodexChatBridge.chatRequest(from: request)
        }
    }
}
