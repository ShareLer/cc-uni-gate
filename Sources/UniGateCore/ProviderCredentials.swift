struct ProviderSecret: Sendable, Equatable {
    let path: [String]
    let value: String

    var field: String {
        path.joined(separator: ".")
    }

    var name: String {
        path.last ?? field
    }
}

enum ProviderCredentials {
    static func secret(for provider: ImportedProvider) -> ProviderSecret? {
        secret(appType: provider.appType, settings: provider.settings)
    }

    static func secret(
        appType: String,
        settings: [String: SendableValue]
    ) -> ProviderSecret? {
        for path in secretPaths(appType: appType) {
            if let value = JSONValueParser.string(settings, path) {
                return ProviderSecret(path: path, value: value)
            }
        }
        return nil
    }

    static func hasSecret(appType: String, settings: [String: SendableValue]) -> Bool {
        secret(appType: appType, settings: settings) != nil
    }

    static func proxyAuthHeaders(for provider: ImportedProvider) -> [String: String] {
        guard let secret = secret(for: provider) else {
            return [:]
        }
        return proxyAuthHeaders(appType: provider.appType, apiFormat: provider.apiFormat, secret: secret)
    }

    static func modelFetchHeaders(for provider: ImportedProvider) -> [String: String]? {
        secret(for: provider).map(modelFetchHeaders(secret:))
    }

    static func modelFetchHeaders(secret: ProviderSecret) -> [String: String] {
        ["authorization": "Bearer \(secret.value)"]
    }

    private static func proxyAuthHeaders(
        appType: String,
        apiFormat: ApiFormat,
        secret: ProviderSecret
    ) -> [String: String] {
        if isAnthropicApp(appType), apiFormat == .anthropic, secret.name == "ANTHROPIC_API_KEY" {
            return ["x-api-key": secret.value]
        }
        return ["authorization": "Bearer \(secret.value)"]
    }

    private static func secretPaths(appType: String) -> [[String]] {
        switch appType {
        case UniGateAppRegistry.codex:
            return [["auth", "OPENAI_API_KEY"], ["env", "OPENAI_API_KEY"]]
        case UniGateAppRegistry.claudeCode, UniGateAppRegistry.claudeDesktop:
            return [
                ["env", "ANTHROPIC_AUTH_TOKEN"],
                ["env", "ANTHROPIC_API_KEY"],
                ["env", "OPENAI_API_KEY"],
                ["apiKey"],
                ["api_key"]
            ]
        case "gemini":
            return [["env", "GEMINI_API_KEY"], ["env", "GOOGLE_API_KEY"]]
        default:
            return [["api_key"]]
        }
    }

    private static func isAnthropicApp(_ appType: String) -> Bool {
        UniGateAppRegistry.isClaudeLike(appType)
    }
}
