import Foundation

public struct UniGateConfigurationBackup: Codable, Sendable {
    public var version: Int
    public var exportedAt: Date
    public var preferences: AppPreferences
    public var routes: RouteState
    public var customModels: CustomModelState
    public var customProviders: CustomProviderState

    private enum CodingKeys: String, CodingKey {
        case version
        case exportedAt
        case preferences
        case routes
        case customModels
        case customProviders
    }

    public init(
        version: Int = 2,
        exportedAt: Date = Date(),
        preferences: AppPreferences,
        routes: RouteState,
        customModels: CustomModelState,
        customProviders: CustomProviderState = CustomProviderState()
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.preferences = preferences
        self.routes = routes
        self.customModels = customModels
        self.customProviders = customProviders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        self.preferences = try container.decode(AppPreferences.self, forKey: .preferences)
        self.routes = try container.decode(RouteState.self, forKey: .routes)
        self.customModels = try container.decode(CustomModelState.self, forKey: .customModels)
        self.customProviders = try container.decodeIfPresent(CustomProviderState.self, forKey: .customProviders) ?? CustomProviderState()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(preferences, forKey: .preferences)
        try container.encode(routes, forKey: .routes)
        try container.encode(customModels, forKey: .customModels)
        try container.encode(customProviders, forKey: .customProviders)
    }

    public var importsCustomProviders: Bool {
        version >= 2
    }

    public func customProvidersForImport(current: CustomProviderState) -> CustomProviderState {
        importsCustomProviders ? customProviders : current
    }
}

public final class ConfigurationBackupStore: @unchecked Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ backup: UniGateConfigurationBackup, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(backup)
        try data.write(to: fileURL, options: .atomic)
    }

    public func load(from fileURL: URL) throws -> UniGateConfigurationBackup {
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(UniGateConfigurationBackup.self, from: data)
    }

    public static func defaultExportURL(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "UniGate-Backup-\(formatter.string(from: now)).json"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }
}
