import Foundation

public enum CodexChatBridgeError: Error, LocalizedError, Equatable {
    case missingModel
    case missingInput
    case unsupportedInputItem(String)
    case invalidChatResponse

    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Codex Responses request must include a model"
        case .missingInput:
            return "Codex Responses request must include input"
        case let .unsupportedInputItem(type):
            return "Codex Responses input item is not supported by the OpenAI Chat bridge: \(type)"
        case .invalidChatResponse:
            return "Upstream OpenAI Chat response must be a JSON object"
        }
    }
}

public enum CodexChatBridge {
    public static func chatRequest(from responsesRequest: [String: Any]) throws -> [String: Any] {
        guard let model = trimmedString(responsesRequest["model"]) else {
            throw CodexChatBridgeError.missingModel
        }
        for key in ["tools", "tool_choice", "parallel_tool_calls"] where responsesRequest[key] != nil {
            throw CodexChatBridgeError.unsupportedInputItem(key)
        }

        var messages: [[String: Any]] = []
        if let instructions = trimmedString(responsesRequest["instructions"]) {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(contentsOf: try inputMessages(from: responsesRequest["input"]))
        guard !messages.isEmpty else {
            throw CodexChatBridgeError.missingInput
        }

        var chat: [String: Any] = [
            "model": model,
            "messages": messages
        ]
        if let maxTokens = responsesRequest["max_output_tokens"] ?? responsesRequest["max_tokens"] {
            chat["max_tokens"] = maxTokens
        }
        for key in ["temperature", "top_p", "presence_penalty", "frequency_penalty", "seed", "stream"] {
            if let value = responsesRequest[key] {
                chat[key] = value
            }
        }
        if let stop = responsesRequest["stop"] ?? responsesRequest["stop_sequences"] {
            chat["stop"] = stop
        }
        return chat
    }

    public static func responsesBody(from chatResponse: [String: Any], fallbackModel: String) throws -> [String: Any] {
        let id = trimmedString(chatResponse["id"]) ?? "resp_\(UUID().uuidString)"
        let model = trimmedString(chatResponse["model"]) ?? fallbackModel
        let choice = firstChoice(chatResponse)
        let message = choice?["message"] as? [String: Any] ?? [:]
        let text = try textContent(message["content"])
        let finishReason = trimmedString(choice?["finish_reason"])
        let status = finishReason == "length" ? "incomplete" : "completed"

        let messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let outputMessage: [String: Any] = [
            "id": messageID,
            "type": "message",
            "status": status,
            "role": "assistant",
            "content": [[
                "type": "output_text",
                "text": text,
                "annotations": []
            ]]
        ]

        return [
            "id": id,
            "object": "response",
            "created_at": numericValue(chatResponse["created"]) ?? Date().timeIntervalSince1970,
            "status": status,
            "model": model,
            "output": [outputMessage],
            "output_text": text,
            "usage": responsesUsage(from: chatResponse["usage"])
        ]
    }

    public static func responsesErrorBody(fromOpenAIError object: [String: Any], fallbackMessage: String) -> [String: Any] {
        let errorObject = object["error"] as? [String: Any]
        let message = trimmedString(errorObject?["message"])
            ?? trimmedString(object["message"])
            ?? fallbackMessage
        let type = trimmedString(errorObject?["type"]) ?? "api_error"
        var error: [String: Any] = [
            "message": message,
            "type": type
        ]
        if let code = errorObject?["code"] ?? object["code"] {
            error["code"] = code
        }
        if let param = errorObject?["param"] ?? object["param"] {
            error["param"] = param
        }
        return [
            "type": "error",
            "error": error
        ]
    }

    private static func inputMessages(from input: Any?) throws -> [[String: Any]] {
        if let text = trimmedString(input) {
            return [["role": "user", "content": text]]
        }

        guard let items = input as? [Any] else {
            return []
        }

        return try items.flatMap { item -> [[String: Any]] in
            if let text = trimmedString(item) {
                return [["role": "user", "content": text]]
            }
            guard let object = item as? [String: Any] else {
                return []
            }

            let type = trimmedString(object["type"])
            if let type, type.contains("function") || type.contains("tool") {
                throw CodexChatBridgeError.unsupportedInputItem(type)
            }
            if type == "reasoning" {
                return []
            }
            if let type, !["message", "input_message", "input_text", "output_text"].contains(type) {
                throw CodexChatBridgeError.unsupportedInputItem(type)
            }

            let role = normalizeRole(trimmedString(object["role"]) ?? "user")
            let content = try textContent(object["content"] ?? object["text"])
            guard !content.isEmpty else {
                return []
            }
            return [["role": role, "content": content]]
        }
    }

    private static func textContent(_ value: Any?) throws -> String {
        if let text = trimmedString(value) {
            return text
        }
        if let object = value as? [String: Any] {
            guard let type = trimmedString(object["type"]) else {
                return trimmedString(object["text"]) ?? ""
            }
            switch type {
            case "text", "input_text", "output_text":
                return trimmedString(object["text"]) ?? ""
            default:
                throw CodexChatBridgeError.unsupportedInputItem(type)
            }
        }
        guard let parts = value as? [Any] else {
            return ""
        }
        var textParts: [String] = []
        for part in parts {
            if let text = trimmedString(part) {
                textParts.append(text)
                continue
            }
            guard let object = part as? [String: Any] else {
                continue
            }
            guard let type = trimmedString(object["type"]) else {
                if let text = trimmedString(object["text"]) {
                    textParts.append(text)
                }
                continue
            }
            switch type {
            case "text", "input_text", "output_text":
                if let text = trimmedString(object["text"]) {
                    textParts.append(text)
                }
            default:
                throw CodexChatBridgeError.unsupportedInputItem(type)
            }
        }
        return textParts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func normalizeRole(_ role: String) -> String {
        switch role {
        case "assistant", "system", "tool":
            return role
        case "developer":
            return "system"
        default:
            return "user"
        }
    }

    private static func firstChoice(_ object: [String: Any]) -> [String: Any]? {
        guard let choices = object["choices"] as? [[String: Any]] else {
            return nil
        }
        return choices.first
    }

    private static func responsesUsage(from value: Any?) -> [String: Any] {
        guard let usage = value as? [String: Any] else {
            return [
                "input_tokens": 0,
                "output_tokens": 0,
                "total_tokens": 0
            ]
        }

        let inputTokens = intValue(usage["prompt_tokens"] ?? usage["input_tokens"]) ?? 0
        let outputTokens = intValue(usage["completion_tokens"] ?? usage["output_tokens"]) ?? 0
        return [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "total_tokens": intValue(usage["total_tokens"]) ?? inputTokens + outputTokens
        ]
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

    private static func numericValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }
}
