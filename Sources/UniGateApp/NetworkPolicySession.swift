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

    static func invalidateSharedSessions() {
        systemSession.invalidateAndCancel()
        directSession.invalidateAndCancel()
    }
}
