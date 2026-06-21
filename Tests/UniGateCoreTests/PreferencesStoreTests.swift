import UniGateCore
import Foundation
import Testing

struct PreferencesStoreTests {
    @Test
    func missingPreferencesFileMeansShowAllModels() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)

        let preferences = try store.load()

        #expect(preferences.visibleModelList(allModels: ["a", "b"]) == ["a", "b"])
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test
    func emptyVisibleModelsMeansShowNoModels() {
        let preferences = AppPreferences(visibleModels: [])
        #expect(preferences.visibleModelList(allModels: ["a", "b"]) == [])
    }

    @Test
    func filtersVisibleModels() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)
        try store.save(AppPreferences(visibleModels: ["gpt-5.5"]))

        let loaded = try store.load()
        #expect(loaded.visibleModelList(allModels: ["auto", "gpt-5.5"]) == ["gpt-5.5"])
    }

    @Test
    func persistsProtocolOverrides() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)
        let ref = ProviderRef(appType: "codex", id: "p1")
        try store.save(AppPreferences(protocolOverrides: [ref.description: .openaiResponses]))

        let loaded = try store.load()

        #expect(loaded.protocolOverride(for: ref) == .openaiResponses)
    }

    @Test
    func loadsLegacyPreferencesWithoutProtocolOverrides() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        try FileManager.default.createDirectory(
            at: tmp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"visibleModels":["gpt-5.5"]}"#.utf8).write(to: tmp)
        let store = PreferencesStore(fileURL: tmp)

        let loaded = try store.load()

        #expect(loaded.visibleModelList(allModels: ["auto", "gpt-5.5"]) == ["gpt-5.5"])
        #expect(loaded.visibleRouteKeyList(allRouteKeys: [
            ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5"),
            ModelRouteKey(appType: "claude", logicalModel: "auto")
        ]) == [ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")])
        #expect(loaded.protocolOverrides.isEmpty)
        #expect(loaded.port == 17888)
        #expect(loaded.ccSwitchDBPath == nil)
        #expect(loaded.resolvedCcSwitchDBPath == AppPreferences.defaultCcSwitchDBPath())
        #expect(loaded.brandColor == .ember)
        #expect(loaded.bubbleNotificationsEnabled)
        #expect(loaded.launchAtLoginEnabled)
    }

    @Test
    func filtersVisibleRouteKeys() {
        let preferences = AppPreferences(visibleModels: ["codex:gpt-5.5"])

        let visible = preferences.visibleRouteKeyList(allRouteKeys: [
            ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5"),
            ModelRouteKey(appType: "claude", logicalModel: "gpt-5.5")
        ])

        #expect(visible == [ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")])
    }

    @Test
    func persistsPort() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)
        try store.save(AppPreferences(port: 17988))

        let loaded = try store.load()

        #expect(loaded.port == 17988)
    }

    @Test
    func persistsCcSwitchDBPath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)
        try store.save(AppPreferences(ccSwitchDBPath: "~/.cc-switch/custom.db"))

        let loaded = try store.load()

        #expect(loaded.ccSwitchDBPath == "~/.cc-switch/custom.db")
        #expect(loaded.resolvedCcSwitchDBPath.hasSuffix("/.cc-switch/custom.db"))
    }

    @Test
    func persistsBrandColor() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)
        try store.save(AppPreferences(brandColor: .teal))

        let loaded = try store.load()

        #expect(loaded.brandColor == .teal)
    }

    @Test
    func persistsBubbleNotificationsEnabled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)
        try store.save(AppPreferences(bubbleNotificationsEnabled: false))

        let loaded = try store.load()

        #expect(!loaded.bubbleNotificationsEnabled)
    }

    @Test
    func persistsLaunchAtLoginEnabled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: tmp)
        try store.save(AppPreferences(launchAtLoginEnabled: false))

        let loaded = try store.load()

        #expect(!loaded.launchAtLoginEnabled)
    }

    @Test
    func unknownBrandColorFallsBackToDefault() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("preferences.json")
        try FileManager.default.createDirectory(
            at: tmp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"brandColor":"unknown"}"#.utf8).write(to: tmp)
        let store = PreferencesStore(fileURL: tmp)

        let loaded = try store.load()

        #expect(loaded.brandColor == .ember)
    }
}
