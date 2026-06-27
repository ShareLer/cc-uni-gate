@testable import UniGateApp
import UniGateCore
import Foundation
import Network
import Testing

struct LocalProxyServerTests {
    @Test
    @MainActor
    func malformedOpenAIChatStreamChunkBecomesAnthropicErrorEvent() async throws {
        let upstream = try MockSSEUpstream(
            body: Data("data: {not json}\n\n".utf8)
        )
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let provider = ImportedProvider(
            id: "openai-chat",
            appType: UniGateAppRegistry.claudeCode,
            name: "OpenAI Chat Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiChat,
            baseURL: "http://127.0.0.1:\(upstreamPort)",
            hasSecret: true,
            settings: ["env": .object(["OPENAI_API_KEY": .string("test-key")])],
            meta: [:]
        )
        let routeKey = ModelRouteKey(appType: UniGateAppRegistry.claudeCode, logicalModel: "claude-sonnet")
        let candidate = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: routeKey.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .openaiChat,
            upstreamModel: "gpt-4.1",
            baseURL: provider.baseURL,
            requiresTransform: true,
            label: nil,
            supportsLongContext: false
        )
        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: ProviderCatalog(providers: [provider], candidates: [candidate]),
            routes: RouteState(routes: [
                routeKey.description: ActiveRoute(
                    appType: routeKey.appType,
                    logicalModel: routeKey.logicalModel,
                    providerRef: provider.ref,
                    updatedAt: Date(timeIntervalSince1970: 1)
                )
            ]),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))

        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let requestBody = """
        {
          "model": "claude-sonnet",
          "max_tokens": 16,
          "stream": true,
          "messages": [
            {"role": "user", "content": "hello"}
          ]
        }
        """
        let rawResponse = try await Task.detached {
            try Self.rawHTTPResponse(
                port: proxyPort,
                request: """
                POST /v1/messages HTTP/1.1\r
                Host: 127.0.0.1:\(proxyPort)\r
                Content-Type: application/json\r
                Accept: text/event-stream\r
                Content-Length: \(Data(requestBody.utf8).count)\r
                \r
                \(requestBody)
                """
            )
        }.value

        #expect(rawResponse.contains("HTTP/1.1 200 OK"))
        #expect(runtime.failures.contains { $0.contains("SSE error") }, "\(runtime.events)")
        #expect(rawResponse.contains("event: error"), "\(rawResponse)\n\(runtime.events)")
        #expect(rawResponse.contains("Upstream OpenAI Chat stream chunk must be a JSON object"), "\(rawResponse)\n\(runtime.events)")
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TestError("socket failed")
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw TestError("bind failed")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw TestError("getsockname failed")
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    private static func rawHTTPResponse(port: UInt16, request: String) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TestError("socket failed")
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw TestError("connect failed")
        }

        let requestData = Array(request.utf8)
        try requestData.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var sent = 0
            while sent < requestData.count {
                let count = send(descriptor, baseAddress.advanced(by: sent), requestData.count - sent, 0)
                guard count > 0 else {
                    throw TestError("send failed")
                }
                sent += count
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count == 0 {
                break
            } else {
                throw TestError("read failed")
            }
        }
        return String(data: response, encoding: .utf8) ?? ""
    }
}

@MainActor
private final class MockProxyRuntime: LocalProxyRuntime {
    private var snapshot: ProxyRuntimeSnapshot
    private var listenerStates: [ProxyListenerState] = []
    private(set) var failures: [String] = []
    private(set) var events: [String] = []

    init(snapshot: ProxyRuntimeSnapshot) {
        self.snapshot = snapshot
    }

    func waitUntilReady() async throws {
        for _ in 0..<100 {
            if listenerStates.contains(where: { state in
                if case .ready = state {
                    return true
                }
                return false
            }) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestError("proxy listener did not become ready")
    }

    func proxySnapshot() -> ProxyRuntimeSnapshot {
        snapshot
    }

    func modelListSnapshot() -> ProxyRuntimeSnapshot {
        snapshot
    }

    func reloadProxyRuntime() throws -> ProxyRuntimeSnapshot {
        snapshot
    }

    func switchProxyRoute(routeKey: ModelRouteKey, providerRef: ProviderRef) throws -> ProxyRuntimeSnapshot {
        snapshot
    }

    func recordProxyEvent(level: ProxyEvent.Level, message: String) {
        events.append(message)
    }

    func recordForwardedRequest(appType: String) {}

    func recordRequestMetric(
        key: RequestMetricKey,
        statusCode: Int?,
        latencyMilliseconds: Double,
        errorMessage: String?,
        providerFailure: Bool
    ) {}

    func proxyProviderDidSucceed() {}

    func proxyProviderDidFail(_ message: String) {
        failures.append(message)
    }

    func proxyProviderDidFail(appType: String, message: String) {
        failures.append(message)
    }

    func proxyListenerDidChange(_ state: ProxyListenerState, serverID: UUID) {
        listenerStates.append(state)
    }
}

private final class MockSSEUpstream: @unchecked Sendable {
    private let body: Data
    private let queue = DispatchQueue(label: "unigate.test.upstream")
    private let listener: NWListener

    init(body: Data) throws {
        self.body = body
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 0)!)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        for _ in 0..<100 {
            if let port = listener.port?.rawValue, port != 0 {
                return port
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestError("upstream listener did not become ready")
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, data: Data())
    }

    private func receive(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] chunk, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }
            var next = data
            if let chunk {
                next.append(chunk)
            }
            if Self.hasCompleteRequest(next) {
                self.sendResponse(on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, data: next)
            }
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let head = Data("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\ncontent-length: \(body.count)\r\n\r\n".utf8)
        connection.send(content: head + body, completion: .contentProcessed { _ in
            self.queue.asyncAfter(deadline: .now() + 0.05) {
                connection.cancel()
            }
        })
    }

    private static func hasCompleteRequest(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return false
        }
        let headers = Dictionary(uniqueKeysWithValues: headerText
            .components(separatedBy: "\r\n")
            .dropFirst()
            .compactMap { line -> (String, String)? in
                guard let separator = line.firstIndex(of: ":") else {
                    return nil
                }
                let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return (name, value)
            })
        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        return data.count >= headerRange.upperBound + bodyLength
    }
}

private struct TestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
