import AppKit
import Security

@MainActor
enum CcSwitchApplicationLauncher {
    static let bundleIdentifier = "com.ccswitch.desktop"
    static let teamIdentifier = "R8UR22V2F9"
    static let designatedRequirement = """
    identifier "\(bundleIdentifier)" and anchor apple generic and \
    certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
    certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
    certificate leaf[subject.OU] = "\(teamIdentifier)"
    """

    static func openImportURL(
        _ importURL: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let applicationURL = trustedApplicationURL(for: importURL) else {
            completion(false)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [importURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                completion(error == nil)
            }
        }
    }

    private static func trustedApplicationURL(for importURL: URL) -> URL? {
        var candidates = NSWorkspace.shared.urlsForApplications(toOpen: importURL)
        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            candidates.append(applicationURL)
        }

        var seenPaths: Set<String> = []
        return candidates.first { applicationURL in
            seenPaths.insert(applicationURL.standardizedFileURL.path).inserted
                && isTrustedApplication(at: applicationURL)
        }
    }

    static func isTrustedApplication(at applicationURL: URL) -> Bool {
        guard Bundle(url: applicationURL)?.bundleIdentifier == bundleIdentifier else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess, let staticCode else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            designatedRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }
}
