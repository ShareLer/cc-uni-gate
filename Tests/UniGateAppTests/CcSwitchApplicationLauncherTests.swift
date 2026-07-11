@testable import UniGateApp
import AppKit
import Testing

struct CcSwitchApplicationLauncherTests {
    @Test
    @MainActor
    func designatedRequirementPinsAppleDeveloperIDIdentity() {
        let requirement = CcSwitchApplicationLauncher.designatedRequirement
        #expect(requirement.contains(#"identifier "com.ccswitch.desktop""#))
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "R8UR22V2F9""#))
    }

    @Test
    @MainActor
    func installedOfficialApplicationPassesCodeSignatureValidationWhenPresent() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: CcSwitchApplicationLauncher.bundleIdentifier
        ) else {
            return
        }

        #expect(CcSwitchApplicationLauncher.isTrustedApplication(at: applicationURL))
    }
}
