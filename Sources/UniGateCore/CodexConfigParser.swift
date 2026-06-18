import Foundation

struct CodexConfig {
    var model: String?
    var baseURL: String?
    var wireAPI: String?
}

enum CodexConfigParser {
    static func parse(_ text: String?) -> CodexConfig {
        guard let text else {
            return CodexConfig()
        }

        var config = CodexConfig()
        var activeProvider: String?
        var currentSection: String?
        var providerValues: [String: [String: String]] = [:]
        var rootValues: [String: String] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if line.isEmpty {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }

            guard let (key, value) = parseAssignment(line) else {
                continue
            }

            if currentSection == nil {
                rootValues[key] = value
                if key == "model_provider" {
                    activeProvider = value
                } else if key == "model" {
                    config.model = value
                }
                continue
            }

            if let currentSection, currentSection.hasPrefix("model_providers.") {
                let providerName = String(currentSection.dropFirst("model_providers.".count))
                var values = providerValues[providerName] ?? [:]
                values[key] = value
                providerValues[providerName] = values
            }
        }

        let activeValues = activeProvider.flatMap { providerValues[$0] }
        config.baseURL = activeValues?["base_url"] ?? rootValues["base_url"]
        config.wireAPI = activeValues?["wire_api"] ?? rootValues["wire_api"]
        return config
    }

    private static func parseAssignment(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(of: "=") else {
            return nil
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if
            value.count >= 2,
            let first = value.first,
            let last = value.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            value.removeFirst()
            value.removeLast()
        }
        return key.isEmpty ? nil : (key, value)
    }
}

