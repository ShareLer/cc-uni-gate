import Foundation

public enum CcSwitchDeepLink {
    // Kept for recognizing old cc-switch imports. New imports must pass the
    // installation-specific token stored by UniGate.
    public static let localAPIKey = "sk-unigate-local"

    public static func providerImportURL(
        app: String,
        name: String = "UniGate",
        endpoint: String,
        apiKey: String,
        model: String? = nil,
        homepage: String? = nil,
        enabled: Bool = true
    ) -> URL? {
        var items = [
            URLQueryItem(name: "resource", value: "provider"),
            URLQueryItem(name: "app", value: app),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "endpoint", value: endpoint),
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(
                name: "notes",
                value: app == "codex"
                    ? "由 UniGate 导入；Codex 官方路由会校验此本地凭据，请勿修改。"
                    : "由 UniGate 导入。"
            )
        ]
        if let homepage, !homepage.isEmpty {
            items.append(URLQueryItem(name: "homepage", value: homepage))
        }
        if let model, !model.isEmpty {
            items.append(URLQueryItem(name: "model", value: model))
        }
        if enabled {
            items.append(URLQueryItem(name: "enabled", value: "true"))
        }

        var components = URLComponents()
        components.scheme = "ccswitch"
        components.host = "v1"
        components.path = "/import"
        components.queryItems = items
        return components.url
    }
}
