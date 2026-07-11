@testable import UniGateCore
import Foundation
import Testing

struct CodexOAuthTests {
    @Test
    func backendKindAndOfficialURLsAreStable() throws {
        let data = try JSONEncoder().encode(ProviderBackendKind.codexOfficial)

        #expect(String(decoding: data, as: UTF8.self) == "\"codex_official\"")
        #expect(CodexOfficial.backendBaseURLString == "https://chatgpt.com/backend-api/codex")
        #expect(CodexOfficial.modelDiscoveryClientVersion == "0.144.1")
        #expect(
            CodexOfficial.modelListURL(clientVersion: " 0.142.5 ").absoluteString
                == "https://chatgpt.com/backend-api/codex/models?client_version=0.142.5"
        )
    }

    @Test
    func pkceUsesRFC7636ChallengeAndOfficialEntropySizes() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(
            CodexOAuthPKCE.challenge(for: verifier)
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )

        let login = try CodexOAuthLoginRequest.make()
        #expect(login.pkce.verifier.count == 86)
        #expect(login.state.count == 43)
        #expect(!login.pkce.verifier.contains("="))
        #expect(!login.state.contains("="))
    }

    @Test
    func authorizationURLUsesCurrentOfficialParameters() throws {
        let pkce = CodexOAuthPKCE(verifier: "test-verifier")
        let login = try CodexOAuthLoginRequest(
            state: "test-state",
            pkce: pkce
        )
        let query = queryValues(login.authorizationURL)

        #expect(login.authorizationURL.host == "auth.openai.com")
        #expect(login.authorizationURL.path == "/oauth/authorize")
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == CodexOfficial.clientID)
        #expect(query["redirect_uri"] == CodexOfficial.redirectURI.absoluteString)
        #expect(query["scope"] == "openid profile email offline_access api.connectors.read api.connectors.invoke")
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["id_token_add_organizations"] == "true")
        #expect(query["codex_cli_simplified_flow"] == "true")
        #expect(query["state"] == "test-state")
        #expect(query["originator"] == "codex_cli_rs")
    }

    @Test
    func parsesNamespacedJWTClaimsAndFedRAMPStatus() throws {
        let token = try jwt([
            "exp": 2_000_000_000,
            "https://api.openai.com/profile": ["email": "nested@example.com"],
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-nested",
                "chatgpt_account_is_fedramp": true
            ]
        ])

        let claims = try CodexOAuthJWT.parse(token)

        #expect(claims.accountID == "account-nested")
        #expect(claims.email == "nested@example.com")
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(claims.isFedRAMP == true)
    }

    @Test
    func parsesTopLevelJWTClaimsAndProfileFallback() throws {
        let token = try jwt([
            "chatgpt_account_id": "account-top-level",
            "chatgpt_account_is_fedramp": false,
            "profile": ["email": "profile@example.com"]
        ])

        let claims = try CodexOAuthJWT.parse(token)

        #expect(claims.accountID == "account-top-level")
        #expect(claims.email == "profile@example.com")
        #expect(claims.isFedRAMP == false)
    }

    @Test
    func rejectsMalformedJWT() {
        #expect(throws: CodexOAuthError.invalidJWT) {
            try CodexOAuthJWT.parse("not-a-jwt")
        }
    }

    @Test
    func buildsFormExchangeAndJSONRefreshRequests() throws {
        let exchange = CodexOAuthHTTPClient.authorizationCodeRequest(
            code: "code with spaces",
            codeVerifier: "verifier/value",
            redirectURI: CodexOfficial.redirectURI
        )
        let exchangeForm = formValues(exchange)

        #expect(exchange.httpMethod == "POST")
        #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(exchangeForm == [
            "client_id": CodexOfficial.clientID,
            "code": "code with spaces",
            "code_verifier": "verifier/value",
            "grant_type": "authorization_code",
            "redirect_uri": CodexOfficial.redirectURI.absoluteString
        ])

        let refresh = try CodexOAuthHTTPClient.refreshRequest(refreshToken: "rotating-token")
        let refreshBody = try #require(refresh.httpBody)
        let refreshObject = try #require(
            JSONSerialization.jsonObject(with: refreshBody) as? [String: String]
        )
        #expect(refresh.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(refreshObject == [
            "client_id": CodexOfficial.clientID,
            "grant_type": "refresh_token",
            "refresh_token": "rotating-token"
        ])
    }

    @Test
    func buildsOfficialRefreshAndAccessTokenRevocationRequests() throws {
        let refresh = try CodexOAuthHTTPClient.revokeRequest(
            token: "refresh-token",
            typeHint: .refreshToken
        )
        let refreshBody = try #require(refresh.httpBody)
        let refreshObject = try #require(
            JSONSerialization.jsonObject(with: refreshBody) as? [String: String]
        )

        #expect(refresh.url?.absoluteString == "https://auth.openai.com/oauth/revoke")
        #expect(refresh.httpMethod == "POST")
        #expect(refresh.timeoutInterval == 10)
        #expect(refresh.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(refreshObject == [
            "token": "refresh-token",
            "token_type_hint": "refresh_token",
            "client_id": CodexOfficial.clientID
        ])

        let access = try CodexOAuthHTTPClient.revokeRequest(
            token: "access-token",
            typeHint: .accessToken
        )
        let accessBody = try #require(access.httpBody)
        let accessObject = try #require(
            JSONSerialization.jsonObject(with: accessBody) as? [String: String]
        )
        #expect(accessObject == [
            "token": "access-token",
            "token_type_hint": "access_token"
        ])
    }

    @Test
    func tokenResponseAllowsPartialRefreshAndClassifiesPermanentErrors() throws {
        let response = try CodexOAuthHTTPClient.tokenResponse(
            data: Data("{\"refresh_token\":\"new-refresh\"}".utf8),
            statusCode: 200
        )
        #expect(response.accessToken == nil)
        #expect(response.refreshToken == "new-refresh")
        #expect(response.idToken == nil)

        #expect(throws: CodexOAuthError.tokenRequestFailed(
            statusCode: 400,
            code: "refresh_token_reused",
            description: "already used"
        )) {
            try CodexOAuthHTTPClient.tokenResponse(
                data: Data("""
                {"error":{"code":"refresh_token_reused","message":"already used"}}
                """.utf8),
                statusCode: 400
            )
        }
        #expect(CodexOAuthError.tokenRequestFailed(
            statusCode: 400,
            code: "invalid_grant",
            description: nil
        ).isPermanentRefreshFailure)
        #expect(CodexOAuthError.tokenRequestFailed(
            statusCode: 401,
            code: nil,
            description: nil
        ).isPermanentRefreshFailure)
        #expect(!CodexOAuthError.tokenRequestFailed(
            statusCode: 500,
            code: "server_error",
            description: nil
        ).isPermanentRefreshFailure)
    }

    @Test
    func credentialDescriptionsRedactSecrets() {
        let credential = CodexOAuthCredential(
            accessToken: "secret-access",
            refreshToken: "secret-refresh",
            idToken: "secret-id",
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: .distantFuture
        )
        let tokenResponse = CodexOAuthTokenResponse(
            accessToken: "secret-access",
            refreshToken: "secret-refresh",
            idToken: "secret-id",
            expiresIn: 3600
        )
        let authorization = CodexOAuthUpstreamAuthorization(
            accessToken: "secret-access",
            accountID: "account-1"
        )

        for value in [String(describing: credential), String(reflecting: credential)] {
            #expect(!value.contains("secret-access"))
            #expect(!value.contains("secret-refresh"))
            #expect(!value.contains("secret-id"))
        }
        #expect(!String(describing: tokenResponse).contains("secret-access"))
        #expect(!String(describing: authorization).contains("secret-access"))
    }

    @Test
    func rejectsCrossOriginTokenRedirects() {
        #expect(CodexOAuthHTTPClient.isAllowedRedirect(
            to: URL(string: "https://auth.openai.com/oauth/token-next")
        ))
        #expect(!CodexOAuthHTTPClient.isAllowedRedirect(
            to: URL(string: "https://example.com/oauth/token")
        ))
        #expect(!CodexOAuthHTTPClient.isAllowedRedirect(
            to: URL(string: "http://auth.openai.com/oauth/token")
        ))
        #expect(!CodexOAuthHTTPClient.isAllowedRedirect(
            to: URL(string: "https://auth.openai.com:444/oauth/token")
        ))
        #expect(!CodexOAuthHTTPClient.isAllowedRedirect(
            to: URL(string: "https://user@auth.openai.com/oauth/token")
        ))
    }

    @Test
    func completeLoginPersistsIdentityAndBuildsFedRAMPHeaders() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let idToken = try jwt([
            "email": "user@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-1",
                "chatgpt_account_is_fedramp": true
            ]
        ])
        let accessToken = try jwt(["exp": 1_900_003_600])
        let response = CodexOAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: "refresh-1",
            idToken: idToken,
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore()
        let client = MockCodexOAuthTokenClient(exchangeResponse: response, refreshResponse: response)
        let manager = CodexOAuthManager(store: store, client: client, now: { now })

        let credential = try await manager.completeLogin(
            for: providerRef,
            code: "authorization-code",
            pkce: CodexOAuthPKCE(verifier: "verifier")
        )
        let authorization = try await manager.authorization(for: providerRef)

        #expect(credential.accountID == "account-1")
        #expect(credential.email == "user@example.com")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_900_003_600))
        #expect(credential.isFedRAMP)
        #expect(authorization.headers[CodexOfficial.authorizationHeader] == "Bearer \(accessToken)")
        #expect(authorization.headers[CodexOfficial.accountIDHeader] == "account-1")
        #expect(authorization.headers[CodexOfficial.originatorHeader] == "codex_cli_rs")
        #expect(authorization.headers[CodexOfficial.fedRAMPHeader] == "true")
        #expect(CodexOAuthUpstreamAuthorization(
            accessToken: "access",
            accountID: "account-2"
        ).headers[CodexOfficial.fedRAMPHeader] == nil)
        #expect(try store.loadCredential(for: providerRef) == credential)
    }

    @Test
    func authorizationFingerprintBindsToAccountWithoutExposingIdentityOrTokens() throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let credential = CodexOAuthCredential(
            accessToken: "secret-access-token",
            refreshToken: "secret-refresh-token",
            idToken: nil,
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: .distantFuture
        )
        let manager = CodexOAuthManager(
            store: MemoryCodexOAuthCredentialStore([providerRef: credential]),
            client: MockCodexOAuthTokenClient(exchangeResponse: .empty, refreshResponse: .empty)
        )

        let fingerprint = try #require(try manager.authorizationFingerprint(for: providerRef))

        #expect(fingerprint == "4054d6a4e46c0a4b2607dc1d91823be73be7df83fd8ad6f9a90a4b1f3608e31b")
        #expect(fingerprint == CodexOAuthUpstreamAuthorization(
            accessToken: "different-token",
            accountID: "account-1"
        ).authorizationFingerprint)
        #expect(fingerprint != CodexOAuthUpstreamAuthorization(
            accessToken: "different-token",
            accountID: "account-2"
        ).authorizationFingerprint)
        #expect(!fingerprint.contains("account-1"))
        #expect(!fingerprint.contains("secret"))
    }

    @Test
    func authorizationFingerprintIsNilWithoutStoredCredential() throws {
        let manager = CodexOAuthManager(
            store: MemoryCodexOAuthCredentialStore(),
            client: MockCodexOAuthTokenClient(exchangeResponse: .empty, refreshResponse: .empty)
        )

        #expect(try manager.authorizationFingerprint(
            for: ProviderRef(appType: "codex", id: "official")
        ) == nil)
    }

    @Test
    func completeLoginRequiresAllOfficialTokenFields() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let idToken = try jwt([
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-1"]
        ])
        let response = CodexOAuthTokenResponse(
            accessToken: "access",
            refreshToken: nil,
            idToken: idToken,
            expiresIn: 3600
        )
        let manager = CodexOAuthManager(
            store: MemoryCodexOAuthCredentialStore(),
            client: MockCodexOAuthTokenClient(exchangeResponse: response, refreshResponse: response)
        )

        await #expect(throws: CodexOAuthError.missingRefreshToken) {
            try await manager.completeLogin(
                for: providerRef,
                code: "authorization-code",
                pkce: CodexOAuthPKCE(verifier: "verifier")
            )
        }
    }

    @Test
    func refreshIsSingleFlightAndPersistsRotatedToken() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let idToken = try jwt([
            "email": "user@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-1"]
        ])
        let oldCredential = CodexOAuthCredential(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: idToken,
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: now.addingTimeInterval(-1)
        )
        let newAccessToken = try jwt(["exp": 1_900_007_200])
        let refreshResponse = CodexOAuthTokenResponse(
            accessToken: newAccessToken,
            refreshToken: "rotated-refresh",
            idToken: nil,
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: oldCredential])
        let client = MockCodexOAuthTokenClient(
            exchangeResponse: refreshResponse,
            refreshResponse: refreshResponse,
            refreshDelay: .milliseconds(100)
        )
        let manager = CodexOAuthManager(store: store, client: client, now: { now })

        let authorizations = try await withThrowingTaskGroup(
            of: CodexOAuthUpstreamAuthorization.self,
            returning: [CodexOAuthUpstreamAuthorization].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await manager.authorization(for: providerRef)
                }
            }
            var values: [CodexOAuthUpstreamAuthorization] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(authorizations.count == 8)
        #expect(authorizations.allSatisfy { $0.accessToken == newAccessToken })
        #expect(await client.refreshCallCount() == 1)
        let loaded = try store.loadCredential(for: providerRef)
        let persisted = try #require(loaded)
        #expect(persisted.refreshToken == "rotated-refresh")
        #expect(persisted.idToken == idToken)
        #expect(persisted.expiresAt == Date(timeIntervalSince1970: 1_900_007_200))
    }

    @Test
    func lateUnauthorizedResponsesDoNotRotateAnAlreadyRefreshedTokenAgain() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let oldCredential = CodexOAuthCredential(
            accessToken: "rejected-access",
            refreshToken: "old-refresh",
            idToken: try jwt([
                "email": "user@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "account-1"]
            ]),
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: now.addingTimeInterval(3600)
        )
        let newAccessToken = try jwt(["exp": 1_900_007_200])
        let refreshResponse = CodexOAuthTokenResponse(
            accessToken: newAccessToken,
            refreshToken: "rotated-refresh",
            idToken: nil,
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: oldCredential])
        let client = MockCodexOAuthTokenClient(
            exchangeResponse: refreshResponse,
            refreshResponse: refreshResponse
        )
        let manager = CodexOAuthManager(store: store, client: client, now: { now })

        _ = try await manager.authorization(
            for: providerRef,
            forceRefresh: true,
            rejectingAccessToken: "rejected-access"
        )
        let lateAuthorizations = try await withThrowingTaskGroup(
            of: CodexOAuthUpstreamAuthorization.self,
            returning: [CodexOAuthUpstreamAuthorization].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await manager.authorization(
                        for: providerRef,
                        forceRefresh: true,
                        rejectingAccessToken: "rejected-access"
                    )
                }
            }
            var values: [CodexOAuthUpstreamAuthorization] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(lateAuthorizations.count == 8)
        #expect(lateAuthorizations.allSatisfy { $0.accessToken == newAccessToken })
        #expect(await client.refreshCallCount() == 1)
    }

    @Test
    func partialRefreshPreservesExistingTokenChain() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let credential = CodexOAuthCredential(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: try jwt([
                "email": "user@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "account-1"]
            ]),
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: now.addingTimeInterval(120)
        )
        let response = CodexOAuthTokenResponse(
            accessToken: nil,
            refreshToken: "rotated-refresh",
            idToken: nil,
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: credential])
        let manager = CodexOAuthManager(
            store: store,
            client: MockCodexOAuthTokenClient(exchangeResponse: response, refreshResponse: response),
            now: { now }
        )

        let authorization = try await manager.authorization(for: providerRef, forceRefresh: true)
        let loaded = try store.loadCredential(for: providerRef)
        let persisted = try #require(loaded)

        #expect(authorization.accessToken == "old-access")
        #expect(persisted.refreshToken == "rotated-refresh")
        #expect(persisted.idToken == credential.idToken)
        #expect(persisted.expiresAt == credential.expiresAt)
    }

    @Test
    func staleRefreshCannotOverwriteConcurrentRelogin() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let oldCredential = CodexOAuthCredential(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: try jwt([
                "email": "old@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "old-account"]
            ]),
            accountID: "old-account",
            email: "old@example.com",
            expiresAt: .distantPast
        )
        let staleRefresh = CodexOAuthTokenResponse(
            accessToken: try jwt(["exp": 1_900_003_600]),
            refreshToken: "stale-rotated-refresh",
            idToken: try jwt([
                "email": "old@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "old-account"]
            ]),
            expiresIn: nil
        )
        let newAccessToken = try jwt(["exp": 1_900_007_200])
        let newIDToken = try jwt([
            "email": "new@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "new-account"]
        ])
        let newLogin = CodexOAuthTokenResponse(
            accessToken: newAccessToken,
            refreshToken: "new-refresh",
            idToken: newIDToken,
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: oldCredential])
        let client = ControlledRefreshTokenClient(
            exchangeResponse: newLogin,
            refreshResponse: staleRefresh
        )
        let manager = CodexOAuthManager(store: store, client: client, now: { now })

        let pendingRefresh = Task {
            try await manager.authorization(for: providerRef)
        }
        while !(await client.hasStartedRefresh()) {
            await Task.yield()
        }

        _ = try await manager.completeLogin(
            for: providerRef,
            code: "new-authorization-code",
            pkce: CodexOAuthPKCE(verifier: "new-verifier")
        )
        await client.resumeRefresh()
        await #expect(throws: CodexOAuthError.authorizationSuperseded) {
            try await pendingRefresh.value
        }

        let loaded = try store.loadCredential(for: providerRef)
        let persisted = try #require(loaded)
        #expect(persisted.accessToken == newAccessToken)
        #expect(persisted.refreshToken == "new-refresh")
        #expect(persisted.accountID == "new-account")
        #expect(persisted.email == "new@example.com")
        #expect(try await manager.status(for: providerRef) == .signedIn(email: "new@example.com"))
    }

    @Test
    func unauthorizedRetryDoesNotReplayAcrossAccounts() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let currentCredential = CodexOAuthCredential(
            accessToken: "account-b-access",
            refreshToken: "account-b-refresh",
            idToken: nil,
            accountID: "account-b",
            email: "b@example.com",
            expiresAt: .distantFuture
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: currentCredential])
        let client = MockCodexOAuthTokenClient(
            exchangeResponse: .empty,
            refreshResponse: .empty
        )
        let manager = CodexOAuthManager(store: store, client: client)

        await #expect(throws: CodexOAuthError.authorizationSuperseded) {
            try await manager.authorization(
                for: providerRef,
                forceRefresh: true,
                rejectingAccessToken: "account-a-access",
                rejectingAuthorizationFingerprint: CodexOAuthUpstreamAuthorization(
                    accessToken: "account-a-access",
                    accountID: "account-a"
                ).authorizationFingerprint
            )
        }
        #expect(await client.refreshCallCount() == 0)
        #expect(try store.loadCredential(for: providerRef) == currentCredential)
    }

    @Test
    func logoutPreventsPendingLoginFromRecreatingCredential() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let response = CodexOAuthTokenResponse(
            accessToken: try jwt(["exp": 1_900_003_600]),
            refreshToken: "new-refresh",
            idToken: try jwt([
                "email": "new@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "new-account"]
            ]),
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore()
        let client = ControlledExchangeTokenClient(response: response)
        let manager = CodexOAuthManager(store: store, client: client)

        let pendingLogin = Task {
            try await manager.completeLogin(
                for: providerRef,
                code: "authorization-code",
                pkce: CodexOAuthPKCE(verifier: "verifier")
            )
        }
        while !(await client.hasStartedExchange()) {
            await Task.yield()
        }

        try await manager.logout(for: providerRef)
        await client.resumeExchange()

        await #expect(throws: CodexOAuthError.loginSuperseded) {
            try await pendingLogin.value
        }
        #expect(try store.loadCredential(for: providerRef) == nil)
        #expect(try await manager.status(for: providerRef) == .signedOut)
    }

    @Test
    func logoutDeletesLocallyBeforeBestEffortRefreshTokenRevocation() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let credential = CodexOAuthCredential(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: .distantFuture
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: credential])
        let client = ControlledRevocationTokenClient(revokeError: .offline)
        let manager = CodexOAuthManager(store: store, client: client)

        let pendingLogout = Task {
            try await manager.logout(for: providerRef)
        }
        while !(await client.hasStartedRevocation()) {
            await Task.yield()
        }

        #expect(try store.loadCredential(for: providerRef) == nil)
        #expect(await client.revocations() == [
            RevocationCall(token: "refresh-token", typeHint: .refreshToken)
        ])

        await client.resumeRevocation()
        try await pendingLogout.value
        #expect(try await manager.status(for: providerRef) == .signedOut)
    }

    @Test
    func logoutFallsBackToAccessTokenRevocation() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let credential = CodexOAuthCredential(
            accessToken: "access-token",
            refreshToken: nil,
            idToken: nil,
            accountID: "account-1",
            email: nil,
            expiresAt: .distantFuture
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: credential])
        let client = MockCodexOAuthTokenClient(
            exchangeResponse: .empty,
            refreshResponse: .empty
        )
        let manager = CodexOAuthManager(store: store, client: client)

        try await manager.logout(for: providerRef)

        #expect(await client.revocations() == [
            RevocationCall(token: "access-token", typeHint: .accessToken)
        ])
        #expect(try store.loadCredential(for: providerRef) == nil)
    }

    @Test
    func logoutAllDeletesTheEntireCredentialService() async throws {
        let firstRef = ProviderRef(appType: "codex", id: "official-a")
        let secondRef = ProviderRef(appType: "codex", id: "official-b")
        let credential = CodexOAuthCredential(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountID: "account-1",
            email: nil,
            expiresAt: .distantFuture
        )
        let store = MemoryCodexOAuthCredentialStore([
            firstRef: credential,
            secondRef: credential
        ])
        let client = MockCodexOAuthTokenClient(
            exchangeResponse: .empty,
            refreshResponse: .empty
        )
        let manager = CodexOAuthManager(store: store, client: client)

        try await manager.logoutAll()

        #expect(try store.loadCredential(for: firstRef) == nil)
        #expect(try store.loadCredential(for: secondRef) == nil)
        #expect(store.deleteAllCallCount() == 1)
        #expect(await client.revocations().isEmpty)
    }

    @Test
    func providerCatalogPruningDeletesOrphansAndIgnoresOlderSnapshots() async throws {
        let retainedRef = ProviderRef(appType: "codex", id: "retained")
        let removedRef = ProviderRef(appType: "codex", id: "removed")
        let credential = CodexOAuthCredential(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountID: "account-1",
            email: nil,
            expiresAt: .distantFuture
        )
        let store = MemoryCodexOAuthCredentialStore([
            retainedRef: credential,
            removedRef: credential
        ])
        let manager = CodexOAuthManager(
            store: store,
            client: MockCodexOAuthTokenClient(
                exchangeResponse: .empty,
                refreshResponse: .empty
            )
        )

        try await manager.pruneCredentials(
            validProviderRefs: [retainedRef],
            catalogGeneration: 2
        )
        #expect(try store.loadCredential(for: retainedRef) == credential)
        #expect(try store.loadCredential(for: removedRef) == nil)

        try store.saveCredential(credential, for: removedRef)
        try await manager.pruneCredentials(
            validProviderRefs: [retainedRef],
            catalogGeneration: 1
        )
        #expect(try store.loadCredential(for: removedRef) == credential)
    }

    @Test
    func logoutAllPreventsPendingLoginFromRecreatingCredential() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let response = CodexOAuthTokenResponse(
            accessToken: try jwt(["exp": 1_900_003_600]),
            refreshToken: "new-refresh",
            idToken: try jwt([
                "https://api.openai.com/auth": ["chatgpt_account_id": "new-account"]
            ]),
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore()
        let client = ControlledExchangeTokenClient(response: response)
        let manager = CodexOAuthManager(store: store, client: client)

        let pendingLogin = Task {
            try await manager.completeLogin(
                for: providerRef,
                code: "authorization-code",
                pkce: CodexOAuthPKCE(verifier: "verifier")
            )
        }
        while !(await client.hasStartedExchange()) {
            await Task.yield()
        }

        try await manager.logoutAll()
        await client.resumeExchange()

        await #expect(throws: CodexOAuthError.loginSuperseded) {
            try await pendingLogin.value
        }
        #expect(try store.loadCredential(for: providerRef) == nil)
    }

    @Test
    func logoutAllPreventsPendingRefreshFromRecreatingCredential() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let oldCredential = CodexOAuthCredential(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: nil,
            accountID: "account-1",
            email: nil,
            expiresAt: .distantPast
        )
        let refreshResponse = CodexOAuthTokenResponse(
            accessToken: try jwt(["exp": 1_900_003_600]),
            refreshToken: "rotated-refresh",
            idToken: nil,
            expiresIn: nil
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: oldCredential])
        let client = ControlledRefreshTokenClient(
            exchangeResponse: .empty,
            refreshResponse: refreshResponse
        )
        let manager = CodexOAuthManager(store: store, client: client)

        let pendingRefresh = Task {
            try await manager.authorization(for: providerRef)
        }
        while !(await client.hasStartedRefresh()) {
            await Task.yield()
        }

        try await manager.logoutAll()
        await client.resumeRefresh()

        await #expect(throws: CodexOAuthError.notLoggedIn) {
            try await pendingRefresh.value
        }
        #expect(try store.loadCredential(for: providerRef) == nil)
    }

    @Test
    func permanentRefreshFailureMarksProviderExpired() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let credential = CodexOAuthCredential(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: nil,
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: .distantPast
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: credential])
        let error = CodexOAuthError.tokenRequestFailed(
            statusCode: 400,
            code: "invalid_grant",
            description: "refresh rejected"
        )
        let client = MockCodexOAuthTokenClient(
            exchangeResponse: .empty,
            refreshResult: .failure(error)
        )
        let manager = CodexOAuthManager(store: store, client: client)

        await #expect(throws: error) {
            try await manager.authorization(for: providerRef)
        }
        #expect(try await manager.status(for: providerRef) == .expired(email: "user@example.com"))
        await #expect(throws: CodexOAuthError.refreshTokenUnavailable) {
            try await manager.authorization(for: providerRef)
        }
    }

    @Test
    func markExpiredAndLogoutUpdateDisplayStatusWithoutTouchingOtherStores() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let credential = CodexOAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountID: "account-1",
            email: "user@example.com",
            expiresAt: .distantFuture
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: credential])
        let manager = CodexOAuthManager(
            store: store,
            client: MockCodexOAuthTokenClient(exchangeResponse: .empty, refreshResponse: .empty)
        )

        #expect(try await manager.status(for: providerRef) == .signedIn(email: "user@example.com"))
        let authorization = try await manager.authorization(for: providerRef)
        #expect(await manager.markExpired(
            for: providerRef,
            rejectingAccessToken: authorization.accessToken,
            rejectingAuthorizationFingerprint: authorization.authorizationFingerprint
        ))
        #expect(try await manager.status(for: providerRef) == .expired(email: "user@example.com"))
        try await manager.logout(for: providerRef)
        #expect(try await manager.status(for: providerRef) == .signedOut)
        #expect(try store.loadCredential(for: providerRef) == nil)
    }

    @Test
    func staleUnauthorizedResponseCannotExpireReplacementAccount() async throws {
        let providerRef = ProviderRef(appType: "codex", id: "official")
        let accountA = CodexOAuthCredential(
            accessToken: "account-a-access",
            refreshToken: "account-a-refresh",
            idToken: nil,
            accountID: "account-a",
            email: "a@example.com",
            expiresAt: .distantFuture
        )
        let accountB = CodexOAuthCredential(
            accessToken: "account-b-access",
            refreshToken: "account-b-refresh",
            idToken: nil,
            accountID: "account-b",
            email: "b@example.com",
            expiresAt: .distantFuture
        )
        let store = MemoryCodexOAuthCredentialStore([providerRef: accountA])
        let manager = CodexOAuthManager(
            store: store,
            client: MockCodexOAuthTokenClient(exchangeResponse: .empty, refreshResponse: .empty)
        )
        let rejectedAuthorization = try await manager.authorization(for: providerRef)
        try store.saveCredential(accountB, for: providerRef)

        #expect(!(await manager.markExpired(
            for: providerRef,
            rejectingAccessToken: rejectedAuthorization.accessToken,
            rejectingAuthorizationFingerprint: rejectedAuthorization.authorizationFingerprint
        )))
        #expect(try await manager.status(for: providerRef) == .signedIn(email: "b@example.com"))
    }
}

