@testable import UniGateApp
import Foundation
import Testing

struct CodexOfficialCloudflareCookieStorageTests {
    private let officialURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    @Test
    func storesOnlyAllowedCloudflareCookieNames() throws {
        let storage = CodexOfficialCloudflareCookieStorage()
        let allowedNames = [
            "__cf_bm",
            "__cflb",
            "__cfruid",
            "__cfseq",
            "__cfwaitingroom",
            "_cfuvid",
            "cf_clearance",
            "cf_ob_info",
            "cf_use_ob",
            "cf_chl_rc_i"
        ]

        storage.setCookies(
            try allowedNames.map { try cookie(name: $0) },
            for: officialURL,
            mainDocumentURL: nil
        )

        #expect(Set(storage.cookies(for: officialURL)?.map(\.name) ?? []) == Set(allowedNames))
        #expect(Set(storage.cookies?.map(\.name) ?? []) == Set(allowedNames))
    }

    @Test
    func rejectsChatGPTAccountAndSessionCookiesFromMixedInput() throws {
        let storage = CodexOfficialCloudflareCookieStorage()
        let cookies = try [
            cookie(name: "_cfuvid"),
            cookie(name: "__Secure-next-auth.session-token"),
            cookie(name: "chatgpt_session"),
            cookie(name: "oai-auth-token"),
            cookie(name: "not_cf_clearance")
        ]

        storage.setCookies(cookies, for: officialURL, mainDocumentURL: nil)

        #expect(storage.cookies(for: officialURL)?.map(\.name) == ["_cfuvid"])
    }

    @Test
    func acceptsAndReturnsCookiesOnlyForExactHTTPSChatGPTHostAndPort() throws {
        let invalidSources = [
            URL(string: "http://chatgpt.com/backend-api/codex/responses")!,
            URL(string: "https://chatgpt.com:444/backend-api/codex/responses")!,
            URL(string: "https://sub.chatgpt.com/backend-api/codex/responses")!,
            URL(string: "https://api.openai.com/v1/responses")!,
            URL(string: "https://user@chatgpt.com/backend-api/codex/responses")!
        ]

        for sourceURL in invalidSources {
            let storage = CodexOfficialCloudflareCookieStorage()
            storage.setCookies(
                [try cookie(name: "_cfuvid")],
                for: sourceURL,
                mainDocumentURL: nil
            )
            #expect(storage.cookies == nil)
        }

        let storage = CodexOfficialCloudflareCookieStorage()
        storage.setCookies(
            [try cookie(name: "_cfuvid")],
            for: officialURL,
            mainDocumentURL: URL(string: "https://api.openai.com/")
        )
        #expect(storage.cookies == nil)

        storage.setCookies(
            [try cookie(name: "_cfuvid")],
            for: URL(string: "https://chatgpt.com:443/backend-api/codex/responses"),
            mainDocumentURL: nil
        )
        #expect(storage.cookies(for: officialURL)?.map(\.name) == ["_cfuvid"])
        for invalidURL in invalidSources {
            #expect(storage.cookies(for: invalidURL) == nil)
        }
    }

    @Test
    func rejectsCookiesWithUnsafeDomainPathExpiryTransportOrPort() throws {
        let storage = CodexOfficialCloudflareCookieStorage()
        let invalidCookies = try [
            cookie(name: "_cfuvid", domain: "sub.chatgpt.com"),
            cookie(name: "_cfuvid", path: "backend-api"),
            cookie(name: "_cfuvid", secure: false),
            cookie(name: "_cfuvid", expires: Date(timeIntervalSinceNow: -60)),
            cookie(name: "_cfuvid", port: 444)
        ]

        for invalidCookie in invalidCookies {
            storage.setCookie(invalidCookie)
        }
        #expect(storage.cookies == nil)

        storage.setCookie(try cookie(name: "_cfuvid", domain: ".chatgpt.com", port: 443))
        #expect(storage.cookies(for: officialURL)?.map(\.name) == ["_cfuvid"])
    }

    @Test
    func returnsCookiesOnlyWhenTheirPathMatchesTheRequest() throws {
        let storage = CodexOfficialCloudflareCookieStorage()
        storage.setCookie(try cookie(name: "cf_clearance", path: "/backend-api/codex"))

        #expect(storage.cookies(for: officialURL)?.map(\.name) == ["cf_clearance"])
        #expect(storage.cookies(for: URL(string: "https://chatgpt.com/backend-api/codex-v2")!) == nil)
        #expect(storage.cookies(for: URL(string: "https://chatgpt.com/backend-api/other")!) == nil)
    }

    @Test
    func supportsTaskAwareStorageAndRetrieval() async throws {
        let storage = CodexOfficialCloudflareCookieStorage()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: officialURL)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        let cookie = try cookie(name: "__cf_bm")
        storage.storeCookies([cookie], for: task)
        let returnedCookies = await withCheckedContinuation { continuation in
            storage.getCookiesFor(task) { cookies in
                continuation.resume(returning: cookies)
            }
        }

        #expect(returnedCookies?.map(\.name) == ["__cf_bm"])
        storage.deleteCookie(cookie)
        #expect(storage.cookies == nil)

        storage.setCookie(try self.cookie(name: "_cfuvid"))
        storage.removeCookies(since: .distantPast)
        #expect(storage.cookies == nil)
    }

    @Test
    func officialSessionsUseTheProcessGlobalRestrictedCookieStore() {
        let session = NetworkPolicySession.makeCodexOfficialSession(
            for: .system,
            originURL: officialURL
        )
        defer { session.invalidateAndCancel() }

        #expect(session.configuration.httpShouldSetCookies)
        #expect(session.configuration.httpCookieAcceptPolicy == .always)
        #expect(
            session.configuration.httpCookieStorage
                === CodexOfficialCloudflareCookieStorage.processShared
        )
    }

    @Test
    func sameOriginRedirectsRejectURLUserInfo() {
        let delegate = SameOriginRedirectDelegate(originURL: officialURL)

        #expect(delegate.allowsRedirect(to: officialURL))
        #expect(
            !delegate.allowsRedirect(
                to: URL(string: "https://user:secret@chatgpt.com/backend-api/codex/responses")!
            )
        )
    }

    private func cookie(
        name: String,
        domain: String = "chatgpt.com",
        path: String = "/",
        secure: Bool = true,
        expires: Date? = nil,
        port: Int? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "value-\(name)",
            .domain: domain,
            .path: path
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        if let expires {
            properties[.expires] = expires
        }
        if let port {
            properties[.port] = String(port)
        }
        return try #require(HTTPCookie(properties: properties))
    }
}
