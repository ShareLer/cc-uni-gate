import Foundation

public enum ApiFormat: String, Codable, Sendable {
    case anthropic
    case openaiResponses = "openai_responses"
    case openaiChat = "openai_chat"
    case geminiNative = "gemini_native"
    case unknown
}

public enum ClientProtocolKind: String, Codable, Sendable {
    case codexResponses = "codex_responses"
    case openaiChat = "openai_chat"
    case anthropicMessages = "anthropic_messages"
    case geminiNative = "gemini_native"
}

public enum ProxyResponseTransform: String, Codable, Sendable {
    case none
    case openAIChatToCodexResponse = "openai_chat_to_codex_response"
}

public enum ProxyRequestPath: Equatable, Sendable {
    case proxy(protocolKind: ClientProtocolKind, appType: String)
    case models(appType: String?)
    case unsupported

    public init(_ rawPath: String) {
        let rawPath = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let scoped = Self.scopedPath(rawPath)
        let path = scoped.path

        if Self.modelPaths.contains(path) {
            self = .models(appType: scoped.appType)
        } else if Self.claudePaths.contains(path) {
            self = .proxy(protocolKind: .anthropicMessages, appType: scoped.appType ?? "claude")
        } else if Self.claudeDesktopPaths.contains(path) {
            self = .proxy(protocolKind: .anthropicMessages, appType: "claude-desktop")
        } else if Self.codexResponsesPaths.contains(path) {
            self = .proxy(protocolKind: .codexResponses, appType: scoped.appType ?? "codex")
        } else if Self.openAIChatPaths.contains(path) {
            self = .proxy(protocolKind: .openaiChat, appType: scoped.appType ?? "codex")
        } else {
            self = .unsupported
        }
    }

    private static func scopedPath(_ path: String) -> (path: String, appType: String?) {
        for (prefix, appType) in appPrefixes {
            if path == prefix {
                return ("/", appType)
            }
            if path.hasPrefix("\(prefix)/") {
                return (String(path.dropFirst(prefix.count)), appType)
            }
        }
        return (path, nil)
    }

    private static let appPrefixes: [(String, String)] = [
        ("/claude-desktop", "claude-desktop"),
        ("/claude-code", "claude"),
        ("/claude", "claude"),
        ("/anthropic", "claude"),
        ("/codex", "codex"),
        ("/openai", "codex")
    ]

    private static let modelPaths: Set<String> = [
        "/models", "/v1/models", "/v1/v1/models"
    ]

    private static let claudePaths: Set<String> = [
        "/v1/messages", "/v1/messages/count_tokens"
    ]

    private static let claudeDesktopPaths: Set<String> = [
        "/claude-desktop/v1/messages",
        "/claude-desktop/v1/messages/count_tokens"
    ]

    private static let codexResponsesPaths: Set<String> = [
        "/responses", "/responses/compact",
        "/v1/responses", "/v1/responses/compact",
        "/v1/v1/responses", "/v1/v1/responses/compact"
    ]

    private static let openAIChatPaths: Set<String> = [
        "/chat/completions", "/v1/chat/completions",
        "/v1/v1/chat/completions"
    ]
}

public struct ModelRouteKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let appType: String
    public let logicalModel: String

    public init(appType: String, logicalModel: String) {
        self.appType = appType
        self.logicalModel = logicalModel
    }

    public init(candidate: ModelCandidate) {
        self.appType = candidate.appType
        self.logicalModel = candidate.logicalModel
    }

    public init?(description: String) {
        guard let separator = description.firstIndex(of: ":") else {
            return nil
        }
        let appType = String(description[..<separator])
        let logicalModel = String(description[description.index(after: separator)...])
        guard !appType.isEmpty, !logicalModel.isEmpty else {
            return nil
        }
        self.appType = appType
        self.logicalModel = logicalModel
    }

    public var description: String {
        "\(appType):\(logicalModel)"
    }

    public var displayName: String {
        "\(ProviderDisplay.appTypeLabel(appType)) · \(logicalModel)"
    }
}

