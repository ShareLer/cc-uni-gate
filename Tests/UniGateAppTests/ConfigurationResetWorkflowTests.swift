import Testing
@testable import UniGateApp

@Suite @MainActor
struct ConfigurationResetWorkflowTests {
    @Test
    func logsOutAllCodexOAuthBeforeResettingLocalConfiguration() async throws {
        var steps: [String] = []

        try await ConfigurationResetWorkflow.run(
            logoutAllCodexOAuth: {
                steps.append("oauth")
            },
            resetLocalConfiguration: {
                steps.append("local")
            }
        )

        #expect(steps == ["oauth", "local"])
    }

    @Test
    func oauthDeletionFailurePreventsLocalConfigurationReset() async {
        var didResetLocalConfiguration = false

        do {
            try await ConfigurationResetWorkflow.run(
                logoutAllCodexOAuth: {
                    throw ResetTestError.keychainDeletionFailed
                },
                resetLocalConfiguration: {
                    didResetLocalConfiguration = true
                }
            )
            Issue.record("Expected the OAuth deletion failure to propagate")
        } catch ResetTestError.keychainDeletionFailed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!didResetLocalConfiguration)
    }
}

private enum ResetTestError: Error {
    case keychainDeletionFailed
}
