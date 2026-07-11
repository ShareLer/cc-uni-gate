import Foundation

public enum ProxyAuthorizationRequirement: Equatable, Sendable {
    case staticProvider
    case codexOfficial(providerRef: ProviderRef)
}

public struct ResolvedRoute: Sendable {
    public let requestedModel: String
    public let routeKey: ModelRouteKey
    public let candidate: ModelCandidate
    public let providerName: String
    public let outboundModel: String
    public let upstreamURL: URL
    public let authorizationRequirement: ProxyAuthorizationRequirement
    public let headers: [String: String]
    public let body: Data
    public let responseTransform: ProxyResponseTransform
}

public enum ProxyResolverError: Error, LocalizedError, Equatable {
    case invalidJSONBody
    case invalidRequest(String)
    case missingModel
    case noRoute(routeKey: String)
    case unavailableRouteTarget(routeKey: String, providerRef: String)
    case missingProvider(ref: String)
    case transformRequired(model: String, provider: String, apiFormat: ApiFormat)
    case streamingTransformUnsupported(model: String, provider: String, apiFormat: ApiFormat)
    case missingBaseURL(provider: String)
    case invalidUpstreamURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSONBody:
            return "Request body must be a JSON object"
        case let .invalidRequest(message):
            return message
        case .missingModel:
            return "Request body must include a string model"
        case let .noRoute(routeKey):
            return "No route configured for \(routeKey)"
        case let .unavailableRouteTarget(routeKey, providerRef):
            return "Route \(routeKey) points to unavailable target \(providerRef)"
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

