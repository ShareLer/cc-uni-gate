import Foundation
import Security

public struct CustomProviderDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var appType: String
    public var name: String
    public var baseURL: String
    public var apiFormat: ApiFormat
    public var category: String?
    public var sortIndex: Int?
    public var isCurrent: Bool
    public var enableDiscovery: Bool
    public var apiKeyIdentifier: String?
    public var isFullUrl: Bool
    public var modelsUrl: String?
    public var customUserAgent: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case appType
        case name
        case baseURL
        case apiFormat
        case category
        case sortIndex
        case isCurrent
        case enableDiscovery
        case apiKeyIdentifier
        case isFullUrl
        case modelsUrl
        case customUserAgent
    }

    public init(
        id: String = Self.makeID(),
        appType: String,
        name: String,
        baseURL: String,
        apiFormat: ApiFormat,
        category: String? = nil,
        sortIndex: Int? = nil,
        isCurrent: Bool = false,
        enableDiscovery: Bool = true,
        apiKeyIdentifier: String? = nil,
        isFullUrl: Bool = false,
        modelsUrl: String? = nil,
        customUserAgent: String? = nil
    ) {
        self.id = id
        self.appType = appType
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiFormat = apiFormat
        self.category = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sortIndex = sortIndex
        self.isCurrent = isCurrent
        self.enableDiscovery = enableDiscovery
        self.apiKeyIdentifier = apiKeyIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isFullUrl = isFullUrl
        self.modelsUrl = modelsUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.customUserAgent = customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appType = try container.decode(String.self, forKey: .appType)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? Self.makeID(),
            appType: appType,
            name: try container.decode(String.self, forKey: .name),
            baseURL: try container.decode(String.self, forKey: .baseURL),
            apiFormat: try container.decodeIfPresent(ApiFormat.self, forKey: .apiFormat)
                ?? UniGateAppRegistry.defaultApiFormat(for: appType),
            category: try container.decodeIfPresent(String.self, forKey: .category),
            sortIndex: try container.decodeIfPresent(Int.self, forKey: .sortIndex),
            isCurrent: try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false,
            enableDiscovery: try container.decodeIfPresent(Bool.self, forKey: .enableDiscovery) ?? true,
            apiKeyIdentifier: try container.decodeIfPresent(String.self, forKey: .apiKeyIdentifier),
            isFullUrl: try container.decodeIfPresent(Bool.self, forKey: .isFullUrl) ?? false,
            modelsUrl: try container.decodeIfPresent(String.self, forKey: .modelsUrl),
            customUserAgent: try container.decodeIfPresent(String.self, forKey: .customUserAgent)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appType, forKey: .appType)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiFormat, forKey: .apiFormat)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(sortIndex, forKey: .sortIndex)
        try container.encode(isCurrent, forKey: .isCurrent)
        try container.encode(enableDiscovery, forKey: .enableDiscovery)
        try container.encodeIfPresent(apiKeyIdentifier, forKey: .apiKeyIdentifier)
        try container.encode(isFullUrl, forKey: .isFullUrl)
        try container.encodeIfPresent(modelsUrl, forKey: .modelsUrl)
        try container.encodeIfPresent(customUserAgent, forKey: .customUserAgent)
    }

    public static func makeID() -> String {
        "unigate-\(UUID().uuidString.lowercased())"
    }

    public var providerRef: ProviderRef {
        ProviderRef(appType: appType, id: id)
    }

    public var displayName: String {
        "\(name) · \(ProviderDisplay.appTypeLabel(appType))"
    }

    public var hasSecret: Bool {
        apiKeyIdentifier != nil
    }

    public func normalized() -> CustomProviderDefinition {
        CustomProviderDefinition(
            id: id,
            appType: appType,
            name: name,
            baseURL: baseURL,
            apiFormat: apiFormat,
            category: category,
            sortIndex: sortIndex,
            isCurrent: isCurrent,
            enableDiscovery: enableDiscovery,
            apiKeyIdentifier: apiKeyIdentifier,
            isFullUrl: isFullUrl,
            modelsUrl: modelsUrl,
            customUserAgent: customUserAgent
        )
    }

    public func withSecretIdentifier(_ identifier: String?) -> CustomProviderDefinition {
        var next = self
        next.apiKeyIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return next
    }

    public func withDiscoveryEnabled(_ enabled: Bool) -> CustomProviderDefinition {
        var next = self
        next.enableDiscovery = enabled
        return next
    }

    public func withDiscoveryMetadata(
        isFullUrl: Bool,
        modelsUrl: String?,
        customUserAgent: String?
    ) -> CustomProviderDefinition {
        var next = self
        next.isFullUrl = isFullUrl
        next.modelsUrl = modelsUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.customUserAgent = customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        return next
    }

    public func toImportedProvider(apiKey: String?) -> ImportedProvider {
        ImportedProvider(
            id: id,
            appType: appType,
            name: name,
            category: category,
            sortIndex: sortIndex,
            isCurrent: isCurrent,
            apiFormat: apiFormat,
            baseURL: baseURL,
            hasSecret: apiKey != nil,
            settings: Self.settings(appType: appType, apiFormat: apiFormat, apiKey: apiKey),
            meta: Self.meta(
                isFullUrl: isFullUrl,
                modelsUrl: modelsUrl,
                customUserAgent: customUserAgent
            )
        )
    }

    private static func settings(
        appType: String,
        apiFormat: ApiFormat,
        apiKey: String?
    ) -> [String: SendableValue] {
        guard let apiKey else {
            return [:]
        }
        switch appType {
        case UniGateAppRegistry.codex:
            return ["env": .object(["OPENAI_API_KEY": .string(apiKey)])]
        case UniGateAppRegistry.claudeCode, UniGateAppRegistry.claudeDesktop:
            if apiFormat == .anthropic {
                return ["env": .object(["ANTHROPIC_API_KEY": .string(apiKey)])]
            }
            return ["env": .object(["OPENAI_API_KEY": .string(apiKey)])]
        case "gemini":
            return ["env": .object(["GEMINI_API_KEY": .string(apiKey)])]
        default:
            return ["api_key": .string(apiKey)]
        }
    }

    private static func meta(
        isFullUrl: Bool,
        modelsUrl: String?,
        customUserAgent: String?
    ) -> [String: SendableValue] {
        var meta: [String: SendableValue] = [
            "isFullUrl": .bool(isFullUrl),
            "source": .string("unigate")
        ]
        if let modelsUrl, !modelsUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meta["modelsUrl"] = .string(modelsUrl)
        }
        if let customUserAgent, !customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meta["customUserAgent"] = .string(customUserAgent)
        }
        return meta
    }

}

