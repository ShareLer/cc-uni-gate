import Foundation

public struct ProviderModelFetchPlan: Sendable {
    public let providerRef: ProviderRef
    public let urls: [URL]
    public let headers: [String: String]
    public let userAgent: String?

    public init(providerRef: ProviderRef, urls: [URL], headers: [String: String], userAgent: String?) {
        self.providerRef = providerRef
        self.urls = urls
        self.headers = headers
        self.userAgent = userAgent
    }
}

public enum ProviderModelDiscovery {
    private static let knownCompatSuffixes = [
        "/api/claudecode",
        "/api/anthropic",
        "/apps/anthropic",
        "/api/coding",
        "/claudecode",
        "/anthropic",
        "/step_plan",
        "/coding",
        "/claude"
    ]

    public static func fetchPlan(for provider: ImportedProvider) -> ProviderModelFetchPlan? {
        guard
            let baseURL = provider.baseURL,
            let secret = secret(for: provider)
        else {
            return nil
        }
        let urls = modelURLCandidates(
            baseURL: baseURL,
            isFullURL: bool(provider.meta, ["isFullUrl"]) ?? false,
            modelsURLOverride: modelsURLOverride(for: provider)
        )
        guard !urls.isEmpty else {
            return nil
        }
        return ProviderModelFetchPlan(
            providerRef: provider.ref,
            urls: urls,
            headers: modelFetchHeaders(secret: secret),
            userAgent: JSONValueParser.string(provider.meta, ["customUserAgent"])
        )
    }

    public static func modelURLCandidates(
        baseURL: String,
        isFullURL: Bool = false,
        modelsURLOverride: String? = nil
    ) -> [URL] {
        if let override = trimmed(modelsURLOverride), let url = URL(string: override) {
            return [url]
        }

        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty else {
            return []
        }

        var candidates: [String] = []
        if isFullURL {
            if let range = trimmedBase.range(of: "/v1/") {
                candidates.append("\(trimmedBase[..<range.lowerBound])/v1/models")
            } else if let slash = trimmedBase.lastIndex(of: "/") {
                let root = String(trimmedBase[..<slash])
                if root.contains("://"), root.count > (root.range(of: "://")?.upperBound.utf16Offset(in: root) ?? 0) {
                    candidates.append("\(root)/v1/models")
                }
            }
            return uniqueURLs(candidates)
        }

        if endsWithVersionSegment(trimmedBase) {
            candidates.append("\(trimmedBase)/models")
            if !trimmedBase.hasSuffix("/v1") {
                candidates.append("\(trimmedBase)/v1/models")
            }
        } else {
            candidates.append("\(trimmedBase)/v1/models")
        }

        if let stripped = stripCompatSuffix(trimmedBase) {
            let root = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !root.isEmpty, root.contains("://") {
                candidates.append("\(root)/v1/models")
                candidates.append("\(root)/models")
            }
        }

        return uniqueURLs(candidates)
    }

    public static func modelIDs(from responseData: Data) -> [String] {
        guard
            let value = try? JSONSerialization.jsonObject(with: responseData),
            let object = value as? [String: Any]
        else {
            return []
        }

        var ids: [String] = []
        if let data = object["data"] as? [[String: Any]] {
            ids.append(contentsOf: data.compactMap { trimmed($0["id"] as? String) })
        }
        if let models = object["models"] as? [String] {
            ids.append(contentsOf: models.compactMap(trimmed))
        } else if let models = object["models"] as? [[String: Any]] {
            ids.append(contentsOf: models.compactMap {
                trimmed($0["id"] as? String)
                    ?? trimmed($0["model"] as? String)
                    ?? trimmed($0["slug"] as? String)
            })
        }
        return mergedModelIDs(ids)
    }

    public static func configuredUpstreamModelIDs(from catalog: ProviderCatalog, appType: String) -> [String] {
        mergedModelIDs(catalog.candidates.compactMap { candidate in
            guard
                candidate.appType == appType,
                candidate.providerRef == candidate.upstreamProviderRef
            else {
                return nil
            }
            return ModelNameNormalizer.stripOneMSuffix(candidate.upstreamModel)
        })
    }

    public static func mergedModelIDs(_ ids: [String]) -> [String] {
        Array(Set(ids.compactMap(trimmed))).sorted()
    }

    private static func modelFetchHeaders(secret: (field: String, value: String)) -> [String: String] {
        var headers = ["authorization": "Bearer \(secret.value)"]
        if secret.field.hasSuffix("ANTHROPIC_API_KEY") {
            headers["x-api-key"] = secret.value
        }
        return headers
    }

    private static func secret(for provider: ImportedProvider) -> (field: String, value: String)? {
        let paths: [[String]]
        switch provider.appType {
        case "codex":
            paths = [["auth", "OPENAI_API_KEY"], ["env", "OPENAI_API_KEY"]]
        case "claude", "claude-desktop":
            paths = [
                ["env", "ANTHROPIC_AUTH_TOKEN"],
                ["env", "ANTHROPIC_API_KEY"],
                ["env", "OPENAI_API_KEY"],
                ["apiKey"],
                ["api_key"]
            ]
        case "gemini":
            paths = [["env", "GEMINI_API_KEY"], ["env", "GOOGLE_API_KEY"]]
        default:
            paths = [["api_key"]]
        }

        for path in paths {
            if let value = JSONValueParser.string(provider.settings, path) {
                return (path.joined(separator: "."), value)
            }
        }
        return nil
    }

    private static func modelsURLOverride(for provider: ImportedProvider) -> String? {
        JSONValueParser.string(provider.meta, ["modelsUrl"])
            ?? JSONValueParser.string(provider.settings, ["modelsUrl"])
            ?? JSONValueParser.string(provider.settings, ["models_url"])
    }

    private static func bool(_ object: [String: SendableValue], _ path: [String]) -> Bool? {
        guard case let .bool(value)? = JSONValueParser.value(object, path) else {
            return nil
        }
        return value
    }

    private static func endsWithVersionSegment(_ url: String) -> Bool {
        let last = url.split(separator: "/").last.map(String.init) ?? ""
        guard last.hasPrefix("v"), last.count > 1 else {
            return false
        }
        return last.dropFirst().allSatisfy(\.isNumber)
    }

    private static func stripCompatSuffix(_ baseURL: String) -> String? {
        let lowercased = baseURL.lowercased()
        for suffix in knownCompatSuffixes where lowercased.hasSuffix(suffix) {
            return String(baseURL.dropLast(suffix.count))
        }
        return nil
    }

    private static func uniqueURLs(_ values: [String]) -> [URL] {
        var result: [URL] = []
        for value in values {
            guard let url = URL(string: value), !result.contains(url) else {
                continue
            }
            result.append(url)
        }
        return result
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
