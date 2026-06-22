import Foundation

public struct ProviderModelDiscoveryResult: Codable, Sendable, Equatable, Identifiable {
    public var providerRef: ProviderRef
    public var appType: String
    public var providerName: String
    public var modelIDs: [String]
    public var errorMessage: String?
    public var sourceURL: String?
    public var updatedAt: Date

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
        updatedAt: Date = Date()
    ) {
        self.providerRef = providerRef
        self.appType = appType
        self.providerName = providerName
        self.modelIDs = modelIDs
        self.errorMessage = errorMessage
        self.sourceURL = sourceURL
        self.updatedAt = updatedAt
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

    public mutating func upsert(_ result: ProviderModelDiscoveryResult) {
        results[result.providerRef.description] = result
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