private final class MemoryCodexOAuthCredentialStore: CodexOAuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [ProviderRef: CodexOAuthCredential]
    private var deleteAllCalls = 0

    init(_ credentials: [ProviderRef: CodexOAuthCredential] = [:]) {
        self.credentials = credentials
    }

    func loadCredential(for providerRef: ProviderRef) throws -> CodexOAuthCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credentials[providerRef]
    }

    func saveCredential(_ credential: CodexOAuthCredential, for providerRef: ProviderRef) throws {
        lock.lock()
        defer { lock.unlock() }
        credentials[providerRef] = credential
    }

    func deleteCredential(for providerRef: ProviderRef) throws {
        lock.lock()
        defer { lock.unlock() }
        credentials.removeValue(forKey: providerRef)
    }

    func deleteAllCredentials() throws {
        lock.lock()
        defer { lock.unlock() }
        credentials.removeAll()
        deleteAllCalls += 1
    }

    func allProviderRefs() throws -> Set<ProviderRef> {
        lock.lock()
        defer { lock.unlock() }
        return Set(credentials.keys)
    }

    func deleteAllCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deleteAllCalls
    }
}

private struct RevocationCall: Equatable, Sendable {
    let token: String
    let typeHint: CodexOAuthTokenTypeHint
}

private enum TestRevocationError: Error, Sendable {
    case offline
}

