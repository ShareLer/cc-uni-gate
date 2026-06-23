import UniGateCore
import Foundation
import GRDB
import Testing

struct CcSwitchImporterTests {
    @Test
    func codexWireAPIOverridesStaleMetaApiFormat() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("cc-switch.db")
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                create table providers (
                    id text not null,
                    app_type text not null,
                    name text not null,
                    settings_config text not null,
                    category text,
                    sort_index integer,
                    meta text,
                    is_current integer not null default 0
                )
                """)
            try db.execute(
                sql: """
                    insert into providers (
                        id, app_type, name, settings_config, category, sort_index, meta, is_current
                    ) values (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "p1",
                    "codex",
                    "Provider 1",
                    """
                    {
                      "auth": {"OPENAI_API_KEY": "key-1"},
                      "config": "model_provider = \\"custom\\"\\nmodel = \\"gpt-5.5\\"\\n[model_providers.custom]\\nbase_url = \\"https://api.example.com\\"\\nwire_api = \\"responses\\""
                    }
                    """,
                    nil,
                    1,
                    #"{"apiFormat":"openai_chat"}"#,
                    0
                ]
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()
        let candidate = try #require(catalog.candidates.first)

        #expect(candidate.apiFormat == .openaiResponses)
        #expect(!candidate.requiresTransform)
    }

    @Test
    func filtersUniGateProviderAndReadsCodexModelCatalog() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "unigate",
                appType: "codex",
                name: "UniGate",
                settings: """
                {
                  "config": "model_provider = \\"custom\\"\\nmodel = \\"gpt-5.5\\"\\n[model_providers.custom]\\nbase_url = \\"http://127.0.0.1:17888/codex\\"\\nwire_api = \\"responses\\""
                }
                """,
                meta: #"{"apiFormat":"openai_responses"}"#
            )
            try insertProvider(
                db,
                id: "unigate-claude",
                appType: "claude",
                name: "UniGate",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:17888/claude-code",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "Deepseek-v4-flash[1M]"
                  }
                }
                """,
                meta: #"{"apiFormat":"anthropic"}"#
            )
            try insertProvider(
                db,
                id: "unigate-desktop",
                appType: "claude-desktop",
                name: "UniGate",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:17888/claude-desktop",
                    "ANTHROPIC_AUTH_TOKEN": "key-1"
                  }
                }
                """,
                meta: """
                {
                  "apiFormat": "anthropic",
                  "claudeDesktopMode": "proxy",
                  "claudeDesktopModelRoutes": {
                    "claude-sonnet-4-6": {"model": "deepseek-v4-pro", "labelOverride": "deepseek-v4-pro", "supports1m": true},
                    "claude-opus-4-8": {"model": "auto", "labelOverride": "auto", "supports1m": true},
                    "claude-fable-5": {"model": "union-model", "labelOverride": "union-model", "supports1m": true},
                    "claude-haiku-4-5": {"model": "deepseek-v4-flash", "labelOverride": "deepseek-v4-flash", "supports1m": true}
                  }
                }
                """
            )
            try insertProvider(
                db,
                id: "deepseek",
                appType: "codex",
                name: "DeepSeek",
                settings: """
                {
                  "config": "model_provider = \\"custom\\"\\nmodel = \\"deepseek-v4-flash\\"\\n[model_providers.custom]\\nbase_url = \\"https://api.deepseek.example\\"\\nwire_api = \\"responses\\"",
                  "modelCatalog": {
                    "models": [
                      {"model": "deepseek-v4-flash", "displayName": "GPT-5.4", "contextWindow": 1000000},
                      {"model": "deepseek-v4-pro", "displayName": "GPT-5.5", "contextWindow": 1000000}
                    ]
                  }
                }
                """,
                meta: #"{"apiFormat":"openai_responses"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()

        #expect(catalog.providers.map(\.name) == ["DeepSeek"])
        #expect(catalog.routeKeys.map(\.description) == [
            "codex:deepseek-v4-flash",
            "codex:deepseek-v4-pro"
        ])
        #expect(catalog.candidates.first(where: { $0.logicalModel == "deepseek-v4-pro" })?.label == "GPT-5.5")
        #expect(catalog.candidates.allSatisfy { $0.supportsLongContext })

        let scope = try CcSwitchImporter(dbPath: dbURL.path).loadUniGateModelScope()
        #expect(scope.hasModels(for: "codex"))
        #expect(scope.hasModels(for: "claude"))
        #expect(scope.hasModels(for: "claude-desktop"))
        #expect(!scope.hasModels(for: "gemini"))
        #expect(scope.contains(ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")))
        #expect(scope.contains(ModelRouteKey(appType: "claude", logicalModel: "deepseek-v4-flash")))
        #expect(scope.contains(ModelRouteKey(appType: "claude-desktop", logicalModel: "union-model")))
        #expect(scope.contains(desktopCandidate(upstreamModel: "deepseek-v4-pro[1M]")))
        #expect(!scope.contains(desktopCandidate(upstreamModel: "gpt-5.5")))
        #expect(!scope.contains(ModelRouteKey(appType: "codex", logicalModel: "deepseek-v4-pro")))
    }

    @Test
    func loadsIntegrationSnapshotWithUniGateProvidersAndDesktopRoutes() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "unigate-codex",
                appType: "codex",
                name: "UniGate",
                settings: """
                {
                  "config": "model_provider = \\"custom\\"\\nmodel = \\"gpt-5.5\\"\\n[model_providers.custom]\\nbase_url = \\"http://127.0.0.1:17888/codex\\"\\nwire_api = \\"responses\\""
                }
                """,
                meta: #"{"apiFormat":"openai_responses"}"#,
                isCurrent: true
            )
            try insertProvider(
                db,
                id: "desktop",
                appType: "claude-desktop",
                name: "Desktop",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_BASE_URL": "https://api.desktop.example",
                    "ANTHROPIC_AUTH_TOKEN": "key-1"
                  }
                }
                """,
                meta: """
                {
                  "claudeDesktopModelRoutes": {
                    "claude-sonnet-4-6": {"model": "deepseek-v4-flash"}
                  }
                }
                """
            )
        }

        let snapshot = try CcSwitchImporter(dbPath: dbURL.path).loadIntegrationSnapshot()
        let uniGate = try #require(snapshot.uniGateProvider(appType: "codex"))
        let desktop = try #require(snapshot.providers(appType: "claude-desktop").first)

        #expect(uniGate.isCurrent)
        #expect(uniGate.configuredModels == ["gpt-5.5"])
        #expect(desktop.hasClaudeDesktopRoutes)
        #expect(!desktop.isUniGateProvider)
    }

    @Test
    func excludesGeminiProvidersUntilGeminiProxyIsSupported() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "gemini",
                appType: "gemini",
                name: "Gemini Provider",
                settings: """
                {
                  "env": {
                    "GOOGLE_GEMINI_BASE_URL": "https://generativelanguage.googleapis.com",
                    "GEMINI_API_KEY": "key-1"
                  }
                }
                """,
                meta: #"{"apiFormat":"gemini_native"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()

        #expect(catalog.providers.isEmpty)
        #expect(catalog.candidates.isEmpty)
    }

    @Test
    func configurationFingerprintIgnoresNonProviderTables() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "p1",
                appType: "codex",
                name: "Provider 1",
                settings: """
                {
                  "config": "model_provider = \\"custom\\"\\nmodel = \\"gpt-5.5\\"\\n[model_providers.custom]\\nbase_url = \\"https://api.example.com\\"\\nwire_api = \\"responses\\""
                }
                """,
                meta: #"{"apiFormat":"openai_responses"}"#
            )
            try db.execute(sql: """
                create table proxy_request_logs (
                    request_id text primary key,
                    app_type text,
                    model text
                )
                """)
        }
        let importer = CcSwitchImporter(dbPath: dbURL.path)
        let before = try importer.loadConfigurationFingerprint()

        try dbQueue.write { db in
            try db.execute(
                sql: "insert into proxy_request_logs (request_id, app_type, model) values (?, ?, ?)",
                arguments: ["r1", "codex", "gpt-5.5"]
            )
        }
        let afterUsageWrite = try importer.loadConfigurationFingerprint()

        try dbQueue.write { db in
            try db.execute(
                sql: "update providers set name = ? where id = ?",
                arguments: ["Provider 1 Renamed", "p1"]
            )
        }
        let afterProviderWrite = try importer.loadConfigurationFingerprint()

        #expect(afterUsageWrite == before)
        #expect(afterProviderWrite != before)
    }

    @Test
    func importsClaudeFableModelField() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "claude",
                appType: "claude",
                name: "Claude Provider",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_MODEL": "default-model",
                    "ANTHROPIC_DEFAULT_FABLE_MODEL": "fable-model"
                  }
                }
                """,
                meta: #"{"apiFormat":"anthropic"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()

        #expect(catalog.routeKeys.map(\.description) == [
            "claude:default-model",
            "claude:fable-model"
        ])
    }

    @Test
    func importsClaudeDesktopRoutesWithDisplayAndUpstreamModels() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "desktop",
                appType: "claude-desktop",
                name: "DeepSeek Desktop",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_BASE_URL": "https://api.deepseek.example",
                    "ANTHROPIC_AUTH_TOKEN": "key-1"
                  }
                }
                """,
                meta: """
                {
                  "apiFormat": "anthropic",
                  "claudeDesktopMode": "proxy",
                  "claudeDesktopModelRoutes": {
                    "claude-sonnet-4-6": {
                      "model": "deepseek-v4-flash",
                      "labelOverride": "DeepSeek V4 Flash",
                      "supports1m": true
                    },
                    "claude-opus-4-8": {
                      "model": "deepseek-v4-pro",
                      "labelOverride": "DeepSeek V4 Pro",
                      "supports1m": true
                    }
                  }
                }
                """
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()
        let flash = try #require(catalog.candidates.first(where: { $0.logicalModel == "deepseek-v4-flash" }))
        let pro = try #require(catalog.candidates.first(where: { $0.logicalModel == "deepseek-v4-pro" }))

        #expect(catalog.routeKeys.map(\.description) == [
            "claude-desktop:deepseek-v4-flash",
            "claude-desktop:deepseek-v4-pro"
        ])
        #expect(flash.upstreamModel == "deepseek-v4-flash")
        #expect(flash.displayModelName == "deepseek-v4-flash")
        #expect(flash.label == "DeepSeek V4 Flash")
        #expect(flash.supportsLongContext)
        #expect(pro.upstreamModel == "deepseek-v4-pro")
        #expect(pro.displayModelName == "deepseek-v4-pro")
        #expect(pro.label == "DeepSeek V4 Pro")
    }

    @Test
    func ignoresClaudeDesktopEnvModelsWithoutRoutes() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "desktop",
                appType: "claude-desktop",
                name: "DeepSeek Desktop",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_BASE_URL": "https://api.deepseek.example",
                    "ANTHROPIC_AUTH_TOKEN": "key-1",
                    "ANTHROPIC_MODEL": "deepseek-v4-flash",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro"
                  }
                }
                """,
                meta: #"{"apiFormat":"anthropic","claudeDesktopMode":"proxy"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()

        #expect(catalog.providers.map(\.name) == ["DeepSeek Desktop"])
        #expect(catalog.candidates.isEmpty)
        #expect(catalog.routeKeys.isEmpty)
    }

    @Test
    func importsClaudeRoleModelAsLogicalModelAndModelNameAsLabel() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "claude",
                appType: "claude",
                name: "Claude Provider",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1M]",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "DeepSeek V4 Pro"
                  }
                }
                """,
                meta: #"{"apiFormat":"anthropic"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()
        let candidate = try #require(catalog.candidates.first)

        #expect(catalog.routeKeys.map(\.description) == ["claude:deepseek-v4-pro"])
        #expect(candidate.logicalModel == "deepseek-v4-pro")
        #expect(candidate.upstreamModel == "deepseek-v4-pro[1M]")
        #expect(candidate.label == "DeepSeek V4 Pro")
        #expect(candidate.supportsLongContext)
    }

    @Test
    func prefersOneMRoleModelWhenClaudeDefaultModelHasSameLogicalName() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "claude",
                appType: "claude",
                name: "Claude Provider",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_MODEL": "Deepseek-v4-flash",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "Deepseek-v4-flash[1M]",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Deepseek-v4-flash"
                  }
                }
                """,
                meta: #"{"apiFormat":"anthropic"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()
        let candidate = try #require(catalog.candidates.first)

        #expect(catalog.routeKeys.map(\.description) == ["claude:Deepseek-v4-flash"])
        #expect(candidate.upstreamModel == "Deepseek-v4-flash[1M]")
        #expect(candidate.supportsLongContext)
    }

    @Test
    func deduplicatesClaudeLogicalModelsCaseInsensitively() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "claude",
                appType: "claude",
                name: "Claude Provider",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1M]",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "deepseek-v4-pro",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "Deepseek-v4-pro",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "Deepseek-v4-pro"
                  }
                }
                """,
                meta: #"{"apiFormat":"anthropic"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()
        let candidate = try #require(catalog.candidates.first)

        #expect(catalog.routeKeys.map(\.description) == ["claude:deepseek-v4-pro"])
        #expect(candidate.upstreamModel == "deepseek-v4-pro[1M]")
        #expect(candidate.supportsLongContext)
    }

    @Test
    func upgradesCaseVariantClaudeModelToLaterOneMRole() throws {
        let dbURL = try makeProviderDB()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try insertProvider(
                db,
                id: "claude",
                appType: "claude",
                name: "Claude Provider",
                settings: """
                {
                  "env": {
                    "ANTHROPIC_MODEL": "Deepseek-v4-flash",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "Deepseek-v4-pro",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "Deepseek-v4-pro",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1M]",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "deepseek-v4-pro"
                  }
                }
                """,
                meta: #"{"apiFormat":"anthropic"}"#
            )
        }

        let catalog = try CcSwitchImporter(dbPath: dbURL.path).loadCatalog()

        #expect(catalog.routeKeys.map(\.description) == [
            "claude:Deepseek-v4-flash",
            "claude:deepseek-v4-pro"
        ])
        let candidate = try #require(catalog.candidates.first(where: { $0.logicalModel == "deepseek-v4-pro" }))
        #expect(candidate.upstreamModel == "deepseek-v4-pro[1M]")
        #expect(candidate.supportsLongContext)
    }

    private func makeProviderDB() throws -> URL {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("cc-switch.db")
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                create table providers (
                    id text not null,
                    app_type text not null,
                    name text not null,
                    settings_config text not null,
                    category text,
                    sort_index integer,
                    meta text,
                    is_current integer not null default 0
                )
                """)
        }
        return dbURL
    }

    private func insertProvider(
        _ db: Database,
        id: String,
        appType: String,
        name: String,
        settings: String,
        meta: String,
        sortIndex: Int = 1,
        isCurrent: Bool = false
    ) throws {
        try db.execute(
            sql: """
                insert into providers (
                    id, app_type, name, settings_config, category, sort_index, meta, is_current
                ) values (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, appType, name, settings, nil, sortIndex, meta, isCurrent ? 1 : 0]
        )
    }

    private func desktopCandidate(upstreamModel: String) -> ModelCandidate {
        ModelCandidate(
            logicalModel: ModelNameNormalizer.stripOneMSuffix(upstreamModel),
            providerRef: ProviderRef(appType: "claude-desktop", id: "desktop"),
            providerName: "Desktop",
            appType: "claude-desktop",
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: upstreamModel,
            baseURL: "https://desktop.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
    }
}
