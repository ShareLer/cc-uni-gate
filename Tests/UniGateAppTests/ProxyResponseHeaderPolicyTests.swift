@testable import UniGateApp
import Foundation
import Testing

struct ProxyResponseHeaderPolicyTests {
    @Test
    func officialResponsesStripCookiesButKeepOrdinaryHeaders() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Set-Cookie": "chatgpt_session=secret; Path=/; Secure; HttpOnly",
                "Set-Cookie2": "legacy_session=secret; Path=/; Secure",
                "X-Upstream-Test": "visible"
            ]
        ))

        let headers = ProxyResponseHeaderPolicy.forwardedHeaders(
            from: response,
            stripCookies: true
        )

        #expect(headerValue(headers, name: "set-cookie") == nil)
        #expect(headerValue(headers, name: "set-cookie2") == nil)
        #expect(headerValue(headers, name: "x-upstream-test") == "visible")
    }

    @Test
    func standardResponsesKeepExistingCookieForwardingBehavior() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.example.com/v1/responses")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "provider_cookie=value; Path=/; Secure"]
        ))

        let headers = ProxyResponseHeaderPolicy.forwardedHeaders(
            from: response,
            stripCookies: false
        )

        #expect(headerValue(headers, name: "set-cookie") != nil)
    }

    private func headerValue(_ headers: [String: String], name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
