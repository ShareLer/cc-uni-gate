@testable import UniGateApp
import Foundation
import Testing

@MainActor
struct AppUpdateConfigurationTests {
    private let validPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    @Test
    func acceptsValidConfiguration() throws {
        let bundle = try makeBundle([
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": validPublicKey
        ])

        try AppUpdateService.validateConfiguration(in: bundle)
    }

    @Test
    func treatsBlankConfigurationAsMissing() throws {
        let bundle = try makeBundle([
            "SUFeedURL": "",
            "SUPublicEDKey": ""
        ])

        expectConfigurationError(.missingConfiguration) {
            try AppUpdateService.validateConfiguration(in: bundle)
        }
    }

    @Test
    func rejectsPartialConfiguration() throws {
        let bundle = try makeBundle([
            "SUFeedURL": "https://example.com/appcast.xml"
        ])

        expectConfigurationError(.incompleteConfiguration) {
            try AppUpdateService.validateConfiguration(in: bundle)
        }
    }

    @Test
    func rejectsInvalidPublicKey() throws {
        let bundle = try makeBundle([
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "placeholder-public-key"
        ])

        expectConfigurationError(.invalidPublicKey) {
            try AppUpdateService.validateConfiguration(in: bundle)
        }
    }

    @Test
    func rejectsInvalidFeedURL() throws {
        let bundle = try makeBundle([
            "SUFeedURL": "not a url",
            "SUPublicEDKey": validPublicKey
        ])

        expectConfigurationError(.invalidFeedURL) {
            try AppUpdateService.validateConfiguration(in: bundle)
        }
    }

    private func expectConfigurationError(
        _ expected: AppUpdateConfigurationError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected \(expected), but validation succeeded.")
        } catch let error as AppUpdateConfigurationError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error).")
        }
    }

    private func makeBundle(_ values: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": "test.uni-gate.update"
        ]
        values.forEach { key, value in
            plist[key] = value
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
