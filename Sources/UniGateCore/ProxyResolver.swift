import Foundation

public struct ResolvedRoute: Sendable {
    public let candidate: ModelCandidate
    public let providerName: String
    public let outboundModel: String
    public let upstreamURL: URL
    public let headers: [String: String]
    public let body: Data
    public let responseTransform: ProxyResponseTransform
}

public enum ProxyResolverError: Error, LocalizedError, Equatable {
    case invalidJSONBody
    case missingModel
    case noRoute(routeKey: String)
    case missingProvider(ref: String)
    case transformRequired(model: String, provider: String, apiFormat: ApiFormat)
    case streamingTransformUnsupported(model: String, provider: String, apiFormat: ApiFormat)
    case missingBaseURL(provider: String)
    case invalidUpstreamURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSONBody:
            return "Request body must be a JSON object"
        case .missingModel:
            return "Request body must include a string model"
        case let .noRoute(routeKey):
            return "No route configured for \(routeKey)"
        case let .missingProvider(ref):
            return "Provider \(ref) is missing from catalog"
        case let .transformRequired(model, provider, apiFormat):
            return "Route \(model) -> \(provider) requires protocol transform (\(apiFormat.rawValue))"
        case let .streamingTransformUnsupported(model, provider, apiFormat):
            return "Route \(model) -> \(provider) does not support streaming protocol transform yet (\(apiFormat.rawValue))"
        case let .missingBaseURL(provider):
            return "Provider \(provider) has no base URL"
        case let .invalidUpstreamURL(value):
            return "Invalid upstream URL: \(value)"
        }
    }
}

public enum ProxyResolver {
    public static func resolveRoute(
        catalog: ProviderCatalog,
        routes: RouteState,
        protocolKind: ClientProtocolKind,
        appType: String? = nil,
        path: String,
        body: Data
    ) throws -> ResolvedRoute {
        let json = try parseJSONBody(body)
        guard let requestedModel = stringField(json["model"]) else {
            throw ProxyResolverError.missingModel
        }
        let routeAppType = appType ?? defaultAppType(for: protocolKind)
        let routeKey = resolveRouteKey(
            requestedModel: requestedModel,
            appType: routeAppType,
            routes: routes,
            catalog: catalog
        )

        guard
            let route = routes.routes[routeKey.description],
            let candidate = catalog.candidates.first(where: {
                $0.appType == routeKey.appType
                    && $0.logicalModel == routeKey.logicalModel
                    && $0.providerRef == route.providerRef
            })
        else {
            throw ProxyResolverError.noRoute(routeKey: routeKey.description)
        }

        guard let provider = catalog.providers.first(where: { $0.ref == candidate.upstreamProviderRef }) else {
            throw ProxyResolverError.missingProvider(ref: candidate.upstreamProviderRef.description)
        }

        let responseTransform = try responseTransform(
            protocolKind: protocolKind,
            candidate: candidate,
            requestedModel: requestedModel,
            provider: provider,
            body: json
        )
        if responseTransform == .none && unsupportedProtocolPair(protocolKind: protocolKind, apiFormat: candidate.apiFormat) {
            throw ProxyResolverError.transformRequired(
                model: requestedModel,
                provider: provider.name,
                apiFormat: candidate.apiFormat
            )
        }

        var outboundBody = json
        outboundBody["model"] = stripOneMSuffix(candidate.upstreamModel)
        if responseTransform == .openAIChatToCodexResponse {
            outboundBody = try CodexChatBridge.chatRequest(from: outboundBody)
        }
        let outboundData = try JSONSerialization.data(withJSONObject: outboundBody, options: [])
        let upstreamURL = try buildUpstreamURL(
            provider: provider,
            inboundPath: path,
            protocolKind: protocolKind,
            apiFormat: candidate.apiFormat
        )

        return ResolvedRoute(
            candidate: candidate,
            providerName: provider.name,
            outboundModel: stripOneMSuffix(candidate.upstreamModel),
            upstreamURL: upstreamURL,
            headers: buildAuthHeaders(provider),
            body: outboundData,
            responseTransform: responseTransform
        )
    }

    private static func responseTransform(
        protocolKind: ClientProtocolKind,
        candidate: ModelCandidate,
        requestedModel: String,
        provider: ImportedProvider,
        body: [String: Any]
    ) throws -> ProxyResponseTransform {
        guard protocolKind == .codexResponses, candidate.apiFormat == .openaiChat else {
            return .none
        }
        if (body["stream"] as? Bool) == true {
            throw ProxyResolverError.streamingTransformUnsupported(
                model: requestedModel,
                provider: provider.name,
                apiFormat: candidate.apiFormat
            )
        }
        return .openAIChatToCodexResponse
    }

    private static func unsupportedProtocolPair(protocolKind: ClientProtocolKind, apiFormat: ApiFormat) -> Bool {
        switch protocolKind {
        case .codexResponses:
            return apiFormat != .openaiResponses && apiFormat != .openaiChat
        case .openaiChat:
            return apiFormat != .openaiChat
        case .anthropicMessages:
            return apiFormat != .anthropic
        case .geminiNative:
            return apiFormat != .geminiNative
        }
    }

