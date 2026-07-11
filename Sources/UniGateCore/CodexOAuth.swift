import CryptoKit
import Foundation
import Security

public struct CodexOAuthPKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    public static func generate() -> CodexOAuthPKCE {
        CodexOAuthPKCE(verifier: randomToken(byteCount: 64))
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    fileprivate static func randomToken(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncodedString()
    }
}

public struct CodexOAuthLoginRequest: Equatable, Sendable {
    public let state: String
    public let pkce: CodexOAuthPKCE
    public let redirectURI: URL
    public let authorizationURL: URL

    public static func make(
        redirectURI: URL = CodexOfficial.redirectURI
    ) throws -> CodexOAuthLoginRequest {
        let state = CodexOAuthPKCE.randomToken(byteCount: 32)
        let pkce = CodexOAuthPKCE.generate()
        return try CodexOAuthLoginRequest(state: state, pkce: pkce, redirectURI: redirectURI)
    }

    public init(
        state: String,
        pkce: CodexOAuthPKCE,
        redirectURI: URL = CodexOfficial.redirectURI
    ) throws {
        guard
            !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            var components = URLComponents(
                url: CodexOfficial.authorizationEndpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw CodexOAuthError.invalidAuthorizationRequest
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexOfficial.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: CodexOfficial.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: CodexOfficial.oauthOriginator)
        ]
        guard let authorizationURL = components.url else {
            throw CodexOAuthError.invalidAuthorizationRequest
        }

        self.state = state
        self.pkce = pkce
        self.redirectURI = redirectURI
        self.authorizationURL = authorizationURL
    }
}

public struct CodexOAuthJWTClaims: Equatable, Sendable {
    public let accountID: String?
    public let email: String?
    public let expiresAt: Date?
    public let isFedRAMP: Bool?

    public init(accountID: String?, email: String?, expiresAt: Date?, isFedRAMP: Bool? = nil) {
        self.accountID = accountID
        self.email = email
        self.expiresAt = expiresAt
        self.isFedRAMP = isFedRAMP
    }
}

public enum CodexOAuthJWT {
    public static func parse(_ token: String) throws -> CodexOAuthJWTClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            parts.allSatisfy({ !$0.isEmpty }),
            let payload = Data(base64URLEncoded: String(parts[1]))
        else {
            throw CodexOAuthError.invalidJWT
        }

        do {
            let claims = try JSONDecoder().decode(JWTClaims.self, from: payload)
            return CodexOAuthJWTClaims(
                accountID: claims.accountID?.nonEmpty ?? claims.auth?.accountID?.nonEmpty,
                email: claims.email?.nonEmpty
                    ?? claims.profile?.email?.nonEmpty
                    ?? claims.openAIProfile?.email?.nonEmpty,
                expiresAt: claims.exp.map { Date(timeIntervalSince1970: $0) },
                isFedRAMP: claims.isFedRAMP ?? claims.auth?.isFedRAMP
            )
        } catch {
            throw CodexOAuthError.invalidJWT
        }
    }

    private struct JWTClaims: Decodable {
        let email: String?
        let exp: TimeInterval?
        let accountID: String?
        let isFedRAMP: Bool?
        let profile: ProfileClaims?
        let openAIProfile: ProfileClaims?
        let auth: AuthClaims?

        private enum CodingKeys: String, CodingKey {
            case email
            case exp
            case accountID = "chatgpt_account_id"
            case isFedRAMP = "chatgpt_account_is_fedramp"
            case profile
            case openAIProfile = "https://api.openai.com/profile"
            case auth = "https://api.openai.com/auth"
        }
    }

    private struct ProfileClaims: Decodable {
        let email: String?
    }

    private struct AuthClaims: Decodable {
        let accountID: String?
        let isFedRAMP: Bool?

        private enum CodingKeys: String, CodingKey {
            case accountID = "chatgpt_account_id"
            case isFedRAMP = "chatgpt_account_is_fedramp"
        }
    }
}

