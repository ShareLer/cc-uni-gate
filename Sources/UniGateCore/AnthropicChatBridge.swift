import Foundation

public enum AnthropicChatBridgeError: Error, LocalizedError, Equatable {
    case missingModel
    case missingMessages
    case invalidChatResponse
    case invalidChatStreamChunk
    case truncatedChatStream

    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Anthropic Messages request must include a model"
        case .missingMessages:
            return "Anthropic Messages request must include messages"
        case .invalidChatResponse:
            return "Upstream OpenAI Chat response must be a JSON object"
        case .invalidChatStreamChunk:
            return "Upstream OpenAI Chat stream chunk must be a JSON object"
        case .truncatedChatStream:
            return "Upstream OpenAI Chat stream ended before a terminal chunk"
        }
    }
}

public struct AnthropicChatStreamEvent: Sendable, Equatable {
    public let event: String
    public let data: [String: AnySendable]

    public init(event: String, data: [String: AnySendable]) {
        self.event = event
        self.data = data
    }

    public func sseData() throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: data.anyObject, options: [])
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"
        return Data("event: \(event)\ndata: \(json)\n\n".utf8)
    }

    public static func == (lhs: AnthropicChatStreamEvent, rhs: AnthropicChatStreamEvent) -> Bool {
        lhs.event == rhs.event && NSDictionary(dictionary: lhs.data.anyObject).isEqual(to: rhs.data.anyObject)
    }
}

public enum AnthropicChatBridge {
    public static func chatRequest(from anthropicRequest: [String: Any]) throws -> [String: Any] {
        guard let model = trimmedString(anthropicRequest["model"]) else {
            throw AnthropicChatBridgeError.missingModel
        }

        var messages: [[String: Any]] = []
        messages.append(contentsOf: systemMessages(from: anthropicRequest["system"]))

        guard let requestMessages = anthropicRequest["messages"] as? [[String: Any]] else {
            throw AnthropicChatBridgeError.missingMessages
        }
        for message in requestMessages {
            let role = normalizeRole(trimmedString(message["role"]) ?? "user")
            messages.append(contentsOf: try chatMessages(role: role, content: message["content"]))
        }
        guard !messages.isEmpty else {
            throw AnthropicChatBridgeError.missingMessages
        }
        normalizeSystemMessages(&messages)

        var chat: [String: Any] = [
            "model": model,
            "messages": messages
        ]
        if let maxTokens = anthropicRequest["max_tokens"] {
            chat[Self.isOpenAIOSeries(model) ? "max_completion_tokens" : "max_tokens"] = maxTokens
        }
        for key in ["temperature", "top_p", "stream"] {
            if let value = anthropicRequest[key] {
                chat[key] = value
            }
        }
        if let stop = anthropicRequest["stop_sequences"] {
            chat["stop"] = stop
        }
        if let tools = openAIChatTools(from: anthropicRequest["tools"]) {
            chat["tools"] = tools
        }
        if let toolChoice = anthropicRequest["tool_choice"] {
            chat["tool_choice"] = openAIChatToolChoice(from: toolChoice)
        }
        if Self.supportsReasoningEffort(model), let effort = reasoningEffort(from: anthropicRequest) {
            chat["reasoning_effort"] = effort
        }
        if (chat["stream"] as? Bool) == true {
            chat["stream_options"] = mergedStreamOptions(anthropicRequest["stream_options"])
        }
        return chat
    }

    public static func anthropicBody(from chatResponse: [String: Any], fallbackModel: String) throws -> [String: Any] {
        guard let choice = firstChoice(chatResponse) else {
            throw AnthropicChatBridgeError.invalidChatResponse
        }
        let message = choice["message"] as? [String: Any] ?? [:]
        let content = contentBlocks(from: message)
        let hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
        let stopReason = anthropicStopReason(from: trimmedString(choice["finish_reason"]), hasToolUse: hasToolUse)

        return [
            "id": trimmedString(chatResponse["id"]) ?? "msg_\(UUID().uuidString)",
            "type": "message",
            "role": "assistant",
            "content": content,
            "model": trimmedString(chatResponse["model"]) ?? fallbackModel,
            "stop_reason": stopReason ?? NSNull(),
            "stop_sequence": NSNull(),
            "usage": anthropicUsage(from: chatResponse["usage"])
        ]
    }

