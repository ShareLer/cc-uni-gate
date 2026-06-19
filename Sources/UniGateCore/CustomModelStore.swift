import Foundation

public struct CustomModelTarget: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var routeKey: ModelRouteKey
    public var providerRef: ProviderRef

    public init(id: UUID = UUID(), routeKey: ModelRouteKey, providerRef: ProviderRef) {
        self.id = id
        self.routeKey = routeKey
        self.providerRef = providerRef
    }
}

public struct CustomModelDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var appType: String
    public var name: String
    public var targets: [CustomModelTarget]
    public var selectedTargetID: UUID?

    public init(
        id: UUID = UUID(),
        appType: String,
        name: String,
        targets: [CustomModelTarget] = [],
        selectedTargetID: UUID? = nil
    ) {
        self.id = id
        self.appType = appType
        self.name = name
        self.targets = targets
        self.selectedTargetID = selectedTargetID
    }

    public var selectedTarget: CustomModelTarget? {
        if let selectedTargetID, let target = targets.first(where: { $0.id == selectedTargetID }) {
            return target
        }
        return targets.first
    }
}

public struct CustomModelState: Codable, Sendable {
    public var models: [CustomModelDefinition]

    public init(models: [CustomModelDefinition] = []) {
        self.models = models
    }

    public func expandedCandidates(from catalog: ProviderCatalog) -> [ModelCandidate] {
        models.compactMap { definition in
            guard let target = definition.selectedTarget else {
                return nil
            }
            guard
                target.routeKey.appType == definition.appType,
                let candidate = catalog.candidates.first(where: {
                    $0.appType == target.routeKey.appType
                        && $0.logicalModel == target.routeKey.logicalModel
                        && $0.providerRef == target.providerRef
                })
            else {
                return nil
            }
            return ModelCandidate(
                logicalModel: definition.name,
                providerRef: candidate.providerRef,
                providerName: candidate.providerName,
                appType: definition.appType,
                clientProtocol: candidate.clientProtocol,
                apiFormat: candidate.apiFormat,
                upstreamModel: candidate.upstreamModel,
                baseURL: candidate.baseURL,
                requiresTransform: candidate.requiresTransform,
                label: "自定义：\(candidate.logicalModel)",
                supportsLongContext: candidate.supportsLongContext
            )
        }
    }
}

public final class CustomModelStore: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = CustomModelStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultFileURL() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("custom-models.json", isDirectory: false)
    }

    public func load() throws -> CustomModelState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CustomModelState()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(CustomModelState.self, from: data)
    }

    public func save(_ state: CustomModelState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
