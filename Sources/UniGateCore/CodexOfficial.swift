import Foundation

public enum ProviderBackendKind: String, Codable, Hashable, Sendable {
    case standard
    case codexOfficial = "codex_official"
}

public enum CodexOfficial {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizationEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    public static let redirectURI = URL(string: "http://localhost:1455/auth/callback")!
    public static let scopes = [
        "openid",
        "profile",
        "email",
        "offline_access",
        "api.connectors.read",
        "api.connectors.invoke"
    ]

    public static let backendBaseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
    public static let backendBaseURLString = backendBaseURL.absoluteString
    public static let modelDiscoveryClientVersion = "0.144.1"

    public static let oauthOriginator = "codex_cli_rs"
    public static let upstreamOriginator = "codex_cli_rs"
    public static let authorizationHeader = "Authorization"
    public static let accountIDHeader = "ChatGPT-Account-ID"
    public static let originatorHeader = "Originator"
    public static let fedRAMPHeader = "X-OpenAI-Fedramp"
    public static let refreshLeeway: TimeInterval = 300

    public static func modelListURL(clientVersion: String) -> URL {
        var components = URLComponents(
            url: backendBaseURL.appendingPathComponent("models"),
            resolvingAgainstBaseURL: false
        )!
        let version = clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty {
            components.queryItems = [URLQueryItem(name: "client_version", value: version)]
        }
        return components.url!
    }
}