public struct CustomProviderState: Codable, Sendable, Equatable {
    public var definitions: [CustomProviderDefinition]

    public init(definitions: [CustomProviderDefinition] = []) {
        self.definitions = Self.deduplicated(definitions)
    }

    private enum CodingKeys: String, CodingKey {
        case definitions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.definitions = Self.deduplicated(try container.decodeIfPresent(
            [CustomProviderDefinition].self,
            forKey: .definitions
        ) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(definitions, forKey: .definitions)
    }

    public func normalized() -> CustomProviderState {
        CustomProviderState(definitions: definitions.map { $0.normalized() })
    }

    public func definition(for ref: ProviderRef) -> CustomProviderDefinition? {
        definitions.first { $0.providerRef == ref }
    }

    public func definition(id: String) -> CustomProviderDefinition? {
        definitions.first { $0.id == id }
    }

    public func definition(for appType: String, id: String) -> CustomProviderDefinition? {
        definitions.first { $0.appType == appType && $0.id == id }
    }

    public func isDiscoveryEnabled(for ref: ProviderRef) -> Bool? {
        definition(for: ref)?.enableDiscovery
    }

    public func importedProviders(keychain: CustomProviderKeychain = .shared) -> [ImportedProvider] {
        definitions.map { definition in
            definition.toImportedProvider(apiKey: apiKey(for: definition.providerRef, keychain: keychain))
        }
    }

    public func activeDiscoveryProviders(keychain: CustomProviderKeychain = .shared) -> [ImportedProvider] {
        definitions
            .filter { $0.enableDiscovery }
            .map { definition in
                definition.toImportedProvider(apiKey: apiKey(for: definition.providerRef, keychain: keychain))
            }
    }

    public func apiKey(for ref: ProviderRef, keychain: CustomProviderKeychain = .shared) -> String? {
        guard let definition = definition(for: ref) else {
            return nil
        }
        if let identifier = definition.apiKeyIdentifier, let value = try? keychain.read(identifier: identifier) {
            return value
        }
        return try? keychain.read(identifier: definition.id)
    }

    public func hasSecret(for ref: ProviderRef, keychain: CustomProviderKeychain = .shared) -> Bool {
        apiKey(for: ref, keychain: keychain) != nil
    }

    public func providerRefs() -> [ProviderRef] {
        definitions.map(\.providerRef)
    }

    public func secretIdentifiers() -> Set<String> {
        Set(definitions.compactMap { $0.apiKeyIdentifier ?? $0.id })
    }

    public func replacingDefinition(_ definition: CustomProviderDefinition) -> CustomProviderState {
        var next = definitions
        if let index = next.firstIndex(where: { $0.id == definition.id }) {
            next[index] = definition
        } else {
            next.append(definition)
        }
        return CustomProviderState(definitions: next)
    }

    public func removingDefinition(id: String) -> CustomProviderState {
        CustomProviderState(definitions: definitions.filter { $0.id != id })
    }

    public func definitions(for appType: String) -> [CustomProviderDefinition] {
        definitions.filter { $0.appType == appType }
    }

    private static func deduplicated(_ definitions: [CustomProviderDefinition]) -> [CustomProviderDefinition] {
        var seen = Set<String>()
        var result: [CustomProviderDefinition] = []
        for definition in definitions.reversed() {
            guard !seen.contains(definition.id) else {
                continue
            }
            seen.insert(definition.id)
            result.insert(definition, at: 0)
        }
        return result
    }
}

public enum CustomProviderSecretRetention {
    public static func identifierToPreserve(
        existing: CustomProviderDefinition?,
        canReadSecret: (String) -> Bool
    ) -> String? {
        guard
            let existing,
            let identifier = existing.apiKeyIdentifier,
            canReadSecret(identifier)
        else {
            return nil
        }
        return identifier
    }
}

public final class CustomProviderStore: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = CustomProviderStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static func defaultFileURL() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("custom-providers.json", isDirectory: false)
    }

    public func load() throws -> CustomProviderState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CustomProviderState()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(CustomProviderState.self, from: data).normalized()
    }

    public func save(_ state: CustomProviderState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state.normalized())
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct CustomProviderKeychain: Sendable {
    public static let shared = CustomProviderKeychain()

    private let service: String

    public init(service: String = "UniGate.CustomProviders") {
        self.service = service
    }

    public func read(identifier: String) throws -> String? {
        var query: [String: Any] = baseQuery(identifier: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ value: String, identifier: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(identifier: identifier)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addQuery = query.merging(attributes, uniquingKeysWith: { $1 })
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
    }

    public func delete(identifier: String) throws {
        let query = baseQuery(identifier: identifier)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(identifier: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error"
            ]
        )
    }
}
