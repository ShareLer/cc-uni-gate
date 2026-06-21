import Foundation
import GRDB

public struct CcSwitchImporter: Sendable {
    public let dbPath: String

    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    public func loadCatalog() throws -> ProviderCatalog {
        var configuration = Configuration()
        configuration.readonly = true
        let dbQueue = try DatabaseQueue(path: dbPath, configuration: configuration)

        let providers = try dbQueue.read { db in
            try ProviderRow.fetchAll(
                db,
                sql: """
                select id, app_type, name, settings_config, category, sort_index, meta, is_current
                from providers
                where app_type in ('claude', 'claude-desktop', 'codex')
                order by app_type, coalesce(sort_index, 999999), name, id
                """
            )
        }

        let imported = providers.map(importProvider).filter { !isUniGateProvider($0) }
        return ProviderCatalog(
            providers: imported,
            candidates: imported.flatMap(extractCandidates)
        )
    }

    public func loadUniGateModelScope() throws -> UniGateModelScope {
        var configuration = Configuration()
        configuration.readonly = true
        let dbQueue = try DatabaseQueue(path: dbPath, configuration: configuration)

        let providers = try dbQueue.read { db in
            try ProviderRow.fetchAll(
                db,
                sql: """
                select id, app_type, name, settings_config, category, sort_index, meta, is_current
                from providers
                where app_type in ('claude', 'claude-desktop', 'codex')
                order by app_type, coalesce(sort_index, 999999), name, id
                """
            )
        }

        let modelsByApp = providers
            .map(importProvider)
            .filter(isUniGateProvider)
            .reduce(into: [String: Set<String>]()) { result, provider in
                let models = uniGateConfiguredModels(provider)
                guard !models.isEmpty else {
                    return
                }
                result[provider.appType, default: []].formUnion(models)
            }
        return UniGateModelScope(modelsByApp: modelsByApp)
    }

    private func importProvider(_ row: ProviderRow) -> ImportedProvider {
        let settings = JSONValueParser.parseObject(row.settingsConfig)
        let meta = JSONValueParser.parseObject(row.meta)
        return ImportedProvider(
            id: row.id,
            appType: row.appType,
            name: row.name,
            category: row.category,
            sortIndex: row.sortIndex,
            isCurrent: row.isCurrent,
            apiFormat: inferApiFormat(appType: row.appType, settings: settings, meta: meta),
            baseURL: extractBaseURL(appType: row.appType, settings: settings),
            hasSecret: ProviderCredentials.hasSecret(appType: row.appType, settings: settings),
            settings: settings,
            meta: meta
        )
    }

    private func extractCandidates(_ provider: ImportedProvider) -> [ModelCandidate] {
        switch provider.appType {
        case "codex":
            return extractCodexCandidates(provider)
        case "claude":
            return extractClaudeCandidates(provider, protocolKind: .anthropicMessages)
        case "claude-desktop":
            return extractClaudeDesktopCandidates(provider)
        default:
            return []
        }
    }

    private func extractCodexCandidates(_ provider: ImportedProvider) -> [ModelCandidate] {
        let parsed = CodexConfigParser.parse(JSONValueParser.string(provider.settings, ["config"]))
        var candidates = extractCodexCatalogCandidates(provider)
        if !candidates.isEmpty {
            return candidates
        }

        guard let model = parsed.model else {
            return []
        }
        candidates.append(codexCandidate(provider: provider, logicalModel: model, upstreamModel: model, label: provider.name))
        return candidates
    }

    private func uniGateConfiguredModels(_ provider: ImportedProvider) -> Set<String> {
        switch provider.appType {
        case "codex":
            let catalogModels = extractCodexCatalogModels(provider)
            if !catalogModels.isEmpty {
                return catalogModels
            }
            let parsed = CodexConfigParser.parse(JSONValueParser.string(provider.settings, ["config"]))
            return parsed.model.map { [$0] } ?? []
        case "claude":
            return extractClaudeConfiguredModels(provider)
        case "claude-desktop":
            return extractClaudeDesktopConfiguredModels(provider)
        default:
            return []
        }
    }

    private func extractCodexCatalogModels(_ provider: ImportedProvider) -> Set<String> {
        guard case let .array(models)? = JSONValueParser.value(provider.settings, ["modelCatalog", "models"]) else {
            return []
        }
        return Set(models.compactMap { entry in
            guard case let .object(modelObject) = entry else {
                return nil
            }
            return string(modelObject["model"])
        })
    }

    private func extractClaudeConfiguredModels(_ provider: ImportedProvider) -> Set<String> {
        let fields = [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        ]
        return Set(fields.compactMap { field in
            JSONValueParser.string(provider.settings, ["env", field])
        })
    }

