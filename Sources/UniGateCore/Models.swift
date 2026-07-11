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

enum ProxyProtocolCompatibility: Int, Sendable {
    case native
    case limitedBridge
    case unsupported

    static func classify(
        clientProtocol: ClientProtocolKind,
        apiFormat: ApiFormat
    ) -> ProxyProtocolCompatibility {
        switch (clientProtocol, apiFormat) {
        case (.codexResponses, .openaiResponses),
             (.openaiChat, .openaiChat),
             (.anthropicMessages, .anthropic),
             (.geminiNative, .geminiNative):
            return .native
        case (.codexResponses, .openaiChat),
             (.anthropicMessages, .openaiChat):
            return .limitedBridge
        default:
            return .unsupported
        }
    }
}

public enum UniGateAppRegistry {
    public static let codex = "codex"
    public static let claudeCode = "claude"
    public static let claudeDesktop = "claude-desktop"

    public static let uniGateScopedAppTypes: [String] = [
        codex,
        claudeCode,
        claudeDesktop
    ]

    public static func isUniGateScoped(_ appType: String) -> Bool {
        uniGateScopedAppTypes.contains(appType)
    }

    public static func isClaudeLike(_ appType: String) -> Bool {
        appType == claudeCode || appType == claudeDesktop
    }

    public static func clientProtocol(for appType: String) -> ClientProtocolKind? {
        if appType == codex {
            return .codexResponses
        }
        if isClaudeLike(appType) {
            return .anthropicMessages
        }
        return nil
    }

    public static func defaultApiFormat(for appType: String) -> ApiFormat {
        if appType == codex {
            return .openaiResponses
        }
        if isClaudeLike(appType) {
            return .anthropic
        }
        if appType == "gemini" {
            return .geminiNative
        }
        return .openaiResponses
    }

    public static func requiresTransform(appType: String, apiFormat: ApiFormat) -> Bool? {
        guard let clientProtocol = clientProtocol(for: appType) else {
            return nil
        }
        return ProxyProtocolCompatibility.classify(
            clientProtocol: clientProtocol,
            apiFormat: apiFormat
        ) != .native
    }
}

public enum ProxyResponseTransform: String, Codable, Sendable {
    case none
    case openAIChatToCodexResponse = "openai_chat_to_codex_response"
    case openAIChatToAnthropicMessages = "openai_chat_to_anthropic_messages"
}

public enum ModelCandidateSource: String, Codable, Sendable {
    case configured
    case custom
    case discovered
    case staleDiscovered

    public var isRouteKeySeed: Bool {
        switch self {
        case .configured, .custom:
            return true
        case .discovered, .staleDiscovered:
            return false
        }
    }
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
            self = .proxy(protocolKind: .anthropicMessages, appType: scoped.appType ?? UniGateAppRegistry.claudeCode)
        } else if Self.codexResponsesPaths.contains(path) {
            self = .proxy(protocolKind: .codexResponses, appType: scoped.appType ?? UniGateAppRegistry.codex)
        } else if Self.openAIChatPaths.contains(path) {
            self = .proxy(protocolKind: .openaiChat, appType: scoped.appType ?? UniGateAppRegistry.codex)
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
        ("/claude-desktop", UniGateAppRegistry.claudeDesktop),
        ("/claude-code", UniGateAppRegistry.claudeCode),
        ("/claude", UniGateAppRegistry.claudeCode),
        ("/anthropic", UniGateAppRegistry.claudeCode),
        ("/codex", UniGateAppRegistry.codex),
        ("/openai", UniGateAppRegistry.codex)
    ]

    private static let modelPaths: Set<String> = [
        "/models", "/v1/models", "/v1/v1/models"
    ]

    private static let claudePaths: Set<String> = [
        "/v1/messages", "/v1/messages/count_tokens"
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
    public let backendKind: ProviderBackendKind

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
        meta: [String: SendableValue],
        backendKind: ProviderBackendKind = .standard
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
        self.backendKind = backendKind
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
            meta: meta,
            backendKind: backendKind
        )
    }
}

public enum ProviderDisplay {
    public static func appTypeLabel(_ appType: String) -> String {
        switch appType {
        case UniGateAppRegistry.codex:
            return "Codex"
        case UniGateAppRegistry.claudeCode:
            return "Claude Code"
        case UniGateAppRegistry.claudeDesktop:
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
    public let upstreamProviderRef: ProviderRef
    public let source: ModelCandidateSource

    public var id: String {
        "\(routeKey.description)|\(providerRef.description)"
    }

    public var routeKey: ModelRouteKey {
        ModelRouteKey(appType: appType, logicalModel: logicalModel)
    }

    public var upstreamModelDisplayName: String {
        Self.stripOneMSuffix(upstreamModel)
    }

    public var displayModelName: String {
        return logicalModel
    }

    var protocolCompatibility: ProxyProtocolCompatibility {
        ProxyProtocolCompatibility.classify(
            clientProtocol: clientProtocol,
            apiFormat: apiFormat
        )
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
        supportsLongContext: Bool,
        upstreamProviderRef: ProviderRef? = nil,
        source: ModelCandidateSource = .configured
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
        self.upstreamProviderRef = upstreamProviderRef ?? providerRef
        self.source = source
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
            supportsLongContext: supportsLongContext,
            upstreamProviderRef: upstreamProviderRef,
            source: source
        )
    }

    private func requiresTransform(for appType: String, apiFormat: ApiFormat) -> Bool {
        UniGateAppRegistry.requiresTransform(appType: appType, apiFormat: apiFormat) ?? requiresTransform
    }

    public static func stripOneMSuffix(_ model: String) -> String {
        ModelNameNormalizer.stripOneMSuffix(model)
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
            guard
                provider.backendKind != .codexOfficial,
                let override = overrides[provider.ref.description]
            else {
                return provider
            }
            return provider.withApiFormat(override)
        }
        let codexOfficialProviderRefs = Set(
            providers.filter { $0.backendKind == .codexOfficial }.map(\.ref)
        )
        let candidates = candidates.map { candidate in
            guard
                !codexOfficialProviderRefs.contains(candidate.providerRef),
                let override = overrides[candidate.providerRef.description]
            else {
                return candidate
            }
            return candidate.withApiFormat(override)
        }
        return ProviderCatalog(providers: providers, candidates: candidates)
    }

