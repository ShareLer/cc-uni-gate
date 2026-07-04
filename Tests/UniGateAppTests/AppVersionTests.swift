@testable import UniGateApp
import Foundation
import Testing

@MainActor
struct AppVersionTests {
    @Test
    func readsVersionStringsFromBundleInfoDictionary() throws {
        let bundle = try makeBundle(
            shortVersion: "1.2.3",
            bundleVersion: "456"
        )

        #expect(AppVersion.shortVersion(in: bundle) == "1.2.3")
        #expect(AppVersion.bundleVersion(in: bundle) == "456")
    }

    @Test
    func fallsBackToShortVersionWhenBundleVersionIsMissing() throws {
        let bundle = try makeBundle(shortVersion: "2.0.1", bundleVersion: nil)

        #expect(AppVersion.shortVersion(in: bundle) == "2.0.1")
        #expect(AppVersion.bundleVersion(in: bundle) == "2.0.1")
    }

    private func makeBundle(shortVersion: String, bundleVersion: String?) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": "test.uni-gate.version",
            "CFBundleShortVersionString": shortVersion
        ]
        if let bundleVersion {
            plist["CFBundleVersion"] = bundleVersion
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        guard let bundle = Bundle(path: root.path) else {
            throw NSError(
                domain: "UniGateAppTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load test bundle."]
            )
        }
        return bundle
    }
}
