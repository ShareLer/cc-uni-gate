@testable import UniGateApp
import Foundation
import Testing

@Suite(.serialized)
struct CodexOAuthCallbackServerTests {
    @Test
    func ignoresStateMismatchThenAcceptsMatchingCallback() async throws {
        let server = try await CodexOAuthCallbackServer.start()
        server.configure(expectedState: "expected-state")
        defer { server.stop() }

        let waitTask = Task {
            try await server.waitForAuthorizationCode(timeout: 5)
        }

        let mismatch = try await callback(
            port: server.port,
            items: [
                URLQueryItem(name: "code", value: "wrong-code"),
                URLQueryItem(name: "state", value: "wrong-state")
            ]
        )
        #expect(mismatch.statusCode == 400)

        let success = try await callback(
            port: server.port,
            items: [
                URLQueryItem(name: "code", value: "authorization-code"),
                URLQueryItem(name: "state", value: "expected-state")
            ]
        )
        #expect(success.statusCode == 200)
        #expect(try await waitTask.value == "authorization-code")
    }

    @Test
    func matchingOAuthErrorEndsLogin() async throws {
        let server = try await CodexOAuthCallbackServer.start()
        server.configure(expectedState: "expected-state")
        defer { server.stop() }

        let waitTask = Task {
            try await server.waitForAuthorizationCode(timeout: 5)
        }
        let response = try await callback(
            port: server.port,
            items: [
                URLQueryItem(name: "error", value: "access_denied"),
                URLQueryItem(name: "error_description", value: "User cancelled"),
                URLQueryItem(name: "state", value: "expected-state")
            ]
        )

        #expect(response.statusCode == 400)
        await #expect(throws: CodexOAuthCallbackServerError.authorizationDenied("User cancelled")) {
            try await waitTask.value
        }
    }

    private func callback(port: UInt16, items: [URLQueryItem]) async throws -> HTTPURLResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = CodexOAuthCallbackServer.callbackPath
        components.queryItems = items
        let url = try #require(components.url)
        let (_, response) = try await URLSession.shared.data(from: url)
        return try #require(response as? HTTPURLResponse)
    }
}
