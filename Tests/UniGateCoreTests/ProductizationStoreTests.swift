import UniGateCore
import Foundation
import Testing

struct ProductizationStoreTests {
    @Test
    func requestMetricsAggregateLatencyAndFailures() {
        var state = RequestMetricsState()
        let key = RequestMetricKey(
            appType: "codex",
            routeKey: "codex:gpt-5.5",
            providerRef: "cc-switch:codex:p1",
            providerName: "Provider 1"
        )

        state.record(key: key, statusCode: 200, latencyMilliseconds: 100)
        state.record(key: key, statusCode: 500, latencyMilliseconds: 300, errorMessage: "HTTP 500", providerFailure: true)

        let record = state.records[key]
        #expect(record?.totalCount == 2)
        #expect(record?.successCount == 1)
        #expect(record?.failureCount == 1)
        #expect(record?.providerFailureCount == 1)
        #expect(record?.averageLatencyMilliseconds == 200)
    }

    @Test
    func persistsProviderModelDiscoveryState() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("model-discovery.json")
        let store = ProviderModelDiscoveryStore(fileURL: tmp)
        let ref = ProviderRef(appType: "claude-desktop", id: "desktop")
        let state = ProviderModelDiscoveryState(results: [
            ref.description: ProviderModelDiscoveryResult(
                providerRef: ref,
                appType: "claude-desktop",
                providerName: "Desktop",
                modelIDs: ["auto", "deepseek-v4-pro"],
                errorMessage: nil,
                sourceURL: "https://api.example.com/v1/models",
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ])

        try store.save(state)
        let loaded = try store.load()

        #expect(loaded == state)
        #expect(loaded.results(appType: "claude-desktop").map(\.providerName) == ["Desktop"])
    }

    @Test
    func prunesProviderModelDiscoveryStateForRemovedProviders() {
        let activeRef = ProviderRef(appType: "claude", id: "active")
        let removedRef = ProviderRef(appType: "claude", id: "removed")
        let state = ProviderModelDiscoveryState(results: [
            activeRef.description: ProviderModelDiscoveryResult(
                providerRef: activeRef,
                appType: "claude",
                providerName: "Active",
                modelIDs: ["claude-sonnet"],
                errorMessage: nil,
                sourceURL: nil,
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            removedRef.description: ProviderModelDiscoveryResult(
                providerRef: removedRef,
                appType: "claude",
                providerName: "Removed",
                modelIDs: [],
                errorMessage: "HTTP 401",
                sourceURL: nil,
                updatedAt: Date(timeIntervalSince1970: 2)
            )
        ])

        let pruned = state.pruning(validProviderRefs: [activeRef])

        #expect(pruned.results.keys.sorted() == [activeRef.description])
        #expect(pruned.results[activeRef.description]?.providerName == "Active")
    }

    @Test
    func configurationBackupRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("backup.json")
        let store = ConfigurationBackupStore()
        let backup = UniGateConfigurationBackup(
            exportedAt: Date(timeIntervalSince1970: 1),
            preferences: AppPreferences(port: 17988),
            routes: RouteState(routes: [
                "codex:gpt-5.5": ActiveRoute(
                    appType: "codex",
                    logicalModel: "gpt-5.5",
                    providerRef: ProviderRef(appType: "codex", id: "p1"),
                    updatedAt: Date(timeIntervalSince1970: 2)
                )
            ]),
            customModels: CustomModelState(models: [
                CustomModelDefinition(appType: "codex", name: "uni")
            ])
        )

        try store.save(backup, to: tmp)
        let loaded = try store.load(from: tmp)

        #expect(loaded.version == backup.version)
        #expect(loaded.exportedAt == backup.exportedAt)
        #expect(loaded.preferences.port == backup.preferences.port)
        #expect(loaded.routes.routes.keys == backup.routes.routes.keys)
        #expect(loaded.customModels.models == backup.customModels.models)
    }

    @Test
    func diagnosticsRedactsSecrets() {
        let text = DiagnosticsReportGenerator.redact("authorization: Bearer sk-secret123456 api_key=abc123456789")

        #expect(text.contains("<redacted>"))
        #expect(!text.contains("sk-secret123456"))
        #expect(!text.contains("abc123456789"))
    }
}
