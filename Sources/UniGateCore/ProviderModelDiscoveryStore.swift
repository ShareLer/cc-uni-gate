import Foundation
import CryptoKit

public struct ProviderModelDiscoveryResult: Codable, Sendable, Equatable, Identifiable {
    public var providerRef: ProviderRef
    public var appType: String
    public var providerName: String
    public var modelIDs: [String]
    public var errorMessage: String?
    public var sourceURL: String?
    public var updatedAt: Date
    public var configurationFingerprint: String?

    public var id: String {
        providerRef.description
    }

    public init(
        providerRef: ProviderRef,
        appType: String,
        providerName: String,
        modelIDs: [String],
        errorMessage: String?,
        sourceURL: String?,
        updatedAt: Date = Date(),
        configurationFingerprint: String? = nil
    ) {
        self.providerRef = providerRef
        self.appType = appType
        self.providerName = providerName
        self.modelIDs = modelIDs
        self.errorMessage = errorMessage
        self.sourceURL = sourceURL
        self.updatedAt = updatedAt
        self.configurationFingerprint = configurationFingerprint
    }
}

public struct ProviderModelDiscoveryState: Codable, Sendable, Equatable {
    public var results: [String: ProviderModelDiscoveryResult]

    public init(results: [String: ProviderModelDiscoveryResult] = [:]) {
        self.results = results
    }

    public func results(appType: String) -> [ProviderModelDiscoveryResult] {
        results.values
            .filter { $0.appType == appType }
            .sorted {
                $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending
            }
    }

    public func pruning(validProviderRefs: Set<ProviderRef>) -> ProviderModelDiscoveryState {
        ProviderModelDiscoveryState(results: results.filter { _, result in
            validProviderRefs.contains(result.providerRef)
        })
    }

    public func pruning(validProviders providers: [ImportedProvider]) -> ProviderModelDiscoveryState {
        var fingerprintsByRef: [ProviderRef: String] = [:]
        for provider in providers {
            fingerprintsByRef[provider.ref] = ProviderModelDiscoveryFingerprint.value(for: provider)
        }
        return ProviderModelDiscoveryState(results: results.filter { _, result in
            guard let fingerprint = fingerprintsByRef[result.providerRef] else {
                return false
            }
            return result.configurationFingerprint == fingerprint
        })
    }

    public mutating func upsert(_ result: ProviderModelDiscoveryResult) {
        let key = result.providerRef.description
        guard
            result.errorMessage != nil,
            result.modelIDs.isEmpty,
            var previous = results[key],
            !previous.modelIDs.isEmpty,
            previous.configurationFingerprint == result.configurationFingerprint
        else {
            results[key] = result
            return
        }
        previous.errorMessage = result.errorMessage
        previous.sourceURL = result.sourceURL ?? previous.sourceURL
        previous.updatedAt = result.updatedAt
        results[key] = previous
    }
}

public enum ProviderModelDiscoveryFingerprint {
    public static func value(for provider: ImportedProvider) -> String {
        let plan = ProviderModelDiscovery.fetchPlan(for: provider)
        let secret = ProviderCredentials.secret(for: provider)
        let components = [
            "app=\(provider.appType)",
            "format=\(provider.apiFormat.rawValue)",
            "base=\(provider.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")",
            "isFullURL=\(bool(provider.meta, ["isFullUrl"]) ?? false)",
            "modelsURL=\(modelsURLOverride(for: provider) ?? "")",
            "urls=\(plan?.urls.map(\.absoluteString).joined(separator: ",") ?? "")",
            "ua=\(JSONValueParser.string(provider.meta, ["customUserAgent"]) ?? "")",
            "secretField=\(secret?.field ?? "")",
            "secretHash=\(secret.map { shortHash($0.value) } ?? "")"
        ]
        return shortHash(components.joined(separator: "\n"))
    }

    private static func modelsURLOverride(for provider: ImportedProvider) -> String? {
        JSONValueParser.string(provider.meta, ["modelsUrl"])
            ?? JSONValueParser.string(provider.settings, ["modelsUrl"])
            ?? JSONValueParser.string(provider.settings, ["models_url"])
    }

    private static func bool(_ object: [String: SendableValue], _ path: [String]) -> Bool? {
        switch JSONValueParser.value(object, path) {
        case let .bool(value):
            return value
        case let .number(value):
            return value != 0
        default:
            return nil
        }
    }

    private static func shortHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public final class ProviderModelDiscoveryStore: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = ProviderModelDiscoveryStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultFileURL() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("model-discovery.json", isDirectory: false)
    }

    public func load() throws -> ProviderModelDiscoveryState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProviderModelDiscoveryState()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(ProviderModelDiscoveryState.self, from: data)
    }

    public func save(_ state: ProviderModelDiscoveryState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
