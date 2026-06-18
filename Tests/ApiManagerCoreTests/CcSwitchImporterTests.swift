import ApiManagerCore
import Foundation
import GRDB
import Testing

struct CcSwitchImporterTests {
    @Test
    func codexWireApiTakesPriorityOverMetaApiFormat() throws {
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
}
