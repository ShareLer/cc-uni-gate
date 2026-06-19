import UniGateCore
import Foundation
import Network

@MainActor
protocol LocalProxyRuntime: AnyObject {
    func proxySnapshot() -> ProxyRuntimeSnapshot
    func reloadProxyRuntime() throws -> ProxyRuntimeSnapshot
    func switchProxyRoute(routeKey: ModelRouteKey, providerRef: ProviderRef) throws -> ProxyRuntimeSnapshot
    func recordProxyEvent(level: ProxyEvent.Level, message: String)
    func proxyListenerDidChange(_ state: ProxyListenerState, serverID: UUID)
}

struct ProxyRuntimeSnapshot: Sendable {
    let catalog: ProviderCatalog
    let routes: RouteState
}

enum ProxyListenerState: Sendable {
    case setup
    case waiting(String)
    case ready
    case failed(String)
    case cancelled
}

final class LocalProxyServer: @unchecked Sendable {
    let id = UUID()
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let runtime: any LocalProxyRuntime
    private let queue = DispatchQueue(label: "unigate.local-proxy")
    private var listener: NWListener?

    init(host: String = "127.0.0.1", port: UInt16 = 17888, runtime: any LocalProxyRuntime) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.runtime = runtime
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            self.report(state)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func report(_ state: NWListener.State) {
        let proxyState: ProxyListenerState
        switch state {
        case .setup:
            proxyState = .setup
        case .waiting(let error):
            proxyState = .waiting(error.localizedDescription)
        case .ready:
            proxyState = .ready
        case .failed(let error):
            proxyState = .failed(error.localizedDescription)
        case .cancelled:
            proxyState = .cancelled
        @unknown default:
            proxyState = .failed("未知监听状态")
        }

        Task { @MainActor in
            self.runtime.proxyListenerDidChange(proxyState, serverID: self.id)
        }
    }

