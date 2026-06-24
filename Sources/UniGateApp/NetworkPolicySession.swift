import Foundation
import UniGateCore

enum NetworkPolicySession {
    static func makeSession(for mode: NetworkPolicyMode) -> URLSession {
        let configuration = URLSessionConfiguration.default
        switch mode {
        case .system:
            return URLSession(configuration: configuration)
        case .direct:
            configuration.connectionProxyDictionary = [:]
            return URLSession(configuration: configuration)
        }
    }
}
