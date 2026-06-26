import Foundation

public enum BrandColorPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case ember
    case blue
    case indigo
    case violet
    case teal
    case green
    case rose

    public var id: String { rawValue }
}

public struct AppPreferences: Codable, Sendable {
    public var visibleModels: Set<String>?
    public var protocolOverrides: [String: ApiFormat]
    public var port: UInt16
    public var ccSwitchDBPath: String?
    public var brandColor: BrandColorPreset
    public var bubbleNotificationsEnabled: Bool
    public var launchAtLoginEnabled: Bool
    public var networkPolicy: NetworkPolicyPreferences
    public var modelDiscoveryDisabledProviders: Set<String>

    public init(
        visibleModels: Set<String>? = nil,
        protocolOverrides: [String: ApiFormat] = [:],
        port: UInt16 = 17888,
        ccSwitchDBPath: String? = nil,
        brandColor: BrandColorPreset = .ember,
        bubbleNotificationsEnabled: Bool = true,
        launchAtLoginEnabled: Bool = true,
        networkPolicy: NetworkPolicyPreferences = NetworkPolicyPreferences(),
        modelDiscoveryDisabledProviders: Set<String> = []
    ) {
        self.visibleModels = visibleModels
        self.protocolOverrides = protocolOverrides
        self.port = port
        self.ccSwitchDBPath = ccSwitchDBPath
        self.brandColor = brandColor
        self.bubbleNotificationsEnabled = bubbleNotificationsEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.networkPolicy = networkPolicy
        self.modelDiscoveryDisabledProviders = modelDiscoveryDisabledProviders
    }

    enum CodingKeys: String, CodingKey {
        case visibleModels
        case protocolOverrides
        case port
        case ccSwitchDBPath
        case brandColor
        case bubbleNotificationsEnabled
        case launchAtLoginEnabled
        case networkPolicy
        case modelDiscoveryDisabledProviders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.visibleModels = try container.decodeIfPresent(Set<String>.self, forKey: .visibleModels)
        self.protocolOverrides = try container.decodeIfPresent([String: ApiFormat].self, forKey: .protocolOverrides) ?? [:]
        self.port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 17888
        self.ccSwitchDBPath = try container.decodeIfPresent(String.self, forKey: .ccSwitchDBPath)
        let brandColorValue = try container.decodeIfPresent(String.self, forKey: .brandColor)
        self.brandColor = brandColorValue.flatMap(BrandColorPreset.init(rawValue:)) ?? .ember
        self.bubbleNotificationsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .bubbleNotificationsEnabled
        ) ?? true
        self.launchAtLoginEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .launchAtLoginEnabled
        ) ?? true
        self.networkPolicy = try container.decodeIfPresent(
            NetworkPolicyPreferences.self,
            forKey: .networkPolicy
        ) ?? NetworkPolicyPreferences()
        self.modelDiscoveryDisabledProviders = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .modelDiscoveryDisabledProviders
        ) ?? []
    }

    public func visibleModelList(allModels: [String]) -> [String] {
        guard let visibleModels else {
            return allModels
        }
        return allModels.filter { visibleModels.contains($0) }
    }

    public func visibleRouteKeyList(allRouteKeys: [ModelRouteKey]) -> [ModelRouteKey] {
        guard let visibleModels else {
            return allRouteKeys
        }
        return allRouteKeys.filter {
            visibleModels.contains($0.description) || visibleModels.contains($0.logicalModel)
        }
    }

    public func protocolOverride(for providerRef: ProviderRef) -> ApiFormat? {
        protocolOverrides[providerRef.description]
    }

    public func isModelDiscoveryEnabled(for providerRef: ProviderRef) -> Bool {
        !modelDiscoveryDisabledProviders.contains(providerRef.description)
    }

    public mutating func setModelDiscoveryEnabled(_ enabled: Bool, for providerRef: ProviderRef) {
        if enabled {
            modelDiscoveryDisabledProviders.remove(providerRef.description)
        } else {
            modelDiscoveryDisabledProviders.insert(providerRef.description)
        }
    }

    public var normalizedPort: UInt16 {
        port == 0 ? 17888 : port
    }

    public var resolvedCcSwitchDBPath: String {
        let path = ccSwitchDBPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty {
            return (path as NSString).expandingTildeInPath
        }
        return Self.defaultCcSwitchDBPath()
    }

    public static func defaultCcSwitchDBPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")
            .path
    }
}

public final class PreferencesStore: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = PreferencesStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultFileURL() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("preferences.json", isDirectory: false)
    }

    public func load() throws -> AppPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppPreferences()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AppPreferences.self, from: data)
    }

    public func save(_ preferences: AppPreferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(preferences)
        try data.write(to: fileURL, options: .atomic)
    }
}
