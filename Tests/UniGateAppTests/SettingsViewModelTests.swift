@testable import UniGateApp
import AppKit
import UniGateCore
import Testing

@MainActor
struct SettingsViewModelTests {
    @Test
    func applicationMenuIncludesTextEditingShortcuts() {
        ApplicationMenu.install()

        let editMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        #expect(editMenu?.item(withTitle: "Cut")?.action == #selector(NSText.cut(_:)))
        #expect(editMenu?.item(withTitle: "Cut")?.keyEquivalent == "x")
        #expect(editMenu?.item(withTitle: "Copy")?.action == #selector(NSText.copy(_:)))
        #expect(editMenu?.item(withTitle: "Copy")?.keyEquivalent == "c")
        #expect(editMenu?.item(withTitle: "Paste")?.action == #selector(NSText.paste(_:)))
        #expect(editMenu?.item(withTitle: "Paste")?.keyEquivalent == "v")
        #expect(editMenu?.item(withTitle: "Select All")?.action == #selector(NSText.selectAll(_:)))
        #expect(editMenu?.item(withTitle: "Select All")?.keyEquivalent == "a")
    }

    @Test
    func updatePreservesDirtyTextFields() {
        let initialPreferences = AppPreferences(
            port: 17888,
            ccSwitchDBPath: "/initial/cc-switch.db",
            networkPolicy: NetworkPolicyPreferences(directDomainRules: ["initial.example.com"])
        )
        let model = SettingsViewModel(
            candidates: [],
            providers: [],
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope(),
            preferences: initialPreferences,
            localProxyToken: nil,
            onApply: { _, _ in }
        )
        model.portText = "17999"
        model.ccSwitchDBPathText = "/partial/path"
        model.directDomainRulesText = "draft.example.com"

        model.update(
            candidates: [],
            providers: [],
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope(),
            preferences: AppPreferences(
                port: 18000,
                ccSwitchDBPath: "/updated/cc-switch.db",
                networkPolicy: NetworkPolicyPreferences(directDomainRules: ["updated.example.com"])
            )
        )

        #expect(model.preferences.port == 18000)
        #expect(model.portText == "17999")
        #expect(model.ccSwitchDBPathText == "/partial/path")
        #expect(model.directDomainRulesText == "draft.example.com")
    }

    @Test
    func applyGeneralSettingsDoesNotCommitDatabasePathByDefault() {
        let initialPreferences = AppPreferences(
            port: 17888,
            ccSwitchDBPath: "/stable/cc-switch.db"
        )
        var applied: [AppPreferences] = []
        let model = SettingsViewModel(
            candidates: [],
            providers: [],
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope(),
            preferences: initialPreferences,
            localProxyToken: nil,
            onApply: { preferences, _ in
                applied.append(preferences)
            }
        )
        model.portText = "17999"
        model.ccSwitchDBPathText = "/half-written"

        #expect(model.applyGeneralSettings())
        #expect(applied.first?.port == 17999)
        #expect(applied.first?.ccSwitchDBPath == "/stable/cc-switch.db")

        #expect(model.applyGeneralSettings(commitDatabasePath: true))
        #expect(applied.last?.ccSwitchDBPath == "/half-written")
    }

    @Test
    func ccSwitchImportUsesInstallationSpecificLocalProxyToken() throws {
        let token = "sk-unigate-installation-specific-token"
        let model = SettingsViewModel(
            candidates: [],
            providers: [],
            customModels: CustomModelState(),
            uniGateModelScope: UniGateModelScope(),
            preferences: AppPreferences(),
            localProxyToken: token,
            onApply: { _, _ in }
        )

        let url = try #require(model.ccSwitchImportURL(path: "/codex"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let params = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, $0.value ?? "")
        })

        #expect(params["apiKey"] == token)
        #expect(params["endpoint"] == "http://127.0.0.1:17888/codex")
        #expect(params["notes"]?.contains("Codex 官方路由会校验") == true)
    }
}
