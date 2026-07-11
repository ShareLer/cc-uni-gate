@MainActor
enum ConfigurationResetWorkflow {
    static func run(
        logoutAllCodexOAuth: () async throws -> Void,
        resetLocalConfiguration: () throws -> Void
    ) async throws {
        try await logoutAllCodexOAuth()
        try resetLocalConfiguration()
    }
}