public struct CodexOAuthCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountID: String
    public let email: String?
    public let expiresAt: Date
    public let isFedRAMP: Bool

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        accountID: String,
        email: String?,
        expiresAt: Date,
        isFedRAMP: Bool = false
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.email = email
        self.expiresAt = expiresAt
        self.isFedRAMP = isFedRAMP
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case idToken
        case accountID
        case email
        case expiresAt
        case isFedRAMP
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accessToken: try container.decode(String.self, forKey: .accessToken),
            refreshToken: try container.decodeIfPresent(String.self, forKey: .refreshToken),
            idToken: try container.decodeIfPresent(String.self, forKey: .idToken),
            accountID: try container.decode(String.self, forKey: .accountID),
            email: try container.decodeIfPresent(String.self, forKey: .email),
            expiresAt: try container.decode(Date.self, forKey: .expiresAt),
            isFedRAMP: try container.decodeIfPresent(Bool.self, forKey: .isFedRAMP) ?? false
        )
    }

    public var description: String {
        "CodexOAuthCredential(<redacted>, expiresAt: \(expiresAt))"
    }

    public var debugDescription: String { description }
}

public enum CodexOAuthDisplayState: Equatable, Sendable {
    case signedOut
    case signedIn(email: String?)
    case expired(email: String?)

    public var isSignedIn: Bool {
        if case .signedIn = self {
            return true
        }
        return false
    }

    public var email: String? {
        switch self {
        case .signedOut:
            return nil
        case let .signedIn(email), let .expired(email):
            return email
        }
    }
}

public struct CodexOAuthUpstreamAuthorization: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let accountID: String
    public let isFedRAMP: Bool

    public init(accessToken: String, accountID: String, isFedRAMP: Bool = false) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.isFedRAMP = isFedRAMP
    }

    public var headers: [String: String] {
        var headers = [
            CodexOfficial.authorizationHeader: "Bearer \(accessToken)",
            CodexOfficial.accountIDHeader: accountID,
            CodexOfficial.originatorHeader: CodexOfficial.upstreamOriginator
        ]
        if isFedRAMP {
            headers[CodexOfficial.fedRAMPHeader] = "true"
        }
        return headers
    }

    public var authorizationFingerprint: String {
        codexOfficialAuthorizationFingerprint(forAccountID: accountID)
    }

    public var description: String {
        "CodexOAuthUpstreamAuthorization(<redacted>)"
    }

    public var debugDescription: String { description }
}

public enum CodexOAuthError: Error, Equatable, Sendable, LocalizedError {
    case invalidAuthorizationRequest
    case invalidJWT
    case missingAccessToken
    case missingRefreshToken
    case missingIDToken
    case missingAccountID
    case notLoggedIn
    case loginSuperseded
    case authorizationSuperseded
    case refreshTokenUnavailable
    case invalidTokenResponse
    case tokenRequestFailed(statusCode: Int, code: String?, description: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationRequest:
            return "Unable to create the Codex authorization request."
        case .invalidJWT:
            return "The Codex identity token is invalid."
        case .missingAccessToken:
            return "The Codex token response did not include an access token."
        case .missingRefreshToken:
            return "The Codex token response did not include a refresh token."
        case .missingIDToken:
            return "The Codex token response did not include an identity token."
        case .missingAccountID:
            return "The Codex token response did not include a ChatGPT account ID."
        case .notLoggedIn:
            return "This Codex provider is not logged in."
        case .loginSuperseded:
            return "This Codex login was cancelled because the provider changed. Please try again."
        case .authorizationSuperseded:
            return "The Codex account changed while this request was in progress. Please retry the request."
        case .refreshTokenUnavailable:
            return "The Codex login cannot be refreshed. Please log in again."
        case .invalidTokenResponse:
            return "The Codex token response could not be read."
        case let .tokenRequestFailed(statusCode, code, description):
            let detail = description ?? code
            if let detail, !detail.isEmpty {
                return "Codex authentication failed (HTTP \(statusCode)): \(detail)"
            }
            return "Codex authentication failed (HTTP \(statusCode))."
        }
    }

    public var isPermanentRefreshFailure: Bool {
        guard case let .tokenRequestFailed(statusCode, code, _) = self else {
            return false
        }
        if statusCode == 401 {
            return true
        }
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "invalid_grant",
            "refresh_token_expired",
            "refresh_token_reused",
            "refresh_token_invalidated"
        ].contains(normalizedCode)
    }
}