    private static func resolveRouteKey(
        requestedModel: String,
        appType: String,
        routes: RouteState,
        catalog: ProviderCatalog
    ) -> ModelRouteKey {
        let exactKey = ModelRouteKey(appType: appType, logicalModel: requestedModel)
        if routes.routes[exactKey.description] != nil {
            return exactKey
        }

        let normalizedRequest = stripOneMSuffix(requestedModel)
        let normalizedKey = ModelRouteKey(appType: appType, logicalModel: normalizedRequest)
        if routes.routes[normalizedKey.description] != nil {
            return normalizedKey
        }

        guard appType == "claude" || appType == "claude-desktop" else {
            return exactKey
        }

        let keys = catalog.routeKeys(for: appType)
        if let match = keys.first(where: {
            routes.routes[$0.description] != nil
                && stripOneMSuffix($0.logicalModel).caseInsensitiveCompare(normalizedRequest) == .orderedSame
        }) {
            return match
        }

        guard let role = claudeRoleKeyword(normalizedRequest) else {
            return exactKey
        }

        if let match = keys.first(where: { claudeRoleKeyword($0.logicalModel) == role && routes.routes[$0.description] != nil }) {
            return match
        }
        if role == "fable",
           let opus = keys.first(where: { claudeRoleKeyword($0.logicalModel) == "opus" && routes.routes[$0.description] != nil }) {
            return opus
        }
        return exactKey
    }

    private static func parseJSONBody(_ body: Data) throws -> [String: Any] {
        guard !body.isEmpty else {
            throw ProxyResolverError.invalidJSONBody
        }
        let value = try JSONSerialization.jsonObject(with: body)
        guard let object = value as? [String: Any] else {
            throw ProxyResolverError.invalidJSONBody
        }
        return object
    }

    private static func defaultAppType(for protocolKind: ClientProtocolKind) -> String {
        switch protocolKind {
        case .codexResponses, .openaiChat:
            return "codex"
        case .anthropicMessages:
            return "claude"
        case .geminiNative:
            return "gemini"
        }
    }

    private static func stringField(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripOneMSuffix(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"\[\s*1m\s*\]\s*$"#, options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func claudeRoleKeyword(_ model: String) -> String? {
        let normalized = model.lowercased()
        if normalized.contains("opus") {
            return "opus"
        }
        if normalized.contains("haiku") {
            return "haiku"
        }
        if normalized.contains("fable") {
            return "fable"
        }
        if normalized.contains("sonnet") {
            return "sonnet"
        }
        return nil
    }

    private static func buildUpstreamURL(
        provider: ImportedProvider,
        inboundPath: String,
        protocolKind: ClientProtocolKind,
        apiFormat: ApiFormat
    ) throws -> URL {
        guard let baseURL = provider.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !baseURL.isEmpty else {
            throw ProxyResolverError.missingBaseURL(provider: provider.name)
        }

        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = normalizeEndpoint(
            provider: provider,
            inboundPath: inboundPath,
            protocolKind: protocolKind,
            apiFormat: apiFormat
        )
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let raw: String
        if provider.appType == "codex",
           apiFormat == .openaiChat,
           base.lowercased().hasSuffix("/chat/completions") {
            raw = base
        } else if provider.appType == "codex", isOriginOnlyURL(baseURL) {
            raw = "\(base)/v1/\(endpoint)"
        } else {
            raw = "\(base)/\(endpoint)"
        }
        let normalized = raw.replacingOccurrences(of: "/v1/v1/", with: "/v1/")
        guard let url = URL(string: normalized) else {
            throw ProxyResolverError.invalidUpstreamURL(normalized)
        }
        return url
    }

    private static func normalizeEndpoint(
        provider: ImportedProvider,
        inboundPath: String,
        protocolKind: ClientProtocolKind,
        apiFormat: ApiFormat
    ) -> String {
        let path = inboundPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? inboundPath

        if provider.appType == "codex" {
            if protocolKind == .codexResponses, apiFormat == .openaiChat {
                return "/v1/chat/completions"
            }
            return stripManagerPrefixes(path, prefixes: ["/openai", "/codex"])
        }

        if provider.appType == "claude" || provider.appType == "claude-desktop" {
            return stripManagerPrefixes(path, prefixes: ["/anthropic", "/claude-code", "/claude", "/claude-desktop"])
        }

        return path
    }

    private static func stripManagerPrefixes(_ path: String, prefixes: [String]) -> String {
        for prefix in prefixes {
            let stripped = stripManagerPrefix(path, prefix: prefix)
            if stripped != path {
                return stripped
            }
        }
        return path
    }

    private static func stripManagerPrefix(_ path: String, prefix: String) -> String {
        if path == prefix {
            return "/"
        }
        if path.hasPrefix("\(prefix)/") {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    private static func buildAuthHeaders(_ provider: ImportedProvider) -> [String: String] {
        guard let secret = secret(for: provider) else {
            return [:]
        }

        if provider.appType == "codex" {
            return ["authorization": "Bearer \(secret.value)"]
        }

        if secret.field.hasSuffix("ANTHROPIC_API_KEY") {
            return ["x-api-key": secret.value]
        }

        if provider.appType == "claude" || provider.appType == "claude-desktop" {
            return ["authorization": "Bearer \(secret.value)"]
        }

        return ["authorization": "Bearer \(secret.value)"]
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

    private static func isOriginOnlyURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
            return false
        }
        return url.path.isEmpty || url.path == "/"
    }
}