private actor MockCodexOAuthTokenClient: CodexOAuthTokenClient {
    private let exchangeResponse: CodexOAuthTokenResponse
    private let refreshResult: Result<CodexOAuthTokenResponse, CodexOAuthError>
    private let refreshDelay: Duration?
    private var refreshCalls = 0
    private var revokeCalls: [RevocationCall] = []

    init(
        exchangeResponse: CodexOAuthTokenResponse,
        refreshResponse: CodexOAuthTokenResponse,
        refreshDelay: Duration? = nil
    ) {
        self.exchangeResponse = exchangeResponse
        self.refreshResult = .success(refreshResponse)
        self.refreshDelay = refreshDelay
    }

    init(
        exchangeResponse: CodexOAuthTokenResponse,
        refreshResult: Result<CodexOAuthTokenResponse, CodexOAuthError>,
        refreshDelay: Duration? = nil
    ) {
        self.exchangeResponse = exchangeResponse
        self.refreshResult = refreshResult
        self.refreshDelay = refreshDelay
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> CodexOAuthTokenResponse {
        exchangeResponse
    }

    func refreshTokens(refreshToken: String) async throws -> CodexOAuthTokenResponse {
        refreshCalls += 1
        if let refreshDelay {
            try await Task.sleep(for: refreshDelay)
        }
        return try refreshResult.get()
    }

    func refreshCallCount() -> Int {
        refreshCalls
    }

    func revokeToken(_ token: String, typeHint: CodexOAuthTokenTypeHint) async throws {
        revokeCalls.append(RevocationCall(token: token, typeHint: typeHint))
    }

    func revocations() -> [RevocationCall] {
        revokeCalls
    }
}

private actor ControlledRefreshTokenClient: CodexOAuthTokenClient {
    private let exchangeResponse: CodexOAuthTokenResponse
    private let refreshResponse: CodexOAuthTokenResponse
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var refreshStarted = false

    init(
        exchangeResponse: CodexOAuthTokenResponse,
        refreshResponse: CodexOAuthTokenResponse
    ) {
        self.exchangeResponse = exchangeResponse
        self.refreshResponse = refreshResponse
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> CodexOAuthTokenResponse {
        exchangeResponse
    }

    func refreshTokens(refreshToken: String) async throws -> CodexOAuthTokenResponse {
        refreshStarted = true
        await withCheckedContinuation { continuation in
            refreshContinuation = continuation
        }
        return refreshResponse
    }

    func revokeToken(_ token: String, typeHint: CodexOAuthTokenTypeHint) async throws {}

    func hasStartedRefresh() -> Bool {
        refreshStarted
    }

    func resumeRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }
}

private actor ControlledExchangeTokenClient: CodexOAuthTokenClient {
    private let response: CodexOAuthTokenResponse
    private var exchangeContinuation: CheckedContinuation<Void, Never>?
    private var exchangeStarted = false

    init(response: CodexOAuthTokenResponse) {
        self.response = response
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> CodexOAuthTokenResponse {
        exchangeStarted = true
        await withCheckedContinuation { continuation in
            exchangeContinuation = continuation
        }
        return response
    }

    func refreshTokens(refreshToken: String) async throws -> CodexOAuthTokenResponse {
        response
    }

    func revokeToken(_ token: String, typeHint: CodexOAuthTokenTypeHint) async throws {}

    func hasStartedExchange() -> Bool {
        exchangeStarted
    }

    func resumeExchange() {
        exchangeContinuation?.resume()
        exchangeContinuation = nil
    }
}

private actor ControlledRevocationTokenClient: CodexOAuthTokenClient {
    private let revokeError: TestRevocationError?
    private var revokeContinuation: CheckedContinuation<Void, Never>?
    private var revokeCalls: [RevocationCall] = []

    init(revokeError: TestRevocationError? = nil) {
        self.revokeError = revokeError
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> CodexOAuthTokenResponse {
        .empty
    }

    func refreshTokens(refreshToken: String) async throws -> CodexOAuthTokenResponse {
        .empty
    }

    func revokeToken(_ token: String, typeHint: CodexOAuthTokenTypeHint) async throws {
        revokeCalls.append(RevocationCall(token: token, typeHint: typeHint))
        await withCheckedContinuation { continuation in
            revokeContinuation = continuation
        }
        if let revokeError {
            throw revokeError
        }
    }

    func hasStartedRevocation() -> Bool {
        !revokeCalls.isEmpty
    }

    func revocations() -> [RevocationCall] {
        revokeCalls
    }

    func resumeRevocation() {
        revokeContinuation?.resume()
        revokeContinuation = nil
    }
}

private extension CodexOAuthTokenResponse {
    static let empty = CodexOAuthTokenResponse(
        accessToken: nil,
        refreshToken: nil,
        idToken: nil,
        expiresIn: nil
    )
}

private func queryValues(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )?.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private func formValues(_ request: URLRequest) -> [String: String] {
    guard
        let body = request.httpBody,
        let text = String(data: body, encoding: .utf8),
        let url = URL(string: "https://localhost/?\(text)")
    else {
        return [:]
    }
    return queryValues(url)
}

private func jwt(_ claims: [String: Any]) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    return "e30.\(base64URL(payload)).signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