public protocol CodexOAuthCredentialStore: Sendable {
    func loadCredential(for providerRef: ProviderRef) throws -> CodexOAuthCredential?
    func saveCredential(_ credential: CodexOAuthCredential, for providerRef: ProviderRef) throws
    func deleteCredential(for providerRef: ProviderRef) throws
    func deleteAllCredentials() throws
    func allProviderRefs() throws -> Set<ProviderRef>
}

public struct CodexOAuthKeychainCredentialStore: CodexOAuthCredentialStore, Sendable {
    public static let shared = CodexOAuthKeychainCredentialStore()

    private let service: String

    public init(service: String = "UniGate.CodexOfficialOAuth") {
        self.service = service
    }

    public func loadCredential(for providerRef: ProviderRef) throws -> CodexOAuthCredential? {
        var query = baseQuery(for: providerRef)
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
            throw CodexOAuthError.invalidTokenResponse
        }
        return try JSONDecoder().decode(CodexOAuthCredential.self, from: data)
    }

    public func saveCredential(_ credential: CodexOAuthCredential, for providerRef: ProviderRef) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: providerRef)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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

    public func deleteCredential(for providerRef: ProviderRef) throws {
        let status = SecItemDelete(baseQuery(for: providerRef) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    public func deleteAllCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    public func allProviderRefs() throws -> Set<ProviderRef> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }

        let items: [[String: Any]]
        if let values = result as? [[String: Any]] {
            items = values
        } else if let value = result as? [String: Any] {
            items = [value]
        } else {
            return []
        }
        return Set(items.compactMap { item in
            (item[kSecAttrAccount as String] as? String).flatMap(ProviderRef.init(description:))
        })
    }

    private func baseQuery(for providerRef: ProviderRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerRef.description
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

public struct CodexOAuthTokenResponse: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String?
    public let refreshToken: String?
    public let idToken: String?
    public let tokenType: String?
    public let expiresIn: TimeInterval?

    public init(
        accessToken: String?,
        refreshToken: String?,
        idToken: String?,
        tokenType: String? = nil,
        expiresIn: TimeInterval?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }

    public var description: String {
        "CodexOAuthTokenResponse(<redacted>)"
    }

    public var debugDescription: String { description }
}

public enum CodexOAuthTokenTypeHint: String, Equatable, Sendable {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
}

public protocol CodexOAuthTokenClient: Sendable {
    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> CodexOAuthTokenResponse

    func refreshTokens(refreshToken: String) async throws -> CodexOAuthTokenResponse
    func revokeToken(_ token: String, typeHint: CodexOAuthTokenTypeHint) async throws
}

