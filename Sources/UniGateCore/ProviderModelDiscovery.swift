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
            let headers = ProviderCredentials.modelFetchHeaders(for: provider)
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
            headers: headers,
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

    public static func discoveredCandidates(
        from state: ProviderModelDiscoveryState,
        catalog: ProviderCatalog
    ) -> [ModelCandidate] {
        let providersByRef = providersByRef(in: catalog)
        return state.results.values.flatMap { result -> [ModelCandidate] in
            guard
                let provider = providersByRef[result.providerRef],
                provider.appType == result.appType,
                result.configurationFingerprint == ProviderModelDiscoveryFingerprint.value(for: provider),
                let baseURL = provider.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                !baseURL.isEmpty
            else {
                return []
            }

            let isCustom = isCustomProvider(provider)
            let source: ModelCandidateSource = result.errorMessage == nil ? .discovered : .staleDiscovered
            return mergedModelIDs(result.modelIDs).map { modelID in
                let logicalModel = isCustom ? modelID : ModelNameNormalizer.stripOneMSuffix(modelID)
                return ModelCandidate(
                    logicalModel: logicalModel,
                    providerRef: provider.ref,
                    providerName: provider.name,
                    appType: provider.appType,
                    clientProtocol: clientProtocol(for: provider.appType),
                    apiFormat: provider.apiFormat,
                    upstreamModel: modelID,
                    baseURL: provider.baseURL,
                    requiresTransform: requiresTransform(appType: provider.appType, apiFormat: provider.apiFormat),
                    label: nil,
                    supportsLongContext: ModelNameNormalizer.hasOneMMarker(modelID),
                    source: source
                )
            }
        }
    }

    public static func providersByRef(in catalog: ProviderCatalog) -> [ProviderRef: ImportedProvider] {
        var result: [ProviderRef: ImportedProvider] = [:]
        for provider in catalog.providers {
            result[provider.ref] = provider
        }
        return result
    }

    public static func mergedModelIDs(_ ids: [String]) -> [String] {
        Array(Set(ids.compactMap(trimmed))).sorted()
    }

    private static func clientProtocol(for appType: String) -> ClientProtocolKind {
        UniGateAppRegistry.clientProtocol(for: appType) ?? .openaiChat
    }

    private static func requiresTransform(appType: String, apiFormat: ApiFormat) -> Bool {
        UniGateAppRegistry.requiresTransform(appType: appType, apiFormat: apiFormat) ?? false
    }

    private static func modelsURLOverride(for provider: ImportedProvider) -> String? {
        JSONValueParser.string(provider.meta, ["modelsUrl"])
            ?? JSONValueParser.string(provider.settings, ["modelsUrl"])
            ?? JSONValueParser.string(provider.settings, ["models_url"])
    }

    private static func isCustomProvider(_ provider: ImportedProvider) -> Bool {
        JSONValueParser.string(provider.meta, ["source"]) == "unigate"
    }

    private static func bool(_ object: [String: SendableValue], _ path: [String]) -> Bool? {
        switch JSONValueParser.value(object, path) {
        case let .bool(value):
            return value
        case let .number(value):
            return value != 0
        default:
            return nil
        }
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