    private func extractClaudeDesktopConfiguredModels(_ provider: ImportedProvider) -> Set<String> {
        guard let routes = JSONValueParser.object(provider.meta, ["claudeDesktopModelRoutes"]) else {
            return []
        }
        return Set(routes.compactMap { logicalModel, value in
            guard case let .object(route) = value else {
                return nil
            }
            return string(route["model"]) ?? logicalModel
        })
    }

    private func extractCodexCatalogCandidates(_ provider: ImportedProvider) -> [ModelCandidate] {
        guard case let .array(models)? = JSONValueParser.value(provider.settings, ["modelCatalog", "models"]) else {
            return []
        }

        var seen = Set<String>()
        return models.compactMap { entry in
            guard case let .object(modelObject) = entry else {
                return nil
            }
            guard let upstreamModel = string(modelObject["model"]) else {
                return nil
            }
            let displayName = string(modelObject["displayName"]) ?? string(modelObject["display_name"])
            guard !seen.contains(upstreamModel) else {
                return nil
            }
            seen.insert(upstreamModel)
            return codexCandidate(
                provider: provider,
                logicalModel: upstreamModel,
                upstreamModel: upstreamModel,
                label: displayName ?? provider.name,
                supportsLongContext: longContextValue(modelObject["contextWindow"] ?? modelObject["context_window"])
                    ?? ModelNameNormalizer.hasOneMMarker(upstreamModel)
            )
        }
    }

    private func extractClaudeCandidates(
        _ provider: ImportedProvider,
        protocolKind: ClientProtocolKind
    ) -> [ModelCandidate] {
        let fields: [(model: String, name: String?)] = [
            ("ANTHROPIC_MODEL", nil),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME")
        ]
        var seen = Set<String>()
        var models: [(logical: String, upstream: String, label: String?)] = []
        for field in fields {
            guard
                let upstreamModel = JSONValueParser.string(provider.settings, ["env", field.model])
            else {
                continue
            }
            let logicalModel = ModelNameNormalizer.stripOneMSuffix(upstreamModel)
            let label = field.name.flatMap { JSONValueParser.string(provider.settings, ["env", $0]) }
            let dedupeKey = logicalModel.lowercased()
            guard !seen.contains(dedupeKey) else {
                if ModelNameNormalizer.hasOneMMarker(upstreamModel),
                   let index = models.firstIndex(where: { $0.logical.caseInsensitiveCompare(logicalModel) == .orderedSame }),
                   !ModelNameNormalizer.hasOneMMarker(models[index].upstream) {
                    models[index] = (logicalModel, upstreamModel, label)
                }
                continue
            }
            seen.insert(dedupeKey)
            models.append((logicalModel, upstreamModel, label))
        }
        return models.map { model in
            ModelCandidate(
                logicalModel: model.logical,
                providerRef: provider.ref,
                providerName: provider.name,
                appType: provider.appType,
                clientProtocol: protocolKind,
                apiFormat: provider.apiFormat,
                upstreamModel: model.upstream,
                baseURL: provider.baseURL,
                requiresTransform: provider.apiFormat != .anthropic,
                label: model.label ?? provider.name,
                supportsLongContext: ModelNameNormalizer.hasOneMMarker(model.upstream)
            )
        }
    }

    private func extractClaudeDesktopCandidates(_ provider: ImportedProvider) -> [ModelCandidate] {
        guard let routes = JSONValueParser.object(provider.meta, ["claudeDesktopModelRoutes"]) else {
            return []
        }

        struct DesktopRouteCandidate {
            var logicalModel: String
            var upstreamModel: String
            var label: String?
            var supportsLongContext: Bool
        }

        var order: [String] = []
        var candidatesByModel: [String: DesktopRouteCandidate] = [:]

        for routeID in routes.keys.sorted() {
            guard case let .object(route)? = routes[routeID] else {
                continue
            }
            guard let upstreamModel = string(route["model"]) else {
                continue
            }
            let logicalModel = ModelNameNormalizer.stripOneMSuffix(upstreamModel)
            let key = ModelNameNormalizer.normalized(logicalModel)
            let label = string(route["labelOverride"]) ?? provider.name
            let supportsLongContext = (bool(route["supports1m"]) ?? false)
                || ModelNameNormalizer.hasOneMMarker(upstreamModel)

            if var existing = candidatesByModel[key] {
                if supportsLongContext && !existing.supportsLongContext {
                    existing.upstreamModel = upstreamModel
                    existing.label = label
                }
                existing.supportsLongContext = existing.supportsLongContext || supportsLongContext
                candidatesByModel[key] = existing
            } else {
                order.append(key)
                candidatesByModel[key] = DesktopRouteCandidate(
                    logicalModel: logicalModel,
                    upstreamModel: upstreamModel,
                    label: label,
                    supportsLongContext: supportsLongContext
                )
            }
        }

        return order.compactMap { key in
            guard let candidate = candidatesByModel[key] else {
                return nil
            }
            return ModelCandidate(
                logicalModel: candidate.logicalModel,
                providerRef: provider.ref,
                providerName: provider.name,
                appType: provider.appType,
                clientProtocol: .anthropicMessages,
                apiFormat: provider.apiFormat,
                upstreamModel: candidate.upstreamModel,
                baseURL: provider.baseURL,
                requiresTransform: provider.apiFormat != .anthropic,
                label: candidate.label,
                supportsLongContext: candidate.supportsLongContext
            )
        }
    }

