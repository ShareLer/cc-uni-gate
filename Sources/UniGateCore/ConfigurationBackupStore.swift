import Foundation

public struct UniGateConfigurationBackup: Codable, Sendable {
    public var version: Int
    public var exportedAt: Date
    public var preferences: AppPreferences
    public var routes: RouteState
    public var customModels: CustomModelState

    public init(
        version: Int = 1,
        exportedAt: Date = Date(),
        preferences: AppPreferences,
        routes: RouteState,
        customModels: CustomModelState
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.preferences = preferences
        self.routes = routes
        self.customModels = customModels
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