public struct CodexOAuthHTTPClient: CodexOAuthTokenClient, Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(
            configuration: configuration,
            delegate: CodexOAuthRedirectDelegate(),
            delegateQueue: nil
        )
    }

    init(session: URLSession) {
        self.session = session
    }

    public func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> CodexOAuthTokenResponse {
        try await send(Self.authorizationCodeRequest(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        ))
    }

    public func refreshTokens(refreshToken: String) async throws -> CodexOAuthTokenResponse {
        try await send(try Self.refreshRequest(refreshToken: refreshToken))
    }

    public func revokeToken(_ token: String, typeHint: CodexOAuthTokenTypeHint) async throws {
        try await sendRevocation(try Self.revokeRequest(token: token, typeHint: typeHint))
    }

    static func authorizationCodeRequest(
        code: String,
        codeVerifier: String,
        redirectURI: URL
    ) -> URLRequest {
        tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "client_id": CodexOfficial.clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": codeVerifier
        ])
    }

    static func refreshRequest(refreshToken: String) throws -> URLRequest {
        var request = URLRequest(url: CodexOfficial.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RefreshRequestPayload(
            clientID: CodexOfficial.clientID,
            grantType: "refresh_token",
            refreshToken: refreshToken
        ))
        return request
    }

    static func revokeRequest(
        token: String,
        typeHint: CodexOAuthTokenTypeHint
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/revoke")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RevokeRequestPayload(
            token: token,
            tokenTypeHint: typeHint.rawValue,
            clientID: typeHint == .refreshToken ? CodexOfficial.clientID : nil
        ))
        return request
    }

    static func tokenRequest(parameters: [String: String]) -> URLRequest {
        var request = URLRequest(url: CodexOfficial.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded(parameters).data(using: .utf8)
        return request
    }

    private func send(_ request: URLRequest) async throws -> CodexOAuthTokenResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexOAuthError.invalidTokenResponse
        }
        return try Self.tokenResponse(data: data, statusCode: httpResponse.statusCode)
    }

    private func sendRevocation(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexOAuthError.invalidTokenResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.endpointError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    static func tokenResponse(data: Data, statusCode: Int) throws -> CodexOAuthTokenResponse {
        guard (200..<300).contains(statusCode) else {
            throw endpointError(statusCode: statusCode, data: data)
        }
        let payload: TokenPayload
        do {
            payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        } catch {
            throw CodexOAuthError.invalidTokenResponse
        }
        return CodexOAuthTokenResponse(
            accessToken: payload.accessToken?.nonEmpty,
            refreshToken: payload.refreshToken?.nonEmpty,
            idToken: payload.idToken?.nonEmpty,
            tokenType: payload.tokenType?.nonEmpty,
            expiresIn: payload.expiresIn
        )
    }

    static func isAllowedRedirect(to url: URL?) -> Bool {
        guard
            let url,
            url.user == nil,
            url.password == nil,
            url.scheme?.lowercased() == CodexOfficial.tokenEndpoint.scheme?.lowercased(),
            url.host?.lowercased() == CodexOfficial.tokenEndpoint.host?.lowercased()
        else {
            return false
        }
        return effectivePort(of: url) == effectivePort(of: CodexOfficial.tokenEndpoint)
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }

    private static func endpointError(statusCode: Int, data: Data) -> CodexOAuthError {
        let payload = try? JSONDecoder().decode(TokenErrorPayload.self, from: data)
        return .tokenRequestFailed(
            statusCode: statusCode,
            code: payload?.resolvedCode,
            description: payload?.resolvedDescription
        )
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }

    private struct RefreshRequestPayload: Encodable {
        let clientID: String
        let grantType: String
        let refreshToken: String

        private enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
        }
    }

    private struct RevokeRequestPayload: Encodable {
        let token: String
        let tokenTypeHint: String
        let clientID: String?

        private enum CodingKeys: String, CodingKey {
            case token
            case tokenTypeHint = "token_type_hint"
            case clientID = "client_id"
        }
    }

    private struct TokenPayload: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let tokenType: String?
        let expiresIn: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    private struct TokenErrorPayload: Decodable {
        let error: ErrorValue?
        let code: String?
        let errorDescription: String?

        var resolvedCode: String? {
            code?.nonEmpty ?? error?.code?.nonEmpty ?? error?.text?.nonEmpty
        }

        var resolvedDescription: String? {
            errorDescription?.nonEmpty ?? error?.message?.nonEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case error
            case code
            case errorDescription = "error_description"
        }
    }

    private enum ErrorValue: Decodable {
        case string(String)
        case object(code: String?, message: String?)

        var text: String? {
            if case let .string(value) = self {
                return value
            }
            return nil
        }

        var code: String? {
            if case let .object(code, _) = self {
                return code
            }
            return nil
        }

        var message: String? {
            if case let .object(_, message) = self {
                return message
            }
            return nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            let object = try container.decode(ErrorObject.self)
            self = .object(code: object.code, message: object.message)
        }
    }

    private struct ErrorObject: Decodable {
        let code: String?
        let message: String?
    }
}

private final class CodexOAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(CodexOAuthHTTPClient.isAllowedRedirect(to: request.url) ? request : nil)
    }
}