    private func handle(_ connection: NWConnection) {
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, data: Data())
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return true
        }
        switch host {
        case .ipv4(let address):
            return address.rawValue.first == 127
        case .ipv6(let address):
            return address.rawValue == IPv6Address.loopback.rawValue
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    private func receive(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }

            var next = data
            if let chunk {
                next.append(chunk)
            }

            if let request = HTTPRequest.parse(next) {
                Task {
                    await self.handle(request, on: connection)
                }
            } else if next.count > 10_485_760 {
                send(.json(status: 413, body: ["error": "Request too large"]), on: connection)
            } else {
                receive(on: connection, data: next)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        if request.method == "POST", proxyRoute(for: request.path) != nil {
            await proxy(request, on: connection)
            return
        }

        let response = await respond(to: request)
        send(response, on: connection)
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        do {
            if request.method == "OPTIONS" {
                return .empty(status: 204)
            }

            if request.method == "GET", request.path == "/__manager/health" {
                let snapshot = await MainActor.run { runtime.proxySnapshot() }
                return .json(status: 200, body: [
                    "ok": true,
                    "serverID": id.uuidString,
                    "providers": snapshot.catalog.providers.count,
                    "candidates": snapshot.catalog.candidates.count
                ])
            }

            if request.method == "POST", request.path == "/__manager/reload" {
                _ = try await MainActor.run { try runtime.reloadProxyRuntime() }
                return .json(status: 200, body: ["ok": true])
            }

            if request.method == "GET", request.path == "/__manager/catalog" {
                let snapshot = await MainActor.run { runtime.proxySnapshot() }
                return catalogResponse(snapshot)
            }

            if request.method == "GET", case let .models(appType) = ProxyRequestPath(request.path) {
                let snapshot = await MainActor.run { runtime.proxySnapshot() }
                return modelsResponse(snapshot, appType: appType)
            }

            if request.method == "POST", request.path == "/__manager/routes" {
                let body = try jsonObject(request.body)
                guard
                    let logicalModel = body["logicalModel"] as? String,
                    let providerRefText = body["providerRef"] as? String,
                    let providerRef = ProviderRef(description: providerRefText)
                else {
                    return .json(status: 400, body: ["error": "logicalModel and providerRef are required"])
                }
                let appType = body["appType"] as? String ?? providerRef.appType
                let snapshot = try await MainActor.run {
                    try runtime.switchProxyRoute(
                        routeKey: ModelRouteKey(appType: appType, logicalModel: logicalModel),
                        providerRef: providerRef
                    )
                }
                return routesResponse(snapshot)
            }

            return .json(status: 404, body: ["error": "Not found"])
        } catch {
            return .json(status: 500, body: ["error": error.localizedDescription])
        }
    }

    private func proxy(_ request: HTTPRequest, on connection: NWConnection) async {
        do {
            let snapshot = await MainActor.run { runtime.proxySnapshot() }
            guard let route = proxyRoute(for: request.path) else {
                send(.json(status: 404, body: ["error": "Not found"]), on: connection)
                return
            }
            let resolved = try ProxyResolver.resolveRoute(
                catalog: snapshot.catalog,
                routes: snapshot.routes,
                protocolKind: route.protocolKind,
                appType: route.appType,
                path: request.path,
                body: request.body
            )

            var upstreamRequest = URLRequest(url: resolved.upstreamURL)
            upstreamRequest.httpMethod = "POST"
            upstreamRequest.httpBody = resolved.body
            upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")

            for (key, value) in copyAllowedHeaders(request.headers) {
                upstreamRequest.setValue(value, forHTTPHeaderField: key)
            }
            for (key, value) in resolved.headers {
                upstreamRequest.setValue(value, forHTTPHeaderField: key)
            }

            let (bytes, response) = try await URLSession.shared.bytes(for: upstreamRequest)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            let headers = forwardResponseHeaders(http)
            await MainActor.run {
                runtime.recordProxyEvent(
                    level: .info,
                    message: "\(request.path) -> \(resolved.providerName) · \(ProviderDisplay.appTypeLabel(resolved.candidate.appType)) \(status)"
                )
            }
            if resolved.responseTransform != .none {
                try await sendTransformedResponse(
                    bytes: bytes,
                    status: status,
                    headers: headers,
                    resolved: resolved,
                    on: connection
                )
                return
            }
            let head = HTTPResponseHead(
                status: status,
                headers: headers
            )
            try await sendHead(head, on: connection)
            var buffer = Data()
            buffer.reserveCapacity(8_192)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 8_192 || byte == 10 {
                    try await send(buffer, on: connection)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try await send(buffer, on: connection)
            }
            connection.cancel()
        } catch let error as ProxyResolverError {
            await MainActor.run {
                runtime.recordProxyEvent(level: .error, message: "\(request.path) failed: \(error.localizedDescription)")
            }
            send(.json(status: 400, body: ["error": error.localizedDescription]), on: connection)
        } catch {
            await MainActor.run {
                runtime.recordProxyEvent(level: .error, message: "\(request.path) upstream error: \(error.localizedDescription)")
            }
            send(.json(status: 502, body: ["error": error.localizedDescription]), on: connection)
        }
    }

    private func sendTransformedResponse(
        bytes: URLSession.AsyncBytes,
        status: Int,
        headers: [String: String],
        resolved: ResolvedRoute,
        on connection: NWConnection
    ) async throws {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > 10_485_760 {
                send(.json(status: 413, body: ["error": "Response too large"]), on: connection)
                return
            }
        }

        guard status >= 200 && status < 300 else {
            let response = HTTPResponse(
                status: status,
                headers: headers,
                body: body
            )
            send(response, on: connection)
            return
        }

        switch resolved.responseTransform {
        case .none:
            send(HTTPResponse(status: status, headers: headers, body: body), on: connection)
        case .openAIChatToCodexResponse:
            let value = try JSONSerialization.jsonObject(with: body)
            guard let object = value as? [String: Any] else {
                throw CodexChatBridgeError.invalidChatResponse
            }
            let transformed = try CodexChatBridge.responsesBody(
                from: object,
                fallbackModel: resolved.outboundModel
            )
            var responseHeaders = headers
            removeEntityHeaders(from: &responseHeaders)
            responseHeaders["content-type"] = "application/json; charset=utf-8"
            let responseBody = try JSONSerialization.data(withJSONObject: transformed, options: [])
            send(HTTPResponse(status: status, headers: responseHeaders, body: responseBody), on: connection)
        }
    }

    private func removeEntityHeaders(from headers: inout [String: String]) {
        for key in Array(headers.keys) where ["content-type", "content-encoding", "content-md5"].contains(key.lowercased()) {
            headers.removeValue(forKey: key)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHead(_ head: HTTPResponseHead, on connection: NWConnection) async throws {
        try await send(head.data, on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func catalogResponse(_ snapshot: ProxyRuntimeSnapshot) -> HTTPResponse {
        let providers = snapshot.catalog.providers.map { provider in
            [
                "ref": provider.ref.description,
                "appType": provider.appType,
                "name": provider.name,
                "displayName": provider.displayName,
                "category": provider.category as Any,
                "isCurrent": provider.isCurrent,
                "apiFormat": provider.apiFormat.rawValue,
                "baseUrl": provider.baseURL as Any,
                "hasSecret": provider.hasSecret
            ]
        }

        let candidates = snapshot.catalog.candidates.map { candidate in
            [
                "logicalModel": candidate.logicalModel,
                "routeKey": candidate.routeKey.description,
                "providerRef": candidate.providerRef.description,
                "providerName": candidate.providerName,
                "providerDisplayName": "\(candidate.providerName) · \(ProviderDisplay.appTypeLabel(candidate.appType))",
                "appType": candidate.appType,
                "clientProtocol": candidate.clientProtocol.rawValue,
                "apiFormat": candidate.apiFormat.rawValue,
                "upstreamModel": candidate.upstreamModel,
                "baseUrl": candidate.baseURL as Any,
                "requiresTransform": candidate.requiresTransform,
                "label": candidate.label as Any,
                "supportsLongContext": candidate.supportsLongContext
            ]
        }

        return .json(status: 200, body: [
            "providers": providers,
            "candidates": candidates,
            "routes": routeDictionary(snapshot.routes)
        ])
    }

    private func routesResponse(_ snapshot: ProxyRuntimeSnapshot) -> HTTPResponse {
        .json(status: 200, body: [
            "ok": true,
            "routes": routeDictionary(snapshot.routes)
        ])
    }

    private func modelsResponse(_ snapshot: ProxyRuntimeSnapshot, appType: String?) -> HTTPResponse {
        let appType = appType ?? "codex"
        let routeKeys = snapshot.catalog.routeKeys
            .filter { $0.appType == appType }
        let modelIDs = Array(Set(routeKeys.map(\.logicalModel))).sorted()
        let data = modelIDs.map { ["id": $0, "object": "model"] }
        let models: Any = appType == "codex"
            ? codexModelCatalog(routeKeys: routeKeys, candidates: snapshot.catalog.candidates)
            : modelIDs
        return .json(status: 200, body: [
            "object": "list",
            "data": data,
            "models": models
        ])
    }

    private func codexModelCatalog(routeKeys: [ModelRouteKey], candidates: [ModelCandidate]) -> [[String: Any]] {
        routeKeys.map { key in
            let routeCandidates = candidates.filter {
                $0.appType == key.appType && $0.logicalModel == key.logicalModel
            }
            let displayName = routeCandidates
                .compactMap(\.label)
                .first { !$0.isEmpty && $0 != routeCandidates.first?.providerName }
                ?? key.logicalModel
            let contextWindow = routeCandidates.contains(where: \.supportsLongContext) ? 1_000_000 : 128_000
            return [
                "slug": key.logicalModel,
                "display_name": displayName,
                "description": displayName,
                "context_window": contextWindow,
                "max_context_window": contextWindow
            ]
        }
    }

    private func routeDictionary(_ routes: RouteState) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var result: [String: Any] = [:]
        for (model, route) in routes.routes {
            result[model] = [
                "appType": route.appType,
                "logicalModel": route.logicalModel,
                "routeKey": route.routeKey.description,
                "providerRef": route.providerRef.description,
                "updatedAt": formatter.string(from: route.updatedAt)
            ]
        }
        return result
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return value as? [String: Any] ?? [:]
    }

    private func proxyRoute(for path: String) -> (protocolKind: ClientProtocolKind, appType: String)? {
        guard case let .proxy(protocolKind, appType) = ProxyRequestPath(path) else {
            return nil
        }
        return (protocolKind, appType)
    }

    private func copyAllowedHeaders(_ headers: [String: String]) -> [String: String] {
        var copied: [String: String] = [:]
        for key in ["accept", "anthropic-version", "anthropic-beta", "user-agent"] {
            if let value = headers[key] {
                copied[key] = value
            }
        }
        return copied
    }

    private func forwardResponseHeaders(_ response: HTTPURLResponse?) -> [String: String] {
        guard let response else {
            return [:]
        }
        let blocked = Set([
            "connection",
            "content-length",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "transfer-encoding",
            "upgrade"
        ])

        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            if !blocked.contains(name.lowercased()) {
                headers[name] = String(describing: value)
            }
        }
        return headers
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + bodyLength else {
            return nil
        }

        return HTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + bodyLength)])
        )
    }
}

private struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(status: Int, body: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: data + Data("\n".utf8)
        )
    }

    static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: Data())
    }

    var data: Data {
        var response = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        var mergedHeaders = headers
        mergedHeaders["content-length"] = "\(body.count)"
        mergedHeaders["connection"] = "close"
        mergedHeaders["access-control-allow-origin"] = "http://127.0.0.1:5173"
        mergedHeaders["access-control-allow-methods"] = "GET,POST,OPTIONS"
        mergedHeaders["access-control-allow-headers"] = "content-type,authorization"
        for (key, value) in mergedHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8) + body
    }

    private func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 204:
            return "No Content"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        case 413:
            return "Payload Too Large"
        case 500:
            return "Internal Server Error"
        case 502:
            return "Bad Gateway"
        default:
            return "OK"
        }
    }
}

private struct HTTPResponseHead {
    let status: Int
    let headers: [String: String]

    var data: Data {
        var response = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        var mergedHeaders = headers
        mergedHeaders["connection"] = "close"
        mergedHeaders["access-control-allow-origin"] = "http://127.0.0.1:5173"
        mergedHeaders["access-control-allow-methods"] = "GET,POST,OPTIONS"
        mergedHeaders["access-control-allow-headers"] = "content-type,authorization"
        for (key, value) in mergedHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8)
    }

    private func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 500:
            return "Internal Server Error"
        case 502:
            return "Bad Gateway"
        default:
            return "OK"
        }
    }
}
