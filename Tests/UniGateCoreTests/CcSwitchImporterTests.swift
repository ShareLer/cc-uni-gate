import UniGateCore
import Foundation
import GRDB
import Testing

struct CcSwitchImporterTests {
    @Test
    func codexMetaApiFormatDescribesRealUpstreamProtocol() throws {
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

        #expect(candidate.apiFormat == .openaiChat)
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
        sortIndex: Int = 1
    ) throws {
        try db.execute(
            sql: """
                insert into providers (
                    id, app_type, name, settings_config, category, sort_index, meta, is_current
                ) values (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, appType, name, settings, nil, sortIndex, meta, 0]
        )
    }
}
