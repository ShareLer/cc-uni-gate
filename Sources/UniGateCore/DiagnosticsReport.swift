import Foundation

public struct DiagnosticsReportInput: Sendable {
    public var databasePath: String
    public var proxyStatus: String
    public var proxyPort: UInt16
    public var catalog: ProviderCatalog
    public var routes: RouteState
    public var preferences: AppPreferences
    public var customModels: CustomModelState
    public var uniGateModelScope: UniGateModelScope
    public var integration: CcSwitchIntegrationSnapshot?
    public var healthReport: ConfigurationHealthReport
    public var recentEvents: [DiagnosticEvent]
    public var requestMetrics: RequestMetricsState
    public var discoveryState: ProviderModelDiscoveryState
    public var networkDiagnostics: [NetworkPolicyDiagnostic]
    public var generatedAt: Date

    public init(
        databasePath: String,
        proxyStatus: String,
        proxyPort: UInt16,
        catalog: ProviderCatalog,
        routes: RouteState,
        preferences: AppPreferences,
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        integration: CcSwitchIntegrationSnapshot?,
        healthReport: ConfigurationHealthReport,
        recentEvents: [DiagnosticEvent],
        requestMetrics: RequestMetricsState,
        discoveryState: ProviderModelDiscoveryState,
        networkDiagnostics: [NetworkPolicyDiagnostic] = [],
        generatedAt: Date = Date()
    ) {
        self.databasePath = databasePath
        self.proxyStatus = proxyStatus
        self.proxyPort = proxyPort
        self.catalog = catalog
        self.routes = routes
        self.preferences = preferences
        self.customModels = customModels
        self.uniGateModelScope = uniGateModelScope
        self.integration = integration
        self.healthReport = healthReport
        self.recentEvents = recentEvents
        self.requestMetrics = requestMetrics
        self.discoveryState = discoveryState
        self.networkDiagnostics = networkDiagnostics
        self.generatedAt = generatedAt
    }
}

public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public var date: Date
    public var level: String
    public var message: String

    public init(date: Date, level: String, message: String) {
        self.date = date
        self.level = level
        self.message = message
    }
}

public enum DiagnosticsReportGenerator {
    public static func text(_ input: DiagnosticsReportInput) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []

        lines.append("Uni Gate Diagnostics")
        lines.append("Generated: \(formatter.string(from: input.generatedAt))")
        lines.append("")
        lines.append("[Runtime]")
        lines.append("Proxy: \(input.proxyStatus)")
        lines.append("Port: \(input.proxyPort)")
        lines.append("cc-switch DB: \(input.databasePath)")
        lines.append("Providers: \(input.catalog.providers.count)")
        lines.append("Candidates: \(input.catalog.candidates.count)")
        lines.append("Routes: \(input.routes.routes.count)")
        lines.append("Custom models: \(input.customModels.models.count)")
        lines.append("")

        lines.append("[Health]")
        lines.append("Summary: \(input.healthReport.summaryTitle)")
        for item in input.healthReport.blockingItems.prefix(20) {
            let app = item.appType.map { "\(ProviderDisplay.appTypeLabel($0)) · " } ?? ""
            lines.append("- [\(item.severity.rawValue)] \(app)\(item.title): \(redact(item.detail))")
        }
        if input.healthReport.blockingItems.isEmpty {
            lines.append("- ok")
        }
        lines.append("")

        lines.append("[Providers]")
        for provider in input.catalog.providers.prefix(80) {
            lines.append("- \(ProviderDisplay.appTypeLabel(provider.appType)) / \(provider.name) / \(provider.apiFormat.rawValue) / secret=\(provider.hasSecret) / base=\(redact(provider.baseURL ?? "<empty>"))")
        }
        lines.append("")

        lines.append("[Routes]")
        for key in input.routes.routes.keys.sorted().prefix(120) {
            guard let route = input.routes.routes[key] else {
                continue
            }
            lines.append("- \(key) -> \(route.providerRef.description)")
        }
        lines.append("")

        lines.append("[Visible Scope]")
        for appType in UniGateAppRegistry.uniGateScopedAppTypes {
            let models = input.uniGateModelScope.models(for: appType)
            lines.append("- \(ProviderDisplay.appTypeLabel(appType)): \(models.prefix(30).joined(separator: ", "))")
        }
        lines.append("")

        lines.append("[Request Metrics]")
        for metric in input.requestMetrics.records.sorted(by: { $0.key.description < $1.key.description }).prefix(80) {
            lines.append("- \(metric.key.description): total=\(metric.value.totalCount) ok=\(metric.value.successCount) fail=\(metric.value.failureCount) avgMs=\(metric.value.averageLatencyMilliseconds.map { String(format: "%.0f", $0) } ?? "-")")
        }
        if input.requestMetrics.records.isEmpty {
            lines.append("- none")
        }
        lines.append("")

        lines.append("[Model Discovery]")
        for result in input.discoveryState.results.sorted(by: { $0.key < $1.key }).prefix(80) {
            let value = result.value
            let status = value.errorMessage ?? "\(value.modelIDs.count) models"
            lines.append("- \(result.key): \(status) at \(formatter.string(from: value.updatedAt))")
        }
        if input.discoveryState.results.isEmpty {
            lines.append("- none")
        }
        lines.append("")

        lines.append("[Network Policy]")
        lines.append("Global: \(input.preferences.networkPolicy.globalMode.rawValue)")
        if input.preferences.networkPolicy.directDomainRules.isEmpty {
            lines.append("Direct domains: none")
        } else {
            lines.append("Direct domains: \(input.preferences.networkPolicy.directDomainRules.joined(separator: ", "))")
        }
        for override in input.preferences.networkPolicy.providerOverrides.sorted(by: { $0.key < $1.key }).prefix(80) {
            lines.append("- \(override.key): \(override.value.rawValue)")
        }
        if input.preferences.networkPolicy.providerOverrides.isEmpty {
            lines.append("- provider overrides: none")
        }
        lines.append("")

        lines.append("[Network Diagnostics]")
        for diagnostic in input.networkDiagnostics.prefix(80) {
            lines.append("- \(ProviderDisplay.appTypeLabel(diagnostic.appType)) / \(diagnostic.providerName): \(diagnostic.failedMode.rawValue) failed (\(redact(diagnostic.failedError))), \(diagnostic.fallbackMode.rawValue) HTTP \(diagnostic.fallbackStatusCode), url=\(redact(diagnostic.url)), at \(formatter.string(from: diagnostic.checkedAt))")
        }
        if input.networkDiagnostics.isEmpty {
            lines.append("- none")
        }
        lines.append("")

        lines.append("[Recent Events]")
        for event in input.recentEvents.prefix(30) {
            lines.append("- \(formatter.string(from: event.date)) [\(event.level)] \(redact(event.message))")
        }
        if input.recentEvents.isEmpty {
            lines.append("- none")
        }

        return lines.joined(separator: "\n")
    }

    public static func redact(_ text: String) -> String {
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            #"Bearer\s+[A-Za-z0-9_\-\.]{8,}"#,
            #"(?i)(api[_-]?key|token|secret)["']?\s*[:=]\s*["']?[^"',\s]+"#
        ]
        var redacted = text
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: [.regularExpression]
            )
        }
        return redacted
    }
}
