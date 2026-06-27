import Foundation

enum JSONValueParser {
    static func parseObject(_ text: String?) -> [String: SendableValue] {
        guard
            let text,
            let data = text.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data),
            let converted = convert(value),
            case let .object(object) = converted
        else {
            return [:]
        }
        return object
    }

    static func string(_ object: [String: SendableValue], _ path: [String]) -> String? {
        guard case let .string(value)? = value(object, path) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func object(_ object: [String: SendableValue], _ path: [String]) -> [String: SendableValue]? {
        guard case let .object(value)? = value(object, path) else {
            return nil
        }
        return value
    }

    static func value(_ object: [String: SendableValue], _ path: [String]) -> SendableValue? {
        var current: SendableValue = .object(object)
        for key in path {
            guard case let .object(dictionary) = current, let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func convert(_ value: Any) -> SendableValue? {
        switch value {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as Bool:
            return .bool(value)
        case let value as [Any]:
            return .array(value.compactMap(convert))
        case let value as [String: Any]:
            var object: [String: SendableValue] = [:]
            for (key, child) in value {
                object[key] = convert(child) ?? .null
            }
            return .object(object)
        default:
            return nil
        }
    }
}
