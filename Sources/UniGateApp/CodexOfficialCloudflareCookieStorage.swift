import Foundation

// This process-global store must never contain ChatGPT account or session cookies.
final class CodexOfficialCloudflareCookieStorage: HTTPCookieStorage, @unchecked Sendable {
    static let processShared = CodexOfficialCloudflareCookieStorage()

    private static let allowedHost = "chatgpt.com"
    private static let allowedCookieNames: Set<String> = [
        "__cf_bm",
        "__cflb",
        "__cfruid",
        "__cfseq",
        "__cfwaitingroom",
        "_cfuvid",
        "cf_clearance",
        "cf_ob_info",
        "cf_use_ob"
    ]

    private struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String
    }

    private struct StoredCookie {
        let cookie: HTTPCookie
        let storedAt: Date
    }

    private let lock = NSLock()
    private var storedCookies: [CookieKey: StoredCookie] = [:]

    override var cookies: [HTTPCookie]? {
        filteredCookies(for: nil)
    }

    override func setCookie(_ cookie: HTTPCookie) {
        store(cookie, sourceURL: nil)
    }

    override func setCookies(
        _ cookies: [HTTPCookie],
        for URL: URL?,
        mainDocumentURL: URL?
    ) {
        guard let URL, Self.isAllowedURL(URL) else {
            return
        }
        if let mainDocumentURL, !Self.isAllowedURL(mainDocumentURL) {
            return
        }

        for cookie in cookies {
            store(cookie, sourceURL: URL)
        }
    }

    override func storeCookies(_ cookies: [HTTPCookie], for task: URLSessionTask) {
        guard let url = Self.requestURL(for: task) else {
            return
        }
        setCookies(cookies, for: url, mainDocumentURL: nil)
    }

    override func cookies(for URL: URL) -> [HTTPCookie]? {
        guard Self.isAllowedURL(URL) else {
            return nil
        }
        return filteredCookies(for: URL)
    }

    override func getCookiesFor(
        _ task: URLSessionTask,
        completionHandler: @escaping @Sendable ([HTTPCookie]?) -> Void
    ) {
        guard let url = Self.requestURL(for: task) else {
            completionHandler(nil)
            return
        }
        completionHandler(cookies(for: url))
    }

    override func deleteCookie(_ cookie: HTTPCookie) {
        guard let key = Self.key(for: cookie) else {
            return
        }
        _ = lock.withLock {
            storedCookies.removeValue(forKey: key)
        }
    }

    override func removeCookies(since date: Date) {
        lock.withLock {
            storedCookies = storedCookies.filter { _, storedCookie in
                storedCookie.storedAt < date
            }
        }
    }

    private func store(_ cookie: HTTPCookie, sourceURL: URL?) {
        guard let key = Self.key(for: cookie),
              Self.hasAllowedAttributes(cookie),
              sourceURL.map(Self.isAllowedURL) ?? true else {
            return
        }

        let now = Date()
        lock.withLock {
            if Self.isExpired(cookie, at: now) {
                storedCookies.removeValue(forKey: key)
            } else {
                storedCookies[key] = StoredCookie(cookie: cookie, storedAt: now)
            }
        }
    }

    private func filteredCookies(for url: URL?) -> [HTTPCookie]? {
        let now = Date()
        let cookies = lock.withLock {
            storedCookies = storedCookies.filter { _, storedCookie in
                Self.hasAllowedAttributes(storedCookie.cookie)
                    && !Self.isExpired(storedCookie.cookie, at: now)
            }

            return storedCookies.values.compactMap { storedCookie in
                let cookie = storedCookie.cookie
                guard let url else {
                    return cookie
                }
                return Self.path(cookie.path, matches: url.path) ? cookie : nil
            }
        }
        .sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count {
                return lhs.path.count > rhs.path.count
            }
            return lhs.name < rhs.name
        }

        return cookies.isEmpty ? nil : cookies
    }

    private static func key(for cookie: HTTPCookie) -> CookieKey? {
        guard isAllowedCookieName(cookie.name),
              normalizedDomain(cookie.domain) == allowedHost,
              isAllowedPath(cookie.path) else {
            return nil
        }
        return CookieKey(
            name: cookie.name,
            domain: allowedHost,
            path: cookie.path
        )
    }

    private static func hasAllowedAttributes(_ cookie: HTTPCookie) -> Bool {
        guard key(for: cookie) != nil,
              cookie.isSecure else {
            return false
        }

        if let ports = cookie.portList, ports.contains(where: { $0.intValue != 443 }) {
            return false
        }
        return true
    }

    private static func isAllowedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedHost,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return (url.port ?? 443) == 443
    }

    private static func requestURL(for task: URLSessionTask) -> URL? {
        task.currentRequest?.url ?? task.originalRequest?.url
    }

    private static func normalizedDomain(_ domain: String) -> String {
        let lowercased = domain.lowercased()
        return lowercased.hasPrefix(".") ? String(lowercased.dropFirst()) : lowercased
    }

    private static func isAllowedCookieName(_ name: String) -> Bool {
        allowedCookieNames.contains(name) || name.hasPrefix("cf_chl_")
    }

    private static func isAllowedPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else {
            return false
        }
        return !path.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f || scalar == ";"
        }
    }

    private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let requestPath = requestPath.isEmpty ? "/" : requestPath
        if requestPath == cookiePath {
            return true
        }
        guard requestPath.hasPrefix(cookiePath) else {
            return false
        }
        if cookiePath.hasSuffix("/") {
            return true
        }

        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundary < requestPath.endIndex && requestPath[boundary] == "/"
    }

    private static func isExpired(_ cookie: HTTPCookie, at date: Date) -> Bool {
        cookie.expiresDate.map { $0 <= date } ?? false
    }
}
