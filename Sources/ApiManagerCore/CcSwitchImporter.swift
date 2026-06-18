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
                where app_type in ('claude', 'claude-desktop', 'codex', 'gemini')
                order by app_type, coalesce(sort_index, 999999), name, id
                """
            )
        }

        let imported = providers.map(importProvider)
        return ProviderCatalog(
            providers: imported,
            candidates: imported.flatMap(extractCandidates)
        )
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
            hasSecret: hasSecret(appType: row.appType, settings: settings),
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
        guard let model = parsed.model else {
            return []
        }
        return [
            ModelCandidate(
                logicalModel: model,
                providerRef: provider.ref,
                providerName: provider.name,
                appType: provider.appType,
                clientProtocol: .codexResponses,
                apiFormat: provider.apiFormat,
                upstreamModel: model,
                baseURL: provider.baseURL,
                requiresTransform: provider.apiFormat == .openaiChat,
                label: provider.name,
                supportsLongContext: hasLongContextSuffix(model)
            )
        ]
    }

    private func extractClaudeCandidates(
        _ provider: ImportedProvider,
        protocolKind: ClientProtocolKind
    ) -> [ModelCandidate] {
        let fields = [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        ]
        var seen = Set<String>()
        var models: [String] = []
        for field in fields {
            guard
                let model = JSONValueParser.string(provider.settings, ["env", field]),
                !seen.contains(model)
            else {
                continue
            }
            seen.insert(model)
            models.append(model)
        }
        return models.map { model in
            ModelCandidate(
                logicalModel: model,
                providerRef: provider.ref,
                providerName: provider.name,
                appType: provider.appType,
                clientProtocol: protocolKind,
                apiFormat: provider.apiFormat,
                upstreamModel: model,
                baseURL: provider.baseURL,
                requiresTransform: provider.apiFormat != .anthropic,
                label: provider.name,
                supportsLongContext: hasLongContextSuffix(model)
            )
        }
    }

    private func extractClaudeDesktopCandidates(_ provider: ImportedProvider) -> [ModelCandidate] {
        guard let routes = JSONValueParser.object(provider.meta, ["claudeDesktopModelRoutes"]) else {
            return extractClaudeCandidates(provider, protocolKind: .anthropicMessages)
        }

        return routes.keys.sorted().compactMap { logicalModel in
            guard case let .object(route)? = routes[logicalModel] else {
                return nil
            }
            let upstreamModel = string(route["model"]) ?? logicalModel
            return ModelCandidate(
                logicalModel: logicalModel,
                providerRef: provider.ref,
                providerName: provider.name,
                appType: provider.appType,
                clientProtocol: .anthropicMessages,
                apiFormat: provider.apiFormat,
                upstreamModel: upstreamModel,
                baseURL: provider.baseURL,
                requiresTransform: provider.apiFormat != .anthropic,
                label: string(route["labelOverride"]) ?? provider.name,
                supportsLongContext: bool(route["supports1m"]) ?? false
            )
        }
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

    private func hasSecret(appType: String, settings: [String: SendableValue]) -> Bool {
        let paths: [[String]]
        switch appType {
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

        return paths.contains { JSONValueParser.string(settings, $0) != nil }
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

    private func hasLongContextSuffix(_ model: String) -> Bool {
        model.range(of: #"\[\s*1m\s*\]"#, options: [.regularExpression, .caseInsensitive]) != nil
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
