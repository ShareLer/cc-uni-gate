import Foundation

enum AppVersion {
    static let bundleVersionKey = "CFBundleVersion"
    static let shortVersionKey = "CFBundleShortVersionString"

    static var shortVersion: String {
        shortVersion(in: .main)
    }

    static var bundleVersion: String {
        bundleVersion(in: .main)
    }

    static func shortVersion(in bundle: Bundle) -> String {
        bundleString(for: shortVersionKey, in: bundle) ?? "0.0.0"
    }

    static func bundleVersion(in bundle: Bundle) -> String {
        bundleString(for: bundleVersionKey, in: bundle) ?? shortVersion(in: bundle)
    }

    private static func bundleString(for key: String, in bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }
}
