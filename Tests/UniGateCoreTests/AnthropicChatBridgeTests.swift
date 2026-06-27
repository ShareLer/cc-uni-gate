@testable import UniGateCore
import Foundation
import Testing

struct AnthropicChatBridgeTests {
    @Test
    func convertsAnthropicMessagesRequestToOpenAIChatRequest() throws {
        let request: [String: Any] = [
            "model": "luban-glm",
            "system": [["type": "text", "text": "You are concise."]],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "Describe this"],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": "aW1hZ2U="
                            ]
                        ]
                    ]
                ],
                [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "search",
                        "input": ["query": "swift"]
                    ]]
                ],
                [
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": "toolu_1",
                        "content": "result"
                    ]]
                ]
            ],
            "tools": [[
                "name": "search",
                "description": "Search docs",
                "input_schema": [
                    "type": "object",
                    "properties": ["query": ["type": "string"]]
                ]
            ]],
            "tool_choice": ["type": "tool", "name": "search"],
            "max_tokens": 64,
            "stream": true
        ]

        let chat = try AnthropicChatBridge.chatRequest(from: request)

        #expect(chat["model"] as? String == "luban-glm")
        #expect(chat["max_tokens"] as? Int == 64)
        let streamOptions = try #require(chat["stream_options"] as? [String: Any])
        #expect(streamOptions["include_usage"] as? Bool == true)

        let messages = try #require(chat["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are concise.")

        let userContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(userContent[0]["type"] as? String == "text")
        #expect(userContent[1]["type"] as? String == "image_url")
        let imageURL = try #require(userContent[1]["image_url"] as? [String: Any])
        #expect(imageURL["url"] as? String == "data:image/png;base64,aW1hZ2U=")

        let toolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "search")
        #expect(function["arguments"] as? String == #"{"query":"swift"}"#)

        #expect(messages[3]["role"] as? String == "tool")
        #expect(messages[3]["tool_call_id"] as? String == "toolu_1")
        #expect(messages[3]["content"] as? String == "result")

        let tools = try #require(chat["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        let toolChoice = try #require(chat["tool_choice"] as? [String: Any])
        let chosenFunction = try #require(toolChoice["function"] as? [String: Any])
        #expect(chosenFunction["name"] as? String == "search")
    }

    @Test
    func convertsOpenAIChatResponseToAnthropicMessagesResponse() throws {
        let body = try AnthropicChatBridge.anthropicBody(
            from: [
                "id": "chatcmpl-1",
                "model": "luban-glm",
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "content": "I can help.",
                        "tool_calls": [[
                            "id": "call_1",
                            "type": "function",
                            "function": [
                                "name": "search",
                                "arguments": #"{"query":"swift"}"#
                            ]
                        ]]
                    ],
                    "finish_reason": "tool_calls"
                ]],
                "usage": [
                    "prompt_tokens": 12,
                    "completion_tokens": 3,
                    "prompt_tokens_details": ["cached_tokens": 2]
                ]
            ],
            fallbackModel: "fallback"
        )

        #expect(body["id"] as? String == "chatcmpl-1")
        #expect(body["type"] as? String == "message")
        #expect(body["model"] as? String == "luban-glm")
        #expect(body["stop_reason"] as? String == "tool_use")

        let content = try #require(body["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "I can help.")
        #expect(content[1]["type"] as? String == "tool_use")
        #expect(content[1]["id"] as? String == "call_1")
        let input = try #require(content[1]["input"] as? [String: Any])
        #expect(input["query"] as? String == "swift")

        let usage = try #require(body["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 10)
        #expect(usage["cache_read_input_tokens"] as? Int == 2)
        #expect(usage["output_tokens"] as? Int == 3)
    }

    @Test
    func preservesReasoningDetailsAndSynthesizesMissingToolCallID() throws {
        let body = try AnthropicChatBridge.anthropicBody(
            from: [
                "id": "chatcmpl-1",
                "model": "luban-glm",
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "reasoning_details": [[
                            "type": "reasoning.text",
                            "text": "Need current data.",
                            "signature": "sig_1"
                        ]],
                        "tool_calls": [[
                            "type": "function",
                            "function": [
                                "name": "search",
                                "arguments": #"{"query":"swift"}"#
                            ]
                        ]]
                    ],
                    "finish_reason": "tool_calls"
                ]]
            ],
            fallbackModel: "fallback"
        )

        let content = try #require(body["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "thinking")
        #expect(content[0]["thinking"] as? String == "Need current data.")
        #expect(content[0]["signature"] as? String == "sig_1")
        #expect(content[1]["type"] as? String == "tool_use")
        #expect((content[1]["id"] as? String)?.hasPrefix("call_") == true)
        #expect(content[1]["id"] as? String != "")
    }

    @Test
    func synthesizesDistinctMissingToolCallIDs() throws {
        let body = try AnthropicChatBridge.anthropicBody(
            from: [
                "id": "chatcmpl-1",
                "model": "luban-glm",
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "tool_calls": [
                            ["type": "function", "function": ["name": "search", "arguments": "{}"]],
                            ["type": "function", "function": ["name": "search", "arguments": "{}"]]
                        ]
                    ],
                    "finish_reason": "tool_calls"
                ]]
            ],
            fallbackModel: "fallback"
        )

        let content = try #require(body["content"] as? [[String: Any]])
        let ids = content.compactMap { $0["id"] as? String }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    @Test
    func convertsOpenAIErrorBodyToAnthropicErrorBody() throws {
        let body = AnthropicChatBridge.anthropicErrorBody(
            fromOpenAIError: [
                "error": [
                    "type": "rate_limit_exceeded",
                    "message": "slow down"
                ]
            ],
            fallbackMessage: "Too Many Requests"
        )

        #expect(body["type"] as? String == "error")
        let error = try #require(body["error"] as? [String: Any])
        #expect(error["type"] as? String == "rate_limit_error")
        #expect(error["message"] as? String == "slow down")
    }

    @Test
    func convertsPureTextContentBlocksToSingleChatString() throws {
        let request: [String: Any] = [
            "model": "luban-glm",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "line one"],
                    ["type": "text", "text": "line two"]
                ]
            ]]
        ]

        let chat = try AnthropicChatBridge.chatRequest(from: request)
        let messages = try #require(chat["messages"] as? [[String: Any]])

        #expect(messages.first?["content"] as? String == "line one\nline two")
    }

    @Test
    func preservesAssistantThinkingOnlyMessages() throws {
        let request: [String: Any] = [
            "model": "luban-glm",
            "messages": [
                ["role": "user", "content": "start"],
                [
                    "role": "assistant",
                    "content": [[
                        "type": "thinking",
                        "thinking": "I should inspect the prior result."
                    ]]
                ],
                ["role": "user", "content": "continue"]
            ]
        ]

        let chat = try AnthropicChatBridge.chatRequest(from: request)
        let messages = try #require(chat["messages"] as? [[String: Any]])

        #expect(messages.count == 3)
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[1]["content"] as? String == "")
        #expect(messages[1]["reasoning_content"] as? String == "I should inspect the prior result.")
    }

    @Test
    func mapsReasoningEffortAndOSeriesTokenParameter() throws {
        let request: [String: Any] = [
            "model": "o3-mini",
            "messages": [["role": "user", "content": "think"]],
            "max_tokens": 128,
            "thinking": ["type": "enabled", "budget_tokens": 12_000]
        ]

        let chat = try AnthropicChatBridge.chatRequest(from: request)

        #expect(chat["max_tokens"] == nil)
        #expect(chat["max_completion_tokens"] as? Int == 128)
        #expect(chat["reasoning_effort"] as? String == "medium")
    }

    @Test
    func mapsOutputConfigEffortForGPT5Models() throws {
        let request: [String: Any] = [
            "model": "gpt-5.1",
            "messages": [["role": "user", "content": "think"]],
            "output_config": ["effort": "max"]
        ]

        let chat = try AnthropicChatBridge.chatRequest(from: request)

        #expect(chat["reasoning_effort"] as? String == "xhigh")
    }

    @Test
    func estimatesCountTokensFromTranslatedOpenAIChatPayload() throws {
        let request: [String: Any] = [
            "model": "luban-glm",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "Describe this"],
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": "aW1hZ2UtZGF0YS13aXRoLWJ5dGVz"
                        ]
                    ]
                ]
            ]],
            "tools": [[
                "name": "search",
                "description": "Search docs",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer"]
                    ]
                ]
            ]]
        ]

        let fullChat = try AnthropicChatBridge.chatRequest(from: request)
        let fullCount = try #require(
            AnthropicChatBridge.countTokensBody(fromOpenAIChatRequest: fullChat)["input_tokens"] as? Int
        )
        let textOnlyCount = try #require(
            AnthropicChatBridge.countTokensBody(fromOpenAIChatRequest: [
                "model": "luban-glm",
                "messages": [["role": "user", "content": "Describe this"]]
            ])["input_tokens"] as? Int
        )

        #expect(fullCount > textOnlyCount)
    }

    @Test
    func countTokensEstimationDoesNotUnderweightCJKText() throws {
        let latinCount = try #require(
            AnthropicChatBridge.countTokensBody(fromOpenAIChatRequest: [
                "model": "luban-glm",
                "messages": [["role": "user", "content": "hello world"]]
            ])["input_tokens"] as? Int
        )
        let cjkCount = try #require(
            AnthropicChatBridge.countTokensBody(fromOpenAIChatRequest: [
                "model": "luban-glm",
                "messages": [["role": "user", "content": "你好世界你好世界你好世界"]]
            ])["input_tokens"] as? Int
        )

        #expect(cjkCount > latinCount)
    }

    @Test
    func mapsAnthropicImageURLSourceToOpenAIImageURL() throws {
        let request: [String: Any] = [
            "model": "luban-glm",
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "image",
                    "source": [
                        "type": "url",
                        "url": "https://example.com/image.png"
                    ]
                ]]
            ]]
        ]

        let chat = try AnthropicChatBridge.chatRequest(from: request)
        let messages = try #require(chat["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let imageURL = try #require(content.first?["image_url"] as? [String: Any])

        #expect(imageURL["url"] as? String == "https://example.com/image.png")
    }

    @Test
    func rejectsUnsupportedDocumentBlocksInsteadOfDroppingThem() {
        let request: [String: Any] = [
            "model": "luban-glm",
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "document",
                    "source": ["type": "base64", "data": "ZmlsZQ=="]
                ]]
            ]]
        ]

        #expect(throws: AnthropicChatBridgeError.unsupportedContentBlock("document")) {
            _ = try AnthropicChatBridge.chatRequest(from: request)
        }
    }

    @Test
    func convertsOpenAIChatTextStreamToAnthropicMessagesEvents() throws {
        var state = AnthropicChatStreamState()
        var events: [AnthropicChatStreamEvent] = []

        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"role":"assistant","content":"Hel"},"finish_reason":null}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14}}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(forOpenAIChatStreamData: "[DONE]", fallbackModel: "fallback")

        #expect(events.map(\.event) == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop"
        ])

        let start = try eventData(events[0])
        let message = try #require(start["message"] as? [String: Any])
        #expect(message["model"] as? String == "luban-glm")

        let messageDeltaEvent = try #require(events.first { $0.event == "message_delta" })
        let messageDelta = try eventData(messageDeltaEvent)
        let delta = try #require(messageDelta["delta"] as? [String: Any])
        #expect(delta["stop_reason"] as? String == "end_turn")
        let usage = try #require(messageDelta["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 12)
        #expect(usage["output_tokens"] as? Int == 2)
    }

    @Test
    func convertsOpenAIChatToolStreamToAnthropicToolUseEvents() throws {
        var state = AnthropicChatStreamState()
        var events: [AnthropicChatStreamEvent] = []

        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":""}}]},"finish_reason":null}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\""}}]},"finish_reason":null}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"swift\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(forOpenAIChatStreamData: "[DONE]", fallbackModel: "fallback")

        #expect(events.map(\.event) == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop"
        ])

        let startEvent = try #require(events.first { $0.event == "content_block_start" })
        let start = try eventData(startEvent)
        let block = try #require(start["content_block"] as? [String: Any])
        #expect(block["type"] as? String == "tool_use")
        #expect(block["id"] as? String == "call_1")
        #expect(block["name"] as? String == "search")
        #expect((block["input"] as? [String: Any])?.isEmpty == true)

        let deltaEvent = try #require(events.first { $0.event == "message_delta" })
        let deltaObject = try eventData(deltaEvent)
        let delta = try #require(deltaObject["delta"] as? [String: Any])
        #expect(delta["stop_reason"] as? String == "tool_use")
    }

    @Test
    func streamsReasoningDetailsSignatureAndSynthesizesMissingToolCallID() throws {
        var state = AnthropicChatStreamState()
        var events: [AnthropicChatStreamEvent] = []

        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"reasoning_details":[{"text":"Need a lookup.","signature":"sig_1"}]} ,"finish_reason":null}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"search","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(forOpenAIChatStreamData: "[DONE]", fallbackModel: "fallback")

        let deltas = try events.filter { $0.event == "content_block_delta" }.map(eventData)
        let thinkingDelta = try #require(deltas.first { data in
            ((data["delta"] as? [String: Any])?["type"] as? String) == "thinking_delta"
        })
        #expect((thinkingDelta["delta"] as? [String: Any])?["thinking"] as? String == "Need a lookup.")

        let signatureDelta = try #require(deltas.first { data in
            ((data["delta"] as? [String: Any])?["type"] as? String) == "signature_delta"
        })
        #expect((signatureDelta["delta"] as? [String: Any])?["signature"] as? String == "sig_1")

        let toolStart = try #require(events.first { event in
            guard event.event == "content_block_start",
                  let block = try? eventData(event)["content_block"] as? [String: Any] else {
                return false
            }
            return block["type"] as? String == "tool_use"
        })
        let block = try #require(eventData(toolStart)["content_block"] as? [String: Any])
        #expect(block["id"] as? String == "call_0")
    }

    @Test
    func stopsMultipleToolStreamBlocksInContentIndexOrder() throws {
        var state = AnthropicChatStreamState()
        var events: [AnthropicChatStreamEvent] = []

        events += try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"second","arguments":"{}"}},{"index":0,"id":"call_a","type":"function","function":{"name":"first","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            fallbackModel: "fallback"
        )
        events += try state.events(forOpenAIChatStreamData: "[DONE]", fallbackModel: "fallback")

        var startIndices: [Int] = []
        var stopIndices: [Int] = []
        for event in events where event.event == "content_block_start" || event.event == "content_block_stop" {
            let data = try eventData(event)
            let index = try #require(data["index"] as? Int)
            if event.event == "content_block_start" {
                startIndices.append(index)
            } else {
                stopIndices.append(index)
            }
        }

        #expect(startIndices == [0, 1])
        #expect(stopIndices == [0, 1])
    }

    @Test
    func streamTerminalStateRequiresDoneOrFinishReason() throws {
        var state = AnthropicChatStreamState()
        _ = try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#,
            fallbackModel: "fallback"
        )

        #expect(state.hasTerminalChunk == false)

        _ = try state.events(
            forOpenAIChatStreamData: #"{"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            fallbackModel: "fallback"
        )

        #expect(state.hasTerminalChunk == true)
    }

    @Test
    func convertsOpenAIStreamErrorToAnthropicErrorEvent() throws {
        var state = AnthropicChatStreamState()

        let events = try state.events(
            forOpenAIChatStreamData: #"{"error":{"type":"invalid_request_error","message":"bad request"}}"#,
            fallbackModel: "fallback"
        )

        #expect(events.map(\.event) == ["error"])
        let data = try eventData(events[0])
        #expect(data["type"] as? String == "error")
        let error = try #require(data["error"] as? [String: Any])
        #expect(error["type"] as? String == "invalid_request_error")
        #expect(error["message"] as? String == "bad request")
        #expect(state.hasTerminalChunk == true)
        #expect(state.finishEvents().isEmpty)
    }

    @Test
    func malformedOpenAIStreamChunkThrowsBridgeError() throws {
        var state = AnthropicChatStreamState()

        #expect(throws: AnthropicChatBridgeError.invalidChatStreamChunk) {
            try state.events(forOpenAIChatStreamData: "{not json}", fallbackModel: "fallback")
        }
    }

    private func eventData(_ event: AnthropicChatStreamEvent) throws -> [String: Any] {
        let sse = try #require(String(data: try event.sseData(), encoding: .utf8))
        let dataLine = try #require(sse.split(separator: "\n").first { $0.hasPrefix("data: ") })
        let json = String(dataLine.dropFirst("data: ".count))
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }
}
