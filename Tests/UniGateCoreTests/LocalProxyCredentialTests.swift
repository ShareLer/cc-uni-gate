@testable import UniGateCore
import Foundation
import Testing

struct LocalProxyCredentialTests {
    @Test
    func createsAndReusesAtLeast32BytesOfRandomCredentialMaterial() throws {
        let store = InMemoryLocalProxyCredentialStore()
        var requestedByteCounts: [Int] = []
        let manager = LocalProxyCredentialManager(
            store: store,
            randomByteCount: 1,
            randomData: { byteCount in
                requestedByteCounts.append(byteCount)
                return Data((0..<byteCount).map(UInt8.init))
            }
        )

        let first = try manager.loadOrCreateToken()
        let second = try manager.loadOrCreateToken()

        #expect(first == second)
        #expect(first.hasPrefix(LocalProxyCredentialManager.tokenPrefix))
        #expect(LocalProxyCredentialManager.hasMinimumEntropyEncoding(first))
        #expect(requestedByteCounts == [LocalProxyCredentialManager.minimumRandomByteCount])
        #expect(store.savedTokens == [first])
    }

    @Test
    func replacesLegacyFixedCredentialInsteadOfTrustingItForOfficialRoutes() throws {
        let store = InMemoryLocalProxyCredentialStore(token: CcSwitchDeepLink.localAPIKey)
        let manager = LocalProxyCredentialManager(
            store: store,
            randomData: { Data(repeating: 0xA5, count: $0) }
        )

        let token = try manager.loadOrCreateToken()

        #expect(token != CcSwitchDeepLink.localAPIKey)
        #expect(LocalProxyCredentialManager.hasMinimumEntropyEncoding(token))
        #expect(store.savedTokens == [token])
    }

    @Test
    func rejectsGeneratorsThatReturnLessThan32Bytes() {
        let store = InMemoryLocalProxyCredentialStore()
        let manager = LocalProxyCredentialManager(
            store: store,
            randomData: { _ in Data(repeating: 0x01, count: 31) }
        )

        #expect(throws: LocalProxyCredentialError.self) {
            try manager.loadOrCreateToken()
        }
        #expect(store.savedTokens.isEmpty)
    }

    @Test
    func concurrentFirstLaunchesConvergeOnOnePersistedCredential() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lockFileURL = directory.appendingPathComponent("credential.lock")
        let store = InMemoryLocalProxyCredentialStore()
        let counter = LockedByteCounter()
        let randomData: @Sendable (Int) throws -> Data = { byteCount in
            Data(repeating: counter.next(), count: byteCount)
        }
        let firstManager = LocalProxyCredentialManager(
            store: store,
            randomData: randomData,
            lockFileURL: lockFileURL
        )
        let secondManager = LocalProxyCredentialManager(
            store: store,
            randomData: randomData,
            lockFileURL: lockFileURL
        )

        async let first = Task.detached { try firstManager.loadOrCreateToken() }.value
        async let second = Task.detached { try secondManager.loadOrCreateToken() }.value
        let tokens = try await [first, second]

        #expect(Set(tokens).count == 1)
        #expect(store.savedTokenSnapshot() == [tokens[0]])
        #expect(counter.value == 1)
    }

    @Test
    func onlyOfficialRoutesRequireTheInstallationCredential() {
        let expected = "sk-unigate-installation-token"
        let providerRef = ProviderRef(appType: UniGateAppRegistry.codex, id: "official")

        #expect(LocalProxyAuthorizationPolicy.allows(
            bearerToken: CcSwitchDeepLink.localAPIKey,
            expectedToken: expected,
            requirement: .staticProvider
        ))
        #expect(!LocalProxyAuthorizationPolicy.allows(
            bearerToken: CcSwitchDeepLink.localAPIKey,
            expectedToken: expected,
            requirement: .codexOfficial(providerRef: providerRef)
        ))
        #expect(LocalProxyAuthorizationPolicy.allows(
            bearerToken: expected,
            expectedToken: expected,
            requirement: .codexOfficial(providerRef: providerRef)
        ))
        #expect(!LocalProxyAuthorizationPolicy.allows(
            bearerToken: nil,
            expectedToken: expected,
            requirement: .codexOfficial(providerRef: providerRef)
        ))
    }
}

private final class InMemoryLocalProxyCredentialStore: LocalProxyCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private(set) var savedTokens: [String] = []

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() throws -> String? {
        lock.withLock { token }
    }

    func saveToken(_ token: String) throws {
        lock.withLock {
            self.token = token
            savedTokens.append(token)
        }
    }

    func savedTokenSnapshot() -> [String] {
        lock.withLock { savedTokens }
    }
}

private final class LockedByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt8 = 0

    var value: UInt8 {
        lock.withLock { count }
    }

    func next() -> UInt8 {
        lock.withLock {
            count &+= 1
            return count
        }
    }
}