public actor CodexOAuthManager {
    private struct RefreshFlight {
        let id: UUID
        let generation: UInt64
        let serviceGeneration: UInt64
        let authorizationFingerprint: String
        let task: Task<CodexOAuthCredential, Error>
    }

    private let store: any CodexOAuthCredentialStore
    private let client: any CodexOAuthTokenClient
    private let refreshLeeway: TimeInterval
    private let now: @Sendable () -> Date
    private var refreshTasks: [ProviderRef: RefreshFlight] = [:]
    private var credentialGenerations: [ProviderRef: UInt64] = [:]
    private var loginGenerations: [ProviderRef: UInt64] = [:]
    private var rejectedProviders: Set<ProviderRef> = []
    private var serviceGeneration: UInt64 = 0
    private var providerCatalogGeneration: UInt64 = 0

    public init(
        store: any CodexOAuthCredentialStore = CodexOAuthKeychainCredentialStore.shared,
        client: any CodexOAuthTokenClient = CodexOAuthHTTPClient(),
        refreshLeeway: TimeInterval = CodexOfficial.refreshLeeway,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.client = client
        self.refreshLeeway = refreshLeeway
        self.now = now
    }

    public nonisolated func authorizationFingerprint(for providerRef: ProviderRef) throws -> String? {
        guard let credential = try store.loadCredential(for: providerRef) else {
            return nil
        }
        return codexOfficialAuthorizationFingerprint(forAccountID: credential.accountID)
    }

    @discardableResult
    public func completeLogin(
        for providerRef: ProviderRef,
        code: String,
        pkce: CodexOAuthPKCE,
        redirectURI: URL = CodexOfficial.redirectURI
    ) async throws -> CodexOAuthCredential {
        let loginGeneration = loginGenerations[providerRef, default: 0]
        let loginServiceGeneration = serviceGeneration
        let response = try await client.exchangeAuthorizationCode(
            code,
            codeVerifier: pkce.verifier,
            redirectURI: redirectURI
        )
        guard
            serviceGeneration == loginServiceGeneration,
            loginGenerations[providerRef, default: 0] == loginGeneration
        else {
            throw CodexOAuthError.loginSuperseded
        }
        let credential = try Self.credential(
            from: response,
            previous: nil,
            now: now()
        )
        try store.saveCredential(credential, for: providerRef)
        invalidateRefresh(for: providerRef)
        advanceLoginGeneration(for: providerRef)
        rejectedProviders.remove(providerRef)
        return credential
    }

    public func authorization(
        for providerRef: ProviderRef,
        forceRefresh: Bool = false,
        rejectingAccessToken: String? = nil,
        rejectingAuthorizationFingerprint: String? = nil
    ) async throws -> CodexOAuthUpstreamAuthorization {
        guard var credential = try store.loadCredential(for: providerRef) else {
            throw CodexOAuthError.notLoggedIn
        }
        if rejectedProviders.contains(providerRef) {
            throw CodexOAuthError.refreshTokenUnavailable
        }

        if forceRefresh,
           let rejectingAuthorizationFingerprint,
           rejectingAuthorizationFingerprint != codexOfficialAuthorizationFingerprint(
                forAccountID: credential.accountID
           ) {
            throw CodexOAuthError.authorizationSuperseded
        }

        let tokenWasAlreadyReplaced = forceRefresh
            && rejectingAccessToken.map { $0 != credential.accessToken } == true
        let needsForcedRefresh = forceRefresh && !tokenWasAlreadyReplaced
        let needsProactiveRefresh = credential.expiresAt <= now().addingTimeInterval(refreshLeeway)
        if needsForcedRefresh || needsProactiveRefresh {
            credential = try await refreshedCredential(for: providerRef, current: credential)
        }
        return CodexOAuthUpstreamAuthorization(
            accessToken: credential.accessToken,
            accountID: credential.accountID,
            isFedRAMP: credential.isFedRAMP
        )
    }

    public func status(for providerRef: ProviderRef) async throws -> CodexOAuthDisplayState {
        guard let credential = try store.loadCredential(for: providerRef) else {
            return .signedOut
        }
        if rejectedProviders.contains(providerRef) {
            return .expired(email: credential.email)
        }
        if credential.expiresAt <= now(), credential.refreshToken?.nonEmpty == nil {
            return .expired(email: credential.email)
        }
        return .signedIn(email: credential.email)
    }

    @discardableResult
    public func markExpired(
        for providerRef: ProviderRef,
        rejectingAccessToken: String?,
        rejectingAuthorizationFingerprint: String?
    ) async -> Bool {
        guard
            let rejectingAccessToken,
            let rejectingAuthorizationFingerprint,
            let credential = try? store.loadCredential(for: providerRef),
            credential.accessToken == rejectingAccessToken,
            codexOfficialAuthorizationFingerprint(forAccountID: credential.accountID)
                == rejectingAuthorizationFingerprint
        else {
            return false
        }
        rejectedProviders.insert(providerRef)
        return true
    }

    public func logout(for providerRef: ProviderRef) async throws {
        let credential = try? store.loadCredential(for: providerRef)
        advanceLoginGeneration(for: providerRef)
        invalidateRefresh(for: providerRef)
        rejectedProviders.remove(providerRef)
        try store.deleteCredential(for: providerRef)

        if let refreshToken = credential?.refreshToken?.nonEmpty {
            try? await client.revokeToken(refreshToken, typeHint: .refreshToken)
        } else if let accessToken = credential?.accessToken.nonEmpty {
            try? await client.revokeToken(accessToken, typeHint: .accessToken)
        }
    }

    public func logoutAll() throws {
        serviceGeneration &+= 1
        for flight in refreshTasks.values {
            flight.task.cancel()
        }
        refreshTasks.removeAll()
        credentialGenerations.removeAll()
        loginGenerations.removeAll()
        rejectedProviders.removeAll()
        try store.deleteAllCredentials()
    }

    public func pruneCredentials(
        validProviderRefs: Set<ProviderRef>,
        catalogGeneration: UInt64
    ) throws {
        guard catalogGeneration >= providerCatalogGeneration else {
            return
        }
        providerCatalogGeneration = catalogGeneration
        let staleProviderRefs = try store.allProviderRefs().subtracting(validProviderRefs)
        var revocations: [(token: String, typeHint: CodexOAuthTokenTypeHint)] = []
        for providerRef in staleProviderRefs {
            let credential = try? store.loadCredential(for: providerRef)
            advanceLoginGeneration(for: providerRef)
            invalidateRefresh(for: providerRef)
            rejectedProviders.remove(providerRef)
            try store.deleteCredential(for: providerRef)
            if let refreshToken = credential?.refreshToken?.nonEmpty {
                revocations.append((refreshToken, .refreshToken))
            } else if let accessToken = credential?.accessToken.nonEmpty {
                revocations.append((accessToken, .accessToken))
            }
        }

        if !revocations.isEmpty {
            let client = self.client
            Task {
                for revocation in revocations {
                    try? await client.revokeToken(revocation.token, typeHint: revocation.typeHint)
                }
            }
        }
    }

    private func refreshedCredential(
        for providerRef: ProviderRef,
        current credential: CodexOAuthCredential
    ) async throws -> CodexOAuthCredential {
        if let flight = refreshTasks[providerRef] {
            return try await resolveRefresh(flight, for: providerRef)
        }
        guard let refreshToken = credential.refreshToken?.nonEmpty else {
            throw CodexOAuthError.refreshTokenUnavailable
        }

        let client = self.client
        let now = self.now
        let task = Task<CodexOAuthCredential, Error> {
            let response = try await client.refreshTokens(refreshToken: refreshToken)
            return try Self.credential(
                from: response,
                previous: credential,
                now: now()
            )
        }
        let flight = RefreshFlight(
            id: UUID(),
            generation: credentialGenerations[providerRef, default: 0],
            serviceGeneration: serviceGeneration,
            authorizationFingerprint: codexOfficialAuthorizationFingerprint(
                forAccountID: credential.accountID
            ),
            task: task
        )
        refreshTasks[providerRef] = flight
        return try await resolveRefresh(flight, for: providerRef)
    }

    private func resolveRefresh(
        _ flight: RefreshFlight,
        for providerRef: ProviderRef
    ) async throws -> CodexOAuthCredential {
        do {
            let refreshed = try await flight.task.value
            guard
                serviceGeneration == flight.serviceGeneration,
                credentialGenerations[providerRef, default: 0] == flight.generation
            else {
                guard let current = try store.loadCredential(for: providerRef) else {
                    throw CodexOAuthError.notLoggedIn
                }
                guard
                    serviceGeneration == flight.serviceGeneration,
                    codexOfficialAuthorizationFingerprint(forAccountID: current.accountID)
                        == flight.authorizationFingerprint
                else {
                    throw CodexOAuthError.authorizationSuperseded
                }
                return current
            }
            if let currentFlight = refreshTasks[providerRef], currentFlight.id != flight.id {
                return try await resolveRefresh(currentFlight, for: providerRef)
            }

            try store.saveCredential(refreshed, for: providerRef)
            if refreshTasks[providerRef]?.id == flight.id {
                refreshTasks.removeValue(forKey: providerRef)
            }
            advanceGeneration(for: providerRef)
            rejectedProviders.remove(providerRef)
            return refreshed
        } catch {
            if refreshTasks[providerRef]?.id == flight.id,
               serviceGeneration == flight.serviceGeneration,
               credentialGenerations[providerRef, default: 0] == flight.generation {
                refreshTasks.removeValue(forKey: providerRef)
                if let oauthError = error as? CodexOAuthError,
                   oauthError.isPermanentRefreshFailure {
                    rejectedProviders.insert(providerRef)
                }
            }
            throw error
        }
    }

    private func invalidateRefresh(for providerRef: ProviderRef) {
        refreshTasks.removeValue(forKey: providerRef)?.task.cancel()
        advanceGeneration(for: providerRef)
    }

    private func advanceGeneration(for providerRef: ProviderRef) {
        credentialGenerations[providerRef, default: 0] &+= 1
    }

    private func advanceLoginGeneration(for providerRef: ProviderRef) {
        loginGenerations[providerRef, default: 0] &+= 1
    }

    private static func credential(
        from response: CodexOAuthTokenResponse,
        previous: CodexOAuthCredential?,
        now: Date
    ) throws -> CodexOAuthCredential {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        if let previous {
            accessToken = response.accessToken?.nonEmpty ?? previous.accessToken
            refreshToken = response.refreshToken?.nonEmpty ?? previous.refreshToken
            idToken = response.idToken?.nonEmpty ?? previous.idToken
        } else {
            guard let newAccessToken = response.accessToken?.nonEmpty else {
                throw CodexOAuthError.missingAccessToken
            }
            guard let newRefreshToken = response.refreshToken?.nonEmpty else {
                throw CodexOAuthError.missingRefreshToken
            }
            guard let newIDToken = response.idToken?.nonEmpty else {
                throw CodexOAuthError.missingIDToken
            }
            accessToken = newAccessToken
            refreshToken = newRefreshToken
            idToken = newIDToken
        }

        let idClaims = idToken.flatMap { try? CodexOAuthJWT.parse($0) }
        let accessClaims = try? CodexOAuthJWT.parse(accessToken)
        guard let accountID = idClaims?.accountID ?? accessClaims?.accountID ?? previous?.accountID,
              !accountID.isEmpty else {
            throw CodexOAuthError.missingAccountID
        }

        let expiresAt: Date
        if let expiresIn = response.expiresIn {
            expiresAt = now.addingTimeInterval(expiresIn)
        } else if response.accessToken?.nonEmpty == nil, let previous {
            expiresAt = previous.expiresAt
        } else {
            expiresAt = accessClaims?.expiresAt
                ?? idClaims?.expiresAt
                ?? now.addingTimeInterval(3600)
        }
        return CodexOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            email: idClaims?.email ?? accessClaims?.email ?? previous?.email,
            expiresAt: expiresAt,
            isFedRAMP: idClaims?.isFedRAMP
                ?? accessClaims?.isFedRAMP
                ?? previous?.isFedRAMP
                ?? false
        )
    }
}

private func codexOfficialAuthorizationFingerprint(forAccountID accountID: String) -> String {
    let digest = SHA256.hash(data: Data("codex-official\n\(accountID)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var encoded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: encoded)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