    public static func countTokensBody(fromOpenAIChatRequest chatRequest: [String: Any]) -> [String: Any] {
        let estimated = max(Int(ceil(Double(serializedText(chatRequest).count) / 4.0)), 1)
        return ["input_tokens": estimated]
    }

    public static func anthropicErrorBody(fromOpenAIError object: [String: Any], fallbackMessage: String) -> [String: Any] {
        let errorObject = object["error"] as? [String: Any]
        let message = trimmedString(errorObject?["message"])
            ?? trimmedString(object["message"])
            ?? fallbackMessage
        let type = trimmedString(errorObject?["type"])
            ?? trimmedString(errorObject?["code"])
            ?? "api_error"
        return [
            "type": "error",
            "error": [
                "type": anthropicErrorType(type),
                "message": message
            ]
        ]
    }

    private static func systemMessages(from value: Any?) -> [[String: Any]] {
        if let text = strippedSystemText(trimmedString(value)) {
            return [["role": "system", "content": text]]
        }
        guard let parts = value as? [[String: Any]] else {
            return []
        }
        return parts.compactMap { part in
            guard let text = strippedSystemText(trimmedString(part["text"])) else {
                return nil
            }
            return ["role": "system", "content": text]
        }
    }

    private static func chatMessages(role: String, content: Any?) throws -> [[String: Any]] {
        if let text = trimmedString(content) {
            return [["role": role, "content": text]]
        }
        guard let blocks = content as? [[String: Any]] else {
            return [["role": role, "content": content ?? NSNull()]]
        }

        var contentParts: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []
        var resultMessages: [[String: Any]] = []
        var reasoningParts: [String] = []

        for block in blocks {
            switch trimmedString(block["type"]) {
            case "text":
                if let text = trimmedString(block["text"]) {
                    contentParts.append(["type": "text", "text": text])
                }
            case "image":
                if let source = block["source"] as? [String: Any],
                   let data = trimmedString(source["data"]) {
                    let mediaType = trimmedString(source["media_type"]) ?? "image/png"
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mediaType);base64,\(data)"]
                    ])
                }
            case "tool_use":
                let input = block["input"] ?? [:]
                toolCalls.append([
                    "id": trimmedString(block["id"]) ?? "",
                    "type": "function",
                    "function": [
                        "name": trimmedString(block["name"]) ?? "",
                        "arguments": jsonString(input)
                    ]
                ])
            case "tool_result":
                let toolUseID = trimmedString(block["tool_use_id"]) ?? ""
                resultMessages.append([
                    "role": "tool",
                    "tool_call_id": toolUseID,
                    "content": toolResultText(block["content"])
                ])
            case "thinking":
                if let thinking = trimmedString(block["thinking"]) {
                    reasoningParts.append(thinking)
                }
            case "redacted_thinking":
                reasoningParts.append("[redacted thinking]")
            default:
                continue
            }
        }

        var messages: [[String: Any]] = []
        if !contentParts.isEmpty || !toolCalls.isEmpty || (role == "assistant" && !reasoningParts.isEmpty) {
            var message: [String: Any] = ["role": role]
            if contentParts.isEmpty {
                message["content"] = toolCalls.isEmpty ? "" : NSNull()
            } else if contentParts.allSatisfy({ ($0["type"] as? String) == "text" }) {
                message["content"] = contentParts
                    .compactMap { trimmedString($0["text"]) }
                    .joined(separator: "\n")
            } else if contentParts.count == 1, let text = contentParts[0]["text"] as? String {
                message["content"] = text
            } else {
                message["content"] = contentParts
            }
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls
            }
            if role == "assistant", !reasoningParts.isEmpty {
                message["reasoning_content"] = reasoningParts.joined(separator: "\n")
            }
            messages.append(message)
        }
        messages.append(contentsOf: resultMessages)
        return messages
    }

    private static func normalizeSystemMessages(_ messages: inout [[String: Any]]) {
        var systemParts: [String] = []
        var nonSystem: [[String: Any]] = []
        for message in messages {
            if message["role"] as? String == "system" {
                if let text = trimmedString(message["content"]) {
                    systemParts.append(text)
                }
            } else {
                nonSystem.append(message)
            }
        }
        if !systemParts.isEmpty {
            messages = [["role": "system", "content": systemParts.joined(separator: "\n")]] + nonSystem
        }
    }

    private static func openAIChatTools(from value: Any?) -> [[String: Any]]? {
        guard let tools = value as? [[String: Any]] else {
            return nil
        }
        let converted = tools.compactMap { tool -> [String: Any]? in
            guard trimmedString(tool["type"]) != "BatchTool" else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": trimmedString(tool["name"]) ?? "",
                    "description": tool["description"] ?? NSNull(),
                    "parameters": cleanSchema(tool["input_schema"] ?? [:])
                ]
            ]
        }
        return converted.isEmpty ? nil : converted
    }

    private static func openAIChatToolChoice(from value: Any) -> Any {
        if let text = trimmedString(value) {
            return text == "any" ? "required" : text
        }
        guard let object = value as? [String: Any] else {
            return value
        }
        switch trimmedString(object["type"]) {
        case "any":
            return "required"
        case "auto":
            return "auto"
        case "none":
            return "none"
        case "tool":
            return [
                "type": "function",
                "function": ["name": trimmedString(object["name"]) ?? ""]
            ]
        default:
            return value
        }
    }

    private static func mergedStreamOptions(_ value: Any?) -> [String: Any] {
        var options = value as? [String: Any] ?? [:]
        options["include_usage"] = true
        return options
    }

    private static func contentBlocks(from message: [String: Any]) -> [[String: Any]] {
        var content: [[String: Any]] = []
        if let reasoning = trimmedString(message["reasoning_content"] ?? message["reasoning"]) {
            content.append(["type": "thinking", "thinking": reasoning])
        }
        appendReasoningDetails(message["reasoning_details"], to: &content)
        appendTextBlocks(message["content"], to: &content)
        if let refusal = trimmedString(message["refusal"]) {
            content.append(["type": "text", "text": refusal])
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for (index, call) in toolCalls.enumerated() {
                content.append(toolUseBlock(from: call, index: index))
            }
        } else if let functionCall = message["function_call"] as? [String: Any] {
            content.append(toolUseBlock(fromFunctionCall: functionCall))
        }
        return content
    }

    private static func appendTextBlocks(_ value: Any?, to content: inout [[String: Any]]) {
        if let text = trimmedString(value) {
            content.append(["type": "text", "text": text])
            return
        }
        guard let parts = value as? [[String: Any]] else {
            return
        }
        for part in parts {
            if let type = trimmedString(part["type"]),
               ["text", "output_text", "refusal"].contains(type),
               let text = trimmedString(part["text"] ?? part["refusal"]) {
                content.append(["type": "text", "text": text])
            }
        }
    }

    private static func appendReasoningDetails(_ value: Any?, to content: inout [[String: Any]]) {
        guard let details = value as? [[String: Any]] else {
            return
        }
        for detail in details {
            if let text = trimmedString(detail["text"] ?? detail["reasoning"] ?? detail["content"]) {
                var block: [String: Any] = ["type": "thinking", "thinking": text]
                if let signature = trimmedString(detail["signature"]) {
                    block["signature"] = signature
                }
                content.append(block)
            }
        }
    }

    private static func toolUseBlock(from call: [String: Any], index: Int) -> [String: Any] {
        let function = call["function"] as? [String: Any] ?? [:]
        let arguments = trimmedString(function["arguments"]) ?? "{}"
        return [
            "type": "tool_use",
            "id": toolCallID(call["id"], name: trimmedString(function["name"]), arguments: arguments, index: index),
            "name": trimmedString(function["name"]) ?? "",
            "input": jsonObject(arguments)
        ]
    }

    private static func toolUseBlock(fromFunctionCall functionCall: [String: Any]) -> [String: Any] {
        let arguments = trimmedString(functionCall["arguments"]) ?? "{}"
        return [
            "type": "tool_use",
            "id": toolCallID(functionCall["id"], name: trimmedString(functionCall["name"]), arguments: arguments),
            "name": trimmedString(functionCall["name"]) ?? "",
            "input": jsonObject(arguments)
        ]
    }

    private static func toolCallID(_ value: Any?, name: String?, arguments: String, index: Int? = nil) -> String {
        if let id = trimmedString(value) {
            return id
        }
        let seed = "\(index.map(String.init) ?? "function"):\(name ?? "function"):\(arguments)"
        return "call_\(stableHash(seed))"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private static func anthropicErrorType(_ value: String) -> String {
        switch value.lowercased() {
        case "invalid_request_error", "bad_request", "invalid_request":
            return "invalid_request_error"
        case "authentication_error", "unauthorized":
            return "authentication_error"
        case "permission_error", "forbidden":
            return "permission_error"
        case "not_found_error", "not_found":
            return "not_found_error"
        case "rate_limit_error", "rate_limit_exceeded":
            return "rate_limit_error"
        case "overloaded_error", "service_unavailable":
            return "overloaded_error"
        default:
            return "api_error"
        }
    }

    private static func reasoningEffort(from request: [String: Any]) -> String? {
        if let outputConfig = request["output_config"] as? [String: Any],
           let effort = trimmedString(outputConfig["effort"]) {
            switch effort {
            case "low", "medium", "high":
                return effort
            case "max":
                return "xhigh"
            default:
                return nil
            }
        }
        guard let thinking = request["thinking"] as? [String: Any] else {
            return nil
        }
        switch trimmedString(thinking["type"]) {
        case "adaptive":
            return "xhigh"
        case "enabled":
            guard let budget = intValue(thinking["budget_tokens"]) else {
                return "high"
            }
            if budget < 4_000 { return "low" }
            if budget < 16_000 { return "medium" }
            return "high"
        default:
            return nil
        }
    }

    private static func isOpenAIOSeries(_ model: String) -> Bool {
        guard model.count > 1, model.first == "o" else {
            return false
        }
        return model.dropFirst().first?.isNumber == true
    }

    private static func supportsReasoningEffort(_ model: String) -> Bool {
        if isOpenAIOSeries(model) {
            return true
        }
        let lower = model.lowercased()
        guard lower.hasPrefix("gpt-") else {
            return false
        }
        guard let version = lower.dropFirst(4).first else {
            return false
        }
        return version.isNumber && version >= "5"
    }

    fileprivate static func anthropicUsage(from value: Any?) -> [String: Any] {
        guard let usage = value as? [String: Any] else {
            return ["input_tokens": 0, "output_tokens": 0]
        }
        let cached = intValue(usage["cache_read_input_tokens"])
            ?? intValue((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? 0
        let cacheCreation = intValue(usage["cache_creation_input_tokens"]) ?? 0
        let prompt = intValue(usage["prompt_tokens"] ?? usage["input_tokens"]) ?? 0
        let completion = intValue(usage["completion_tokens"] ?? usage["output_tokens"]) ?? 0
        var result: [String: Any] = [
            "input_tokens": max(prompt - cached - cacheCreation, 0),
            "output_tokens": completion
        ]
        if cached > 0 {
            result["cache_read_input_tokens"] = cached
        }
        if cacheCreation > 0 {
            result["cache_creation_input_tokens"] = cacheCreation
        }
        return result
    }

    private static func anthropicStopReason(from finishReason: String?, hasToolUse: Bool) -> String? {
        switch finishReason {
        case "stop":
            return "end_turn"
        case "length":
            return "max_tokens"
        case "tool_calls", "function_call":
            return "tool_use"
        case "content_filter":
            return "end_turn"
        case .some:
            return "end_turn"
        case .none:
            return hasToolUse ? "tool_use" : nil
        }
    }

    private static func toolResultText(_ value: Any?) -> String {
        if let text = trimmedString(value) {
            return text
        }
        return jsonString(value ?? "")
    }

    private static func cleanSchema(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            if object["format"] as? String == "uri" {
                object.removeValue(forKey: "format")
            }
            if var properties = object["properties"] as? [String: Any] {
                for (key, value) in properties {
                    properties[key] = cleanSchema(value)
                }
                object["properties"] = properties
            }
            if let items = object["items"] {
                object["items"] = cleanSchema(items)
            }
            return object
        }
        if let array = value as? [Any] {
            return array.map(cleanSchema)
        }
        return value
    }

    private static func strippedSystemText(_ value: String?) -> String? {
        guard var text = value else {
            return nil
        }
        let prefix = "x-anthropic-billing-header:"
        if text.hasPrefix(prefix), let range = text.rangeOfCharacter(from: .newlines) {
            text = String(text[range.upperBound...])
                .trimmingCharacters(in: .newlines)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeRole(_ role: String) -> String {
        switch role {
        case "assistant", "system", "tool":
            return role
        default:
            return "user"
        }
    }

    private static func firstChoice(_ object: [String: Any]) -> [String: Any]? {
        (object["choices"] as? [[String: Any]])?.first
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func serializedText(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private static func jsonObject(_ value: String) -> Any {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }
        return object
    }
}

public struct AnthropicChatStreamState {
    private struct ToolState {
        var anthropicIndex: Int
        var id = ""
        var name = ""
        var started = false
        var pendingArguments = ""
    }

    private var messageID: String?
    private var model: String?
    private var nextContentIndex = 0
    private var sentMessageStart = false
    private var currentBlockIndex: Int?
    private var currentBlockType: String?
    private var toolStates: [Int: ToolState] = [:]
    private var latestUsage: [String: Any]?
    private var pendingStopReason: String?
    private var sentMessageStop = false
    private var sawDone = false
    private var sawStreamError = false

    public var hasTerminalChunk: Bool {
        sawDone || sawStreamError || pendingStopReason != nil || sentMessageStop
    }

    public init() {}

    public mutating func events(forOpenAIChatStreamData data: String, fallbackModel: String) throws -> [AnthropicChatStreamEvent] {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        if trimmed == "[DONE]" {
            sawDone = true
            return finishEvents()
        }
        guard
            let jsonData = trimmed.data(using: .utf8),
            let value = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw AnthropicChatBridgeError.invalidChatStreamChunk
        }
        return try events(forChunk: value, fallbackModel: fallbackModel)
    }

    public mutating func finishEvents() -> [AnthropicChatStreamEvent] {
        guard !sawStreamError else {
            return []
        }
        guard !sentMessageStop else {
            return []
        }
        var events: [AnthropicChatStreamEvent] = []
        if let blockIndex = currentBlockIndex {
            events.append(event("content_block_stop", [
                "type": "content_block_stop",
                "index": blockIndex
            ]))
            currentBlockIndex = nil
            currentBlockType = nil
        }
        for state in toolStates.values.sorted(by: { $0.anthropicIndex < $1.anthropicIndex }) where state.started {
            events.append(event("content_block_stop", [
                "type": "content_block_stop",
                "index": state.anthropicIndex
            ]))
        }
        toolStates.removeAll()
        if sentMessageStart {
            events.append(messageDelta(stopReason: pendingStopReason, usage: latestUsage))
            pendingStopReason = nil
        }
        events.append(event("message_stop", ["type": "message_stop"]))
        sentMessageStop = true
        return events
    }

    private mutating func events(forChunk chunk: [String: Any], fallbackModel: String) throws -> [AnthropicChatStreamEvent] {
        if let errorObject = chunk["error"] as? [String: Any] {
            sawStreamError = true
            return [event("error", AnthropicChatBridge.anthropicErrorBody(
                fromOpenAIError: ["error": errorObject],
                fallbackMessage: "OpenAI Chat stream error"
            ))]
        }
        if let id = chunk["id"] as? String, !id.isEmpty, messageID == nil {
            messageID = id
        }
        if let model = chunk["model"] as? String, !model.isEmpty, self.model == nil {
            self.model = model
        }
        if let usage = chunk["usage"] as? [String: Any] {
            latestUsage = AnthropicChatBridge.anthropicUsage(from: usage)
        }

        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else {
            return []
        }

        var events: [AnthropicChatStreamEvent] = []
        if !sentMessageStart {
            events.append(messageStart(fallbackModel: fallbackModel))
            sentMessageStart = true
        }

        let delta = choice["delta"] as? [String: Any] ?? [:]
        if let reasoning = string(delta["reasoning_content"] ?? delta["reasoning"]), !reasoning.isEmpty {
            events.append(contentsOf: ensureContentBlock(type: "thinking"))
            if let index = currentBlockIndex {
                events.append(event("content_block_delta", [
                    "type": "content_block_delta",
                    "index": index,
                    "delta": [
                        "type": "thinking_delta",
                        "thinking": reasoning
                    ]
                ]))
            }
        }
        if let details = delta["reasoning_details"] as? [[String: Any]] {
            for detail in details {
                if let reasoning = string(detail["text"] ?? detail["reasoning"] ?? detail["content"]), !reasoning.isEmpty {
                    events.append(contentsOf: ensureContentBlock(type: "thinking"))
                    if let index = currentBlockIndex {
                        events.append(event("content_block_delta", [
                            "type": "content_block_delta",
                            "index": index,
                            "delta": [
                                "type": "thinking_delta",
                                "thinking": reasoning
                            ]
                        ]))
                    }
                }
                if let signature = string(detail["signature"]), !signature.isEmpty {
                    events.append(contentsOf: ensureContentBlock(type: "thinking"))
                    if let index = currentBlockIndex {
                        events.append(event("content_block_delta", [
                            "type": "content_block_delta",
                            "index": index,
                            "delta": [
                                "type": "signature_delta",
                                "signature": signature
                            ]
                        ]))
                    }
                }
            }
        }
        if let content = string(delta["content"]), !content.isEmpty {
            events.append(contentsOf: ensureContentBlock(type: "text"))
            if let index = currentBlockIndex {
                events.append(event("content_block_delta", [
                    "type": "content_block_delta",
                    "index": index,
                    "delta": [
                        "type": "text_delta",
                        "text": content
                    ]
                ]))
            }
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            if currentBlockIndex != nil {
                events.append(contentsOf: stopCurrentBlock())
            }
            for toolCall in toolCalls {
                events.append(contentsOf: toolEvents(for: toolCall))
            }
        }

        if let finishReason = string(choice["finish_reason"]) {
            let stopReason = Self.mapStopReason(finishReason)
            pendingStopReason = stopReason
        }
        return events
    }

    private mutating func ensureContentBlock(type: String) -> [AnthropicChatStreamEvent] {
        if currentBlockType == type {
            return []
        }
        var events = stopCurrentBlock()
        let index = nextContentIndex
        nextContentIndex += 1
        currentBlockIndex = index
        currentBlockType = type
        let block: [String: Any]
        if type == "thinking" {
            block = ["type": "thinking", "thinking": ""]
        } else {
            block = ["type": "text", "text": ""]
        }
        events.append(event("content_block_start", [
            "type": "content_block_start",
            "index": index,
            "content_block": block
        ]))
        return events
    }

    private mutating func stopCurrentBlock() -> [AnthropicChatStreamEvent] {
        guard let index = currentBlockIndex else {
            return []
        }
        currentBlockIndex = nil
        currentBlockType = nil
        return [event("content_block_stop", [
            "type": "content_block_stop",
            "index": index
        ])]
    }

    private mutating func toolEvents(for toolCall: [String: Any]) -> [AnthropicChatStreamEvent] {
        let openAIIndex = int(toolCall["index"]) ?? 0
        if toolStates[openAIIndex] == nil {
            toolStates[openAIIndex] = ToolState(anthropicIndex: nextContentIndex)
            nextContentIndex += 1
        }

        var state = toolStates[openAIIndex]!
        if let id = string(toolCall["id"]), !id.isEmpty {
            state.id = id
        }
        if let function = toolCall["function"] as? [String: Any],
           let name = string(function["name"]) {
            state.name = name
        }
        if state.id.isEmpty, !state.name.isEmpty {
            state.id = "call_\(openAIIndex)"
        }

        var events: [AnthropicChatStreamEvent] = []
        if !state.started, !state.id.isEmpty, !state.name.isEmpty {
            state.started = true
            events.append(event("content_block_start", [
                "type": "content_block_start",
                "index": state.anthropicIndex,
                "content_block": [
                    "type": "tool_use",
                    "id": state.id,
                    "name": state.name,
                    "input": [:]
                ]
            ]))
            if !state.pendingArguments.isEmpty {
                events.append(toolDelta(index: state.anthropicIndex, arguments: state.pendingArguments))
                state.pendingArguments = ""
            }
        }

        if let function = toolCall["function"] as? [String: Any],
           let arguments = string(function["arguments"]),
           !arguments.isEmpty {
            if state.started {
                events.append(toolDelta(index: state.anthropicIndex, arguments: arguments))
            } else {
                state.pendingArguments += arguments
            }
        }

        toolStates[openAIIndex] = state
        return events
    }

    private func toolDelta(index: Int, arguments: String) -> AnthropicChatStreamEvent {
        event("content_block_delta", [
            "type": "content_block_delta",
            "index": index,
            "delta": [
                "type": "input_json_delta",
                "partial_json": arguments
            ]
        ])
    }

    private func messageStart(fallbackModel: String) -> AnthropicChatStreamEvent {
        event("message_start", [
            "type": "message_start",
            "message": [
                "id": messageID ?? "msg_\(UUID().uuidString)",
                "type": "message",
                "role": "assistant",
                "model": model ?? fallbackModel,
                "usage": ["input_tokens": 0, "output_tokens": 0]
            ]
        ])
    }

    private func messageDelta(stopReason: String?, usage: [String: Any]?) -> AnthropicChatStreamEvent {
        let stopReasonValue: Any = stopReason ?? NSNull()
        let data: [String: Any] = [
            "type": "message_delta",
            "delta": [
                "stop_reason": stopReasonValue,
                "stop_sequence": NSNull()
            ],
            "usage": usage ?? ["input_tokens": 0, "output_tokens": 0]
        ]
        return event("message_delta", data)
    }

    private func event(_ name: String, _ data: [String: Any]) -> AnthropicChatStreamEvent {
        AnthropicChatStreamEvent(event: name, data: data.anySendableObject)
    }

    private static func mapStopReason(_ finishReason: String) -> String {
        switch finishReason {
        case "length":
            return "max_tokens"
        case "tool_calls", "function_call":
            return "tool_use"
        default:
            return "end_turn"
        }
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        return value
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

public enum AnySendable: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnySendable])
    case object([String: AnySendable])

    var anyObject: Any {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        case let .array(values):
            return values.map(\.anyObject)
        case let .object(values):
            return values.mapValues(\.anyObject)
        }
    }
}

private extension Dictionary where Key == String, Value == AnySendable {
    var anyObject: [String: Any] {
        mapValues(\.anyObject)
    }
}

private extension Dictionary where Key == String, Value == Any {
    var anySendableObject: [String: AnySendable] {
        var result: [String: AnySendable] = [:]
        for (key, value) in self {
            result[key] = AnySendable(value)
        }
        return result
    }
}

private extension Array where Element == Any {
    var anySendableArray: [AnySendable] {
        map(AnySendable.init)
    }
}

private extension AnySendable {
    init(_ value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .double(value.doubleValue)
        case _ as NSNull:
            self = .null
        case let value as [String: Any]:
            self = .object(value.anySendableObject)
        case let value as [Any]:
            self = .array(value.anySendableArray)
        default:
            self = .string(String(describing: value))
        }
    }
}