public struct ProviderRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public let appType: String
    public let id: String

    public init(appType: String, id: String) {
        self.appType = appType
        self.id = id
    }

    public init?(description: String) {
        let parts = description.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "cc-switch" else {
            return nil
        }
        self.appType = parts[1]
        self.id = parts[2]
    }

    public var description: String {
        "cc-switch:\(appType):\(id)"
    }
}

public struct ImportedProvider: Identifiable, Sendable {
    public let id: String
    public let appType: String
    public let name: String
    public let category: String?
    public let sortIndex: Int?
    public let isCurrent: Bool
    public let apiFormat: ApiFormat
    public let baseURL: String?
    public let hasSecret: Bool
    public let settings: [String: SendableValue]
    public let meta: [String: SendableValue]

    public var ref: ProviderRef {
        ProviderRef(appType: appType, id: id)
    }

    public var displayName: String {
        "\(name) · \(ProviderDisplay.appTypeLabel(appType))"
    }

    public init(
        id: String,
        appType: String,
        name: String,
        category: String?,
        sortIndex: Int?,
        isCurrent: Bool,
        apiFormat: ApiFormat,
        baseURL: String?,
        hasSecret: Bool,
        settings: [String: SendableValue],
        meta: [String: SendableValue]
    ) {
        self.id = id
        self.appType = appType
        self.name = name
        self.category = category
        self.sortIndex = sortIndex
        self.isCurrent = isCurrent
        self.apiFormat = apiFormat
        self.baseURL = baseURL
        self.hasSecret = hasSecret
        self.settings = settings
        self.meta = meta
    }

    public func withApiFormat(_ apiFormat: ApiFormat) -> ImportedProvider {
        ImportedProvider(
            id: id,
            appType: appType,
            name: name,
            category: category,
            sortIndex: sortIndex,
            isCurrent: isCurrent,
            apiFormat: apiFormat,
            baseURL: baseURL,
            hasSecret: hasSecret,
            settings: settings,
            meta: meta
        )
    }
}

public enum ProviderDisplay {
    public static func appTypeLabel(_ appType: String) -> String {
        switch appType {
        case "codex":
            return "Codex"
        case "claude":
            return "Claude Code"
        case "claude-desktop":
            return "Claude Desktop"
        case "gemini":
            return "Gemini"
        default:
            return appType
        }
    }
}

public struct ModelCandidate: Identifiable, Sendable {
    public let logicalModel: String
    public let providerRef: ProviderRef
    public let providerName: String
    public let appType: String
    public let clientProtocol: ClientProtocolKind
    public let apiFormat: ApiFormat
    public let upstreamModel: String
    public let baseURL: String?
    public let requiresTransform: Bool
    public let label: String?
    public let supportsLongContext: Bool

    public var id: String {
        "\(routeKey.description)|\(providerRef.description)"
    }

    public var routeKey: ModelRouteKey {
        ModelRouteKey(appType: appType, logicalModel: logicalModel)
    }

    public init(
        logicalModel: String,
        providerRef: ProviderRef,
        providerName: String,
        appType: String,
        clientProtocol: ClientProtocolKind,
        apiFormat: ApiFormat,
        upstreamModel: String,
        baseURL: String?,
        requiresTransform: Bool,
        label: String?,
        supportsLongContext: Bool
    ) {
        self.logicalModel = logicalModel
        self.providerRef = providerRef
        self.providerName = providerName
        self.appType = appType
        self.clientProtocol = clientProtocol
        self.apiFormat = apiFormat
        self.upstreamModel = upstreamModel
        self.baseURL = baseURL
        self.requiresTransform = requiresTransform
        self.label = label
        self.supportsLongContext = supportsLongContext
    }