        let candidate: ModelCandidate
        if let route = routes.routes[routeKey.description] {
            if let activeCandidate = catalog.candidates.first(where: {
                $0.appType == routeKey.appType
                    && $0.logicalModel == routeKey.logicalModel
                    && $0.providerRef == route.providerRef
            }) {
                candidate = activeCandidate
            } else {
                throw ProxyResolverError.unavailableRouteTarget(
                    routeKey: routeKey.description,
                    providerRef: route.providerRef.description
                )
            }
        } else {
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
        outboundBody["model"] = ModelNameNormalizer.stripOneMSuffix(candidate.upstreamModel)
        if responseTransform == .openAIChatToCodexResponse {
            do {
                outboundBody = try CodexChatBridge.chatRequest(from: outboundBody)
            } catch let error as CodexChatBridgeError {
                throw ProxyResolverError.invalidRequest(error.localizedDescription)
            }
        } else if responseTransform == .openAIChatToAnthropicMessages {
            do {
                outboundBody = try AnthropicChatBridge.chatRequest(from: outboundBody)
            } catch let error as AnthropicChatBridgeError {
                throw ProxyResolverError.invalidRequest(error.localizedDescription)
            }
        }
        injectPromptCacheKeyIfConfigured(
            into: &outboundBody,
            provider: provider,
            apiFormat: candidate.apiFormat
        )
        let outboundData = try JSONSerialization.data(withJSONObject: outboundBody, options: [])
        let upstreamURL = try buildUpstreamURL(
            provider: provider,
            inboundPath: path,
            protocolKind: protocolKind,
            apiFormat: candidate.apiFormat
        )

        let authorizationRequirement: ProxyAuthorizationRequirement
        let headers: [String: String]
        if provider.backendKind == .codexOfficial {
            authorizationRequirement = .codexOfficial(providerRef: provider.ref)
            headers = [:]
        } else {
            authorizationRequirement = .staticProvider
            headers = ProviderCredentials.proxyAuthHeaders(for: provider)
        }

        return ResolvedRoute(
            requestedModel: requestedModel,
            routeKey: routeKey,
            candidate: candidate,
            providerName: provider.name,
            outboundModel: ModelNameNormalizer.stripOneMSuffix(candidate.upstreamModel),
            upstreamURL: upstreamURL,
            authorizationRequirement: authorizationRequirement,
            headers: headers,
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
        if protocolKind == .anthropicMessages, candidate.apiFormat == .openaiChat {
            return .openAIChatToAnthropicMessages
        }
        if protocolKind == .codexResponses, candidate.apiFormat == .openaiChat {
            if (body["stream"] as? Bool) == true {
                throw ProxyResolverError.streamingTransformUnsupported(
                    model: requestedModel,
                    provider: provider.name,
                    apiFormat: candidate.apiFormat
                )
            }
            return .openAIChatToCodexResponse
        }
        return .none
    }

    private static func injectPromptCacheKeyIfConfigured(
        into body: inout [String: Any],
        provider: ImportedProvider,
        apiFormat: ApiFormat
    ) {
        guard apiFormat == .openaiChat || apiFormat == .openaiResponses else {
            return
        }
        guard let promptCacheKey = promptCacheKey(for: provider) else {
            return
        }
        body["prompt_cache_key"] = promptCacheKey
    }

    private static func promptCacheKey(for provider: ImportedProvider) -> String? {
        JSONValueParser.string(provider.meta, ["promptCacheKey"])
            ?? JSONValueParser.string(provider.meta, ["prompt_cache_key"])
            ?? JSONValueParser.string(provider.settings, ["promptCacheKey"])
            ?? JSONValueParser.string(provider.settings, ["prompt_cache_key"])
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

        // Codex model IDs are exact route keys. In particular, a disabled
        // "[1m]" route must not fall back to its enabled base model.
        if appType == UniGateAppRegistry.codex {
            return exactKey
        }

        let normalizedRequest = ModelNameNormalizer.stripOneMSuffix(requestedModel)
        let normalizedKey = ModelRouteKey(appType: appType, logicalModel: normalizedRequest)
        if routes.routes[normalizedKey.description] != nil {
            return normalizedKey
        }

        guard ModelRouteVisibility.isClaudeLikeApp(appType) else {
            return exactKey
        }

        let keys = catalog.routeKeys(for: appType)
        if let match = keys.first(where: {
            routes.routes[$0.description] != nil
                && ModelNameNormalizer.stripOneMSuffix($0.logicalModel).caseInsensitiveCompare(normalizedRequest) == .orderedSame
        }) {
            return match
        }

        guard appType == UniGateAppRegistry.claudeCode else {
            return exactKey
        }
        guard let role = ClaudeRouteRole.role(in: normalizedRequest) else {
            return exactKey
        }

        if let match = keys.first(where: { ClaudeRouteRole.role(in: $0.logicalModel) == role && routes.routes[$0.description] != nil }) {
            return match
        }

        return exactKey
    }

    private static func parseJSONBody(_ body: Data) throws -> [String: Any] {
        guard !body.isEmpty else {
            throw ProxyResolverError.invalidJSONBody
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw ProxyResolverError.invalidJSONBody
        }
        guard let object = value as? [String: Any] else {
            throw ProxyResolverError.invalidJSONBody
        }
        return object
    }

    private static func defaultAppType(for protocolKind: ClientProtocolKind) -> String {
        switch protocolKind {
        case .codexResponses, .openaiChat:
            return UniGateAppRegistry.codex
        case .anthropicMessages:
            return UniGateAppRegistry.claudeCode
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

    private static func buildUpstreamURL(
        provider: ImportedProvider,
        inboundPath: String,
        protocolKind: ClientProtocolKind,
        apiFormat: ApiFormat
    ) throws -> URL {
        if provider.backendKind == .codexOfficial {
            let path = inboundPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? inboundPath
            let endpoint: String
            if path.hasSuffix("/responses/compact") {
                endpoint = "responses/compact"
            } else if path.hasSuffix("/responses") {
                endpoint = "responses"
            } else {
                throw ProxyResolverError.invalidRequest(
                    "Codex official providers only support /responses and /responses/compact"
                )
            }
            return CodexOfficial.backendBaseURL.appendingPathComponent(endpoint)
        }

        guard let baseURL = provider.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !baseURL.isEmpty else {
            throw ProxyResolverError.missingBaseURL(provider: provider.name)
        }

        if isFullURL(provider) {
            guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else {
                throw ProxyResolverError.invalidUpstreamURL(baseURL)
            }
            return url
        }

        guard
            var components = URLComponents(string: baseURL),
            components.scheme != nil,
            components.host != nil
        else {
            throw ProxyResolverError.invalidUpstreamURL(baseURL)
        }
        let inboundComponents = URLComponents(string: inboundPath)
        let inboundPathOnly = inboundComponents?.percentEncodedPath
            ?? inboundPath.split(separator: "?", maxSplits: 1).first.map(String.init)
            ?? inboundPath
        let endpoint = normalizeEndpoint(
            provider: provider,
            inboundPath: inboundPathOnly,
            protocolKind: protocolKind,
            apiFormat: apiFormat
        )
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path: String
        if baseEndsWithAnyEndpoint("/\(basePath)", endpoints: endpointSuffixVariants(for: endpoint)) {
            path = "/\(basePath)"
        } else if provider.appType == UniGateAppRegistry.codex, isOriginOnlyURL(baseURL) {
            path = "/v1/\(endpoint)"
        } else {
            path = "/\([basePath, endpoint].filter { !$0.isEmpty }.joined(separator: "/"))"
        }
        components.percentEncodedPath = path.replacingOccurrences(of: "/v1/v1/", with: "/v1/")
        let queryItems = (components.queryItems ?? []) + (inboundComponents?.queryItems ?? [])
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw ProxyResolverError.invalidUpstreamURL(baseURL)
        }
        return url
    }

    private static func isFullURL(_ provider: ImportedProvider) -> Bool {
        switch JSONValueParser.value(provider.meta, ["isFullUrl"]) {
        case let .bool(value):
            return value
        case let .number(value):
            return value != 0
        default:
            return false
        }
    }

    private static func normalizeEndpoint(
        provider: ImportedProvider,
        inboundPath: String,
        protocolKind: ClientProtocolKind,
        apiFormat: ApiFormat
    ) -> String {
        let path = inboundPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? inboundPath

        if provider.appType == UniGateAppRegistry.codex {
            if protocolKind == .codexResponses, apiFormat == .openaiChat {
                return "/v1/chat/completions"
            }
            return stripManagerPrefixes(path, prefixes: ["/openai", "/codex"])
        }

        if UniGateAppRegistry.isClaudeLike(provider.appType) {
            if protocolKind == .anthropicMessages, apiFormat == .openaiChat {
                return "/v1/chat/completions"
            }
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

    private static func isOriginOnlyURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
            return false
        }
        return url.path.isEmpty || url.path == "/"
    }

    private static func baseEndsWithAnyEndpoint(_ base: String, endpoints: [String]) -> Bool {
        let base = base.lowercased()
        return endpoints.contains { endpoint in
            base.hasSuffix(endpoint.lowercased())
        }
    }

    private static func endpointSuffixVariants(for endpoint: String) -> [String] {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            return []
        }
        var variants = ["/\(trimmed)"]
        if trimmed.hasPrefix("v1/") {
            variants.append("/\(trimmed.dropFirst(3))")
        }
        return variants
    }
}
