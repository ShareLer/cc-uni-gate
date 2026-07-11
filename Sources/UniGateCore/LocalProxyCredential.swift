import Darwin
import Foundation
import Security

public protocol LocalProxyCredentialStoring: Sendable {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
}

public struct LocalProxyKeychainCredentialStore: LocalProxyCredentialStoring, Sendable {
    public static let shared = LocalProxyKeychainCredentialStore()

    private let service: String
    private let account: String

    public init(
        service: String = "UniGate.LocalProxy",
        account: String = "bearer-token"
    ) {
        self.service = service
        self.account = account
    }

    public func loadToken() throws -> String? {
        var query = baseQuery
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
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    public func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addQuery = baseQuery.merging(attributes, uniquingKeysWith: { $1 })
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?)
                    ?? "Keychain error"
            ]
        )
    }
}

public struct LocalProxyCredentialManager: @unchecked Sendable {
    public static let minimumRandomByteCount = 32
    public static let tokenPrefix = "sk-unigate-"

    private let store: any LocalProxyCredentialStoring
    private let randomByteCount: Int
    private let randomData: (Int) throws -> Data
    private let lockFileURL: URL?

    public init(
        store: any LocalProxyCredentialStoring = LocalProxyKeychainCredentialStore.shared,
        randomByteCount: Int = LocalProxyCredentialManager.minimumRandomByteCount
    ) {
        self.store = store
        self.randomByteCount = max(randomByteCount, Self.minimumRandomByteCount)
        self.randomData = Self.secureRandomData
        self.lockFileURL = AppPaths.applicationSupportDirectory()
            .appendingPathComponent("local-proxy-credential.lock", isDirectory: false)
    }

    init(
        store: any LocalProxyCredentialStoring,
        randomByteCount: Int = LocalProxyCredentialManager.minimumRandomByteCount,
        randomData: @escaping (Int) throws -> Data,
        lockFileURL: URL? = nil
    ) {
        self.store = store
        self.randomByteCount = max(randomByteCount, Self.minimumRandomByteCount)
        self.randomData = randomData
        self.lockFileURL = lockFileURL
    }

    public func loadOrCreateToken() throws -> String {
        guard let lockFileURL else {
            return try loadOrCreateTokenWhileLocked()
        }
        return try Self.withExclusiveFileLock(at: lockFileURL) {
            try loadOrCreateTokenWhileLocked()
        }
    }

    private func loadOrCreateTokenWhileLocked() throws -> String {
        if let token = try store.loadToken(), Self.hasMinimumEntropyEncoding(token) {
            return token
        }

        let bytes = try randomData(randomByteCount)
        guard bytes.count >= Self.minimumRandomByteCount else {
            throw LocalProxyCredentialError.insufficientRandomData
        }
        let token = Self.tokenPrefix + bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try store.saveToken(token)
        return token
    }

    private static func withExclusiveFileLock<T>(
        at fileURL: URL,
        operation: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            fileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw LocalProxyCredentialError.lockFailed(errno)
        }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw LocalProxyCredentialError.lockFailed(errno)
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func hasMinimumEntropyEncoding(_ token: String) -> Bool {
        guard token.hasPrefix(tokenPrefix) else {
            return false
        }
        var encoded = String(token.dropFirst(tokenPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: encoded)?.count ?? 0 >= minimumRandomByteCount
    }

    private static func secureRandomData(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw LocalProxyCredentialError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}

public enum LocalProxyCredentialError: Error, LocalizedError {
    case randomGenerationFailed(OSStatus)
    case insufficientRandomData
    case lockFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .randomGenerationFailed(status):
            return "无法生成本地代理凭据（\(status)）。"
        case .insufficientRandomData:
            return "本地代理凭据的随机数据不足 32 字节。"
        case let .lockFailed(code):
            return "无法锁定本地代理凭据（\(code)）。"
        }
    }
}

public enum LocalProxyAuthorizationPolicy {
    public static func allows(
        bearerToken: String?,
        expectedToken: String?,
        requirement: ProxyAuthorizationRequirement
    ) -> Bool {
        switch requirement {
        case .staticProvider:
            return true
        case .codexOfficial:
            guard let bearerToken, let expectedToken else {
                return false
            }
            let candidateBytes = Array(bearerToken.utf8)
            let expectedBytes = Array(expectedToken.utf8)
            guard candidateBytes.count == expectedBytes.count else {
                return false
            }
            return zip(candidateBytes, expectedBytes).reduce(UInt8(0)) { difference, pair in
                difference | (pair.0 ^ pair.1)
            } == 0
        }
    }
}