    public func scopedForProxy(
        uniGateModelScope: UniGateModelScope,
        customModels: CustomModelState
    ) -> ProviderCatalog {
        let nonCodexBaseCandidates = candidates.filter { candidate in
            candidate.appType != UniGateAppRegistry.codex
                && candidate.providerRef == candidate.upstreamProviderRef
                && ModelRouteVisibility.isCandidateSelectable(
                    candidate,
                    uniGateModelScope: uniGateModelScope
                )
        }
        let codexCustomRouteKeys = Set(customModels.models.compactMap { definition -> ModelRouteKey? in
            guard definition.appType == UniGateAppRegistry.codex else {
                return nil
            }
            return ModelRouteKey(appType: definition.appType, logicalModel: definition.name)
        })
        var codexRouteKeySet = Set(candidates.compactMap { candidate -> ModelRouteKey? in
            guard candidate.appType == UniGateAppRegistry.codex,
                  candidate.providerRef == candidate.upstreamProviderRef,
                  !codexCustomRouteKeys.contains(candidate.routeKey) else {
                return nil
            }
            return candidate.routeKey
        })
        for model in uniGateModelScope.models(for: UniGateAppRegistry.codex) {
            let routeKey = ModelRouteKey(
                appType: UniGateAppRegistry.codex,
                logicalModel: model
            )
            if !codexCustomRouteKeys.contains(routeKey) {
                codexRouteKeySet.insert(routeKey)
            }
        }
        for policy in customModels.codexRoutePolicies
        where !codexCustomRouteKeys.contains(policy.routeKey) {
            codexRouteKeySet.insert(policy.routeKey)
        }
        let codexRouteKeys = Array(codexRouteKeySet)
        let codexBaseCandidates = CustomModelState.deduplicatedTargetCandidates(
            codexRouteKeys.flatMap { routeKey -> [ModelCandidate] in
                guard !customModels.isCodexRouteDisabled(
                    routeKey,
                    pinnedScope: uniGateModelScope
                ) else {
                    return []
                }
                return customModels.codexRoutingCandidates(for: routeKey, from: self)
            },
            preferLongContext: true
        )
        let codexBaseRouteKeys = Set(codexRouteKeys)
        let nonCodexBaseRouteKeys = Set(nonCodexBaseCandidates.map(\.routeKey))
        let customCandidates = customModels.expandedCandidates(from: self).filter { candidate in
            if candidate.appType == UniGateAppRegistry.codex {
                return !codexBaseRouteKeys.contains(candidate.routeKey)
                    && !customModels.isCodexRouteDisabled(
                    candidate.routeKey,
                    pinnedScope: uniGateModelScope
                )
            }
            guard !nonCodexBaseRouteKeys.contains(candidate.routeKey) else {
                return false
            }
            guard let definition = customModels.definition(for: candidate.routeKey) else {
                return false
            }
            return definition.forceEnabled || uniGateModelScope.contains(candidate.routeKey)
        }
        return ProviderCatalog(
            providers: providers,
            candidates: nonCodexBaseCandidates + codexBaseCandidates + customCandidates
        )
    }
}

public extension ModelCandidate {
    func isDiscoveryStale(in catalog: ProviderCatalog) -> Bool {
        switch source {
        case .staleDiscovered:
            return true
        case .discovered, .configured, .custom:
            break
        }
        guard providerRef != upstreamProviderRef else {
            return false
        }
        let upstreamLogicalModel = label ?? upstreamModelDisplayName
        return catalog.candidates.contains {
            $0.appType == appType
                && $0.logicalModel == upstreamLogicalModel
                && $0.providerRef == upstreamProviderRef
                && $0.source == .staleDiscovered
        }
    }
}

public struct UniGateModelScope: Sendable {
    private let modelsByApp: [String: Set<String>]
    private let normalizedModelsByApp: [String: Set<String>]

    public init(modelsByApp: [String: Set<String>] = [:]) {
        self.modelsByApp = modelsByApp.mapValues { models in
            Set(models.compactMap { model in
                let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            })
        }
        self.normalizedModelsByApp = modelsByApp.mapValues { models in
            Set(models.map(Self.normalizedModel))
        }
    }

    public func contains(_ routeKey: ModelRouteKey) -> Bool {
        guard let models = normalizedModelsByApp[routeKey.appType] else {
            return false
        }
        return models.contains(Self.normalizedModel(routeKey.logicalModel))
    }

    public func contains(_ candidate: ModelCandidate) -> Bool {
        guard let models = normalizedModelsByApp[candidate.appType] else {
            return false
        }
        if candidate.appType == UniGateAppRegistry.claudeDesktop {
            return models.contains(Self.normalizedModel(candidate.upstreamModel))
        }
        return models.contains(Self.normalizedModel(candidate.logicalModel))
    }

    public func hasModels(for appType: String) -> Bool {
        guard let models = normalizedModelsByApp[appType] else {
            return false
        }
        return !models.isEmpty
    }

    public func models(for appType: String) -> [String] {
        guard let models = modelsByApp[appType] else {
            return []
        }
        return models.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func normalizedModel(_ model: String) -> String {
        ModelNameNormalizer.normalized(model)
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