    public func withApiFormat(_ apiFormat: ApiFormat) -> ModelCandidate {
        ModelCandidate(
            logicalModel: logicalModel,
            providerRef: providerRef,
            providerName: providerName,
            appType: appType,
            clientProtocol: clientProtocol,
            apiFormat: apiFormat,
            upstreamModel: upstreamModel,
            baseURL: baseURL,
            requiresTransform: requiresTransform(for: appType, apiFormat: apiFormat),
            label: label,
            supportsLongContext: supportsLongContext
        )
    }

    private func requiresTransform(for appType: String, apiFormat: ApiFormat) -> Bool {
        if appType == "codex" {
            return apiFormat != .openaiResponses && apiFormat != .openaiChat
        }
        if appType == "claude" || appType == "claude-desktop" {
            return apiFormat != .anthropic
        }
        return requiresTransform
    }
}

public struct ProviderCatalog: Sendable {
    public let providers: [ImportedProvider]
    public let candidates: [ModelCandidate]

    public init(providers: [ImportedProvider], candidates: [ModelCandidate]) {
        self.providers = providers
        self.candidates = candidates
    }

    public var models: [String] {
        Array(Set(candidates.map(\.logicalModel))).sorted()
    }

    public var routeKeys: [ModelRouteKey] {
        Array(Set(candidates.map(\.routeKey))).sorted { lhs, rhs in
            let appCompare = ProviderDisplay.appTypeLabel(lhs.appType)
                .localizedStandardCompare(ProviderDisplay.appTypeLabel(rhs.appType))
            if appCompare != .orderedSame {
                return appCompare == .orderedAscending
            }
            return lhs.logicalModel.localizedStandardCompare(rhs.logicalModel) == .orderedAscending
        }
    }

    public var appTypes: [String] {
        Array(Set(candidates.map(\.appType))).sorted {
            ProviderDisplay.appTypeLabel($0).localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
    }

    public func candidates(for model: String) -> [ModelCandidate] {
        candidates
            .filter { $0.logicalModel == model }
            .sorted { lhs, rhs in
                lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
            }
    }

    public func candidates(for key: ModelRouteKey) -> [ModelCandidate] {
        candidates
            .filter { $0.appType == key.appType && $0.logicalModel == key.logicalModel }
            .sorted { lhs, rhs in
                lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
            }
    }

    public func routeKeys(for appType: String) -> [ModelRouteKey] {
        routeKeys.filter { $0.appType == appType }
    }

    public func applyingProtocolOverrides(_ overrides: [String: ApiFormat]) -> ProviderCatalog {
        guard !overrides.isEmpty else {
            return self
        }
        let providers = providers.map { provider in
            guard let override = overrides[provider.ref.description] else {
                return provider
            }
            return provider.withApiFormat(override)
        }
        let candidates = candidates.map { candidate in
            guard let override = overrides[candidate.providerRef.description] else {
                return candidate
            }
            return candidate.withApiFormat(override)
        }
        return ProviderCatalog(providers: providers, candidates: candidates)
    }
}

public struct ActiveRoute: Codable, Sendable {
    public let appType: String
    public let logicalModel: String
    public let providerRef: ProviderRef
    public let updatedAt: Date

    public init(
        appType: String,
        logicalModel: String,
        providerRef: ProviderRef,
        updatedAt: Date
    ) {
        self.appType = appType
        self.logicalModel = logicalModel
        self.providerRef = providerRef
        self.updatedAt = updatedAt
    }

    public var routeKey: ModelRouteKey {
        ModelRouteKey(appType: appType, logicalModel: logicalModel)
    }

    enum CodingKeys: String, CodingKey {
        case appType
        case logicalModel
        case providerRef
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.logicalModel = try container.decode(String.self, forKey: .logicalModel)
        self.providerRef = try container.decode(ProviderRef.self, forKey: .providerRef)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.appType = try container.decodeIfPresent(String.self, forKey: .appType) ?? providerRef.appType
    }
}

public struct RouteState: Codable, Sendable {
    public var routes: [String: ActiveRoute]

    public init(routes: [String: ActiveRoute] = [:]) {
        self.routes = routes
    }
}

public enum SendableValue: Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: SendableValue])
    case array([SendableValue])
    case null
}
