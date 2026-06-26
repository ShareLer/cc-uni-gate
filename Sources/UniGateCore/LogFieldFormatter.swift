import Foundation

public struct LogField: Sendable, Equatable {
    public var key: String
    public var value: String?

    public init(_ key: String, _ value: String?) {
        self.key = key
        self.value = value
    }

    public init<Value: CustomStringConvertible>(_ key: String, _ value: Value) {
        self.key = key
        self.value = value.description
    }

    public init<Value: CustomStringConvertible>(_ key: String, _ value: Value?) {
        self.key = key
        self.value = value?.description
    }
}

public enum LogFieldFormatter {
    public static func format(_ fields: [LogField]) -> String {
        fields.map { field in
            "\(field.key)=\(formatValue(field.value))"
        }.joined(separator: " ")
    }

    private static func formatValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "-"
        }
        if value.rangeOfCharacter(from: quotedCharacterSet) == nil {
            return value
        }
        return "\"\(escape(value))\""
    }

    private static var quotedCharacterSet: CharacterSet {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\"\\")
        return set
    }

    private static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
