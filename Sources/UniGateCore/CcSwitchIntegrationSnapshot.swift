import Foundation

public struct CcSwitchIntegrationSnapshot: Sendable, Equatable {
    public var databasePath: String
    public var providers: [CcSwitchProviderSummary]

    public init(databasePath: String, providers: [CcSwitchProviderSummary]) {
        self.databasePath = databasePath
        self.providers = providers
    }

    public func uniGateProvider(appType: String) -> CcSwitchProviderSummary? {
        providers.first { $0.appType == appType && $0.isUniGateProvider }
    }

    public func providers(appType: String) -> [CcSwitchProviderSummary] {
        providers.filter { $0.appType == appType }
    }
}

public struct CcSwitchProviderSummary: Identifiable, Sendable, Equatable {
    public var id: String
    public var appType: String
    public var name: String
    public var isCurrent: Bool
    public var isUniGateProvider: Bool
    public var baseURL: String?
    public var configuredModels: [String]
    public var hasClaudeDesktopRoutes: Bool

    public init(
        id: String,
        appType: String,
        name: String,
        isCurrent: Bool,
        isUniGateProvider: Bool,
        baseURL: String?,
        configuredModels: [String],
        hasClaudeDesktopRoutes: Bool
    ) {
        self.id = id
        self.appType = appType
        self.name = name
        self.isCurrent = isCurrent
        self.isUniGateProvider = isUniGateProvider
        self.baseURL = baseURL
        self.configuredModels = configuredModels
        self.hasClaudeDesktopRoutes = hasClaudeDesktopRoutes
    }
}

