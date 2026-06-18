import ApiManagerCore
import Foundation
import Testing

struct AppPathsTests {
    @Test
    func migratesLegacyApplicationSupportDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("API Manager", isDirectory: true)
        let current = root.appendingPathComponent("UniGate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("routes".utf8).write(to: legacy.appendingPathComponent("routes.json"))
        try Data("logs".utf8).write(to: legacy.appendingPathComponent("logs/api-manager.log"))

        try AppPaths.migrateApplicationSupportDirectory(from: legacy, to: current)

        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("routes.json").path))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("logs/unigate.log").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test
    func migrationDoesNotOverwriteCurrentFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("API Manager", isDirectory: true)
        let current = root.appendingPathComponent("UniGate", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("routes.json"))
        try Data("current".utf8).write(to: current.appendingPathComponent("routes.json"))
        try Data("prefs".utf8).write(to: legacy.appendingPathComponent("preferences.json"))

        try AppPaths.migrateApplicationSupportDirectory(from: legacy, to: current)

        let routes = try String(contentsOf: current.appendingPathComponent("routes.json"), encoding: .utf8)
        let preferences = try String(contentsOf: current.appendingPathComponent("preferences.json"), encoding: .utf8)
        #expect(routes == "current")
        #expect(preferences == "prefs")
    }
}
