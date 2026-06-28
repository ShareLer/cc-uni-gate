import UniGateCore
import Testing

struct CustomProviderProtocolHintsTests {
    @Test
    func claudeAnthropicProviderWarnsWhenBaseURLDoesNotLookAnthropic() {
        let hint = CustomProviderProtocolHints.hint(
            appType: UniGateAppRegistry.claudeCode,
            apiFormat: .anthropic,
            baseURL: "https://api.ahooqq.cn",
            isFullUrl: false
        )

        #expect(hint.endpointDescription == "Claude 请求将发送到 /v1/messages")
        #expect(hint.warning == "如果上游是 OpenAI 兼容接口，API 格式应选择 OpenAI Chat；否则 Claude 会请求 /v1/messages。")
    }

    @Test
    func claudeOpenAIChatProviderExplainsTransformEndpoint() {
        let hint = CustomProviderProtocolHints.hint(
            appType: UniGateAppRegistry.claudeCode,
            apiFormat: .openaiChat,
            baseURL: "https://api.ahooqq.cn",
            isFullUrl: false
        )

        #expect(hint.endpointDescription == "Claude 请求将转换并发送到 /v1/chat/completions")
        #expect(hint.warning == nil)
    }

    @Test
    func claudeAnthropicProviderDoesNotWarnForAnthropicBaseURL() {
        let hint = CustomProviderProtocolHints.hint(
            appType: UniGateAppRegistry.claudeCode,
            apiFormat: .anthropic,
            baseURL: "https://api.deepseek.com/anthropic",
            isFullUrl: false
        )

        #expect(hint.endpointDescription == "Claude 请求将发送到 /v1/messages")
        #expect(hint.warning == nil)
    }
}