    private func codexCandidate(
        provider: ImportedProvider,
        logicalModel: String,
        upstreamModel: String,
        label: String?,
        supportsLongContext: Bool? = nil
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: logicalModel,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: provider.apiFormat,
            upstreamModel: upstreamModel,
            baseURL: provider.baseURL,
            requiresTransform: provider.apiFormat != .openaiResponses && provider.apiFormat != .openaiChat,
            label: label,
            supportsLongContext: supportsLongContext ?? ModelNameNormalizer.hasOneMMarker(upstreamModel)
        )
    }

    private func inferApiFormat(
        appType: String,
        settings: [String: SendableValue],
        meta: [String: SendableValue]
    ) -> ApiFormat {
        if appType == "codex" {
            let parsed = CodexConfigParser.parse(JSONValueParser.string(settings, ["config"]))
            let wireFormat = normalizeApiFormat(parsed.wireAPI)
            if wireFormat != .unknown {
                return wireFormat
            }
        }

        let metaFormat = normalizeApiFormat(string(meta["apiFormat"]))
        if metaFormat != .unknown {
            return metaFormat
        }

        let settingsFormat = normalizeApiFormat(
            JSONValueParser.string(settings, ["api_format"]) ?? JSONValueParser.string(settings, ["apiFormat"])
        )
        if settingsFormat != .unknown {
            return settingsFormat
        }

        if appType == "claude" || appType == "claude-desktop" {
            return .anthropic
        }

        return .unknown
    }

    private func normalizeApiFormat(_ value: String?) -> ApiFormat {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic":
            return .anthropic
        case "responses", "openai_responses":
            return .openaiResponses
        case "chat", "chat_completions", "chat-completions", "openai_chat", "openai-chat", "openai_chat_completions":
            return .openaiChat
        case "gemini_native":
            return .geminiNative
        default:
            return .unknown
        }
    }

    private func extractBaseURL(appType: String, settings: [String: SendableValue]) -> String? {
        if appType == "codex" {
            return JSONValueParser.string(settings, ["base_url"])
                ?? JSONValueParser.string(settings, ["baseURL"])
                ?? CodexConfigParser.parse(JSONValueParser.string(settings, ["config"])).baseURL
        }

        if appType == "claude" || appType == "claude-desktop" {
            return JSONValueParser.string(settings, ["env", "ANTHROPIC_BASE_URL"])
                ?? JSONValueParser.string(settings, ["base_url"])
                ?? JSONValueParser.string(settings, ["baseURL"])
                ?? JSONValueParser.string(settings, ["apiEndpoint"])
        }

        if appType == "gemini" {
            return JSONValueParser.string(settings, ["env", "GOOGLE_GEMINI_BASE_URL"])
        }

        return JSONValueParser.string(settings, ["base_url"])
            ?? JSONValueParser.string(settings, ["baseURL"])
    }

    private func string(_ value: SendableValue?) -> String? {
        guard case let .string(text)? = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bool(_ value: SendableValue?) -> Bool? {
        guard case let .bool(flag)? = value else {
            return nil
        }
        return flag
    }

    private func longContextValue(_ value: SendableValue?) -> Bool? {
        guard case let .number(number)? = value else {
            return nil
        }
        return number >= 1_000_000
    }

    private func isUniGateProvider(_ provider: ImportedProvider) -> Bool {
        if provider.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("UniGate") == .orderedSame {
            return true
        }
        guard let baseURL = provider.baseURL?.lowercased() else {
            return false
        }
        return isLoopbackURL(baseURL)
            && (baseURL.contains("/codex") || baseURL.contains("/claude-code") || baseURL.contains("/claude-desktop"))
    }

    private func isLoopbackURL(_ value: String) -> Bool {
        value.contains("://127.") || value.contains("://localhost") || value.contains("://[::1]")
    }
}

private struct ProviderRow: FetchableRecord, Decodable {
    let id: String
    let appType: String
    let name: String
    let settingsConfig: String
    let category: String?
    let sortIndex: Int?
    let meta: String?
    let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case appType = "app_type"
        case name
        case settingsConfig = "settings_config"
        case category
        case sortIndex = "sort_index"
        case meta
        case isCurrent = "is_current"
    }
}
