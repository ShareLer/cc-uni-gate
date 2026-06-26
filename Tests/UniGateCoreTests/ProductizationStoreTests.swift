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
    func prunesProviderModelDiscoveryStateWhenProviderConfigurationChanges() {
        let original = discoveryProvider(
            id: "provider",
            baseURL: "https://api.one.example",
            apiKey: "key-one"
        )
        let changedBaseURL = discoveryProvider(
            id: "provider",
            baseURL: "https://api.two.example",
            apiKey: "key-one"
        )
        let state = ProviderModelDiscoveryState(results: [
            original.ref.description: ProviderModelDiscoveryResult(
                providerRef: original.ref,
                appType: original.appType,
                providerName: original.name,
                modelIDs: ["gpt-5.5"],
                errorMessage: nil,
                sourceURL: "https://api.one.example/v1/models",
                updatedAt: Date(timeIntervalSince1970: 1),
                configurationFingerprint: ProviderModelDiscoveryFingerprint.value(for: original)
            )
        ])

        #expect(state.pruning(validProviders: [original]).results.keys.sorted() == [original.ref.description])
        #expect(state.pruning(validProviders: [changedBaseURL]).results.isEmpty)
    }

    @Test
    func providerModelDiscoveryFingerprintTracksSecretAndModelsURLChanges() {
        let original = discoveryProvider(
            id: "provider",
            baseURL: "https://api.example.com",
            apiKey: "key-one",
            meta: ["modelsUrl": .string("https://api.example.com/v1/models")]
        )
        let changedSecret = discoveryProvider(
            id: "provider",
            baseURL: "https://api.example.com",
            apiKey: "key-two",
            meta: ["modelsUrl": .string("https://api.example.com/v1/models")]
        )
        let changedModelsURL = discoveryProvider(
            id: "provider",
            baseURL: "https://api.example.com",
            apiKey: "key-one",
            meta: ["modelsUrl": .string("https://api.example.com/models")]
        )

        let fingerprint = ProviderModelDiscoveryFingerprint.value(for: original)

        #expect(fingerprint != ProviderModelDiscoveryFingerprint.value(for: changedSecret))
        #expect(fingerprint != ProviderModelDiscoveryFingerprint.value(for: changedModelsURL))
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

    @Test
    func logFieldFormatterQuotesValuesForStableParsing() {
        let text = LogFieldFormatter.format([
            LogField("event", "proxy"),
            LogField("requestId", "abc123"),
            LogField("error", "The request \"timed out\"."),
            LogField("empty", nil as String?)
        ])

        #expect(text == #"event=proxy requestId=abc123 error="The request \"timed out\"." empty=-"#)
    }

    @Test
    func diagnosticsReportIncludesBidirectionalNetworkPolicyDiagnostic() {
        let providerRef = ProviderRef(appType: "claude", id: "provider")
        let text = DiagnosticsReportGenerator.text(DiagnosticsReportInput(
            databasePath: "/tmp/cc-switch.db",
            proxyStatus: "running",
            proxyPort: 17888,
            catalog: ProviderCatalog(providers: [], candidates: []),
            routes: RouteState(),
            preferences: AppPreferences(),
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope(),
            integration: nil,
            healthReport: ConfigurationHealthReport(generatedAt: Date(timeIntervalSince1970: 1), items: []),
            recentEvents: [],
            requestMetrics: RequestMetricsState(),
            discoveryState: ProviderModelDiscoveryState(),
            networkDiagnostics: [
                NetworkPolicyDiagnostic(
                    providerRef: providerRef,
                    appType: "claude",
                    providerName: "Provider",
                    url: "https://api.example.com/v1/models",
                    failedMode: .direct,
                    failedError: "The request timed out.",
                    fallbackMode: .system,
                    fallbackStatusCode: 200,
                    checkedAt: Date(timeIntervalSince1970: 1)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 2)
        ))

        #expect(text.contains("direct failed"))
        #expect(text.contains("system HTTP 200"))
        #expect(text.contains("The request timed out."))
    }

    private func discoveryProvider(
        id: String,
        baseURL: String,
        apiKey: String,
        meta: [String: SendableValue] = [:]
    ) -> ImportedProvider {
        ImportedProvider(
            id: id,
            appType: "codex",
            name: "Provider",
            category: nil,
            sortIndex: nil,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: baseURL,
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string(apiKey)])],
            meta: meta
        )
    }
}
