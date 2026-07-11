import Foundation
import UniGateCore

enum NetworkPolicySession {
    private static let systemSession = URLSession(configuration: .default)
    private static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    static func makeSession(for mode: NetworkPolicyMode) -> URLSession {
        switch mode {
        case .system:
            return systemSession
        case .direct:
            return directSession
        }
    }

    static func makeCodexOfficialSession(for mode: NetworkPolicyMode, originURL: URL) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = CodexOfficialCloudflareCookieStorage.processShared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        if mode == .direct {
            configuration.connectionProxyDictionary = [:]
        }
        return URLSession(
            configuration: configuration,
            delegate: SameOriginRedirectDelegate(originURL: originURL),
            delegateQueue: nil
        )
    }

    static func invalidateSharedSessions() {
        systemSession.invalidateAndCancel()
        directSession.invalidateAndCancel()
    }
}

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: Origin

    init(originURL: URL) {
        self.origin = Origin(url: originURL)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, allowsRedirect(to: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func allowsRedirect(to url: URL) -> Bool {
        url.user == nil
            && url.password == nil
            && Origin(url: url) == origin
    }

    private struct Origin: Equatable {
        let scheme: String?
        let host: String?
        let port: Int?

        init(url: URL) {
            scheme = url.scheme?.lowercased()
            host = url.host?.lowercased()
            if let explicitPort = url.port {
                port = explicitPort
            } else if scheme == "https" {
                port = 443
            } else if scheme == "http" {
                port = 80
            } else {
                port = nil
            }
        }
    }
}
