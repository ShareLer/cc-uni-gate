@testable import UniGateApp
import UniGateCore
import Testing

@MainActor
struct SettingsViewModelTests {
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
}
