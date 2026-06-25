import UniGateCore
import Foundation
import Network

@MainActor
protocol LocalProxyRuntime: AnyObject {
    func proxySnapshot() -> ProxyRuntimeSnapshot
    func modelListSnapshot() -> ProxyRuntimeSnapshot
    func reloadProxyRuntime() throws -> ProxyRuntimeSnapshot
    func switchProxyRoute(routeKey: ModelRouteKey, providerRef: ProviderRef) throws -> ProxyRuntimeSnapshot
    func recordProxyEvent(level: ProxyEvent.Level, message: String)
    func recordForwardedRequest(appType: String)
    func recordRequestMetric(
        key: RequestMetricKey,
        statusCode: Int?,
        latencyMilliseconds: Double,
        errorMessage: String?,
        providerFailure: Bool
    )
    func proxyProviderDidSucceed()
    func proxyProviderDidFail(_ message: String)
    func proxyProviderDidFail(appType: String, message: String)
    func proxyListenerDidChange(_ state: ProxyListenerState, serverID: UUID)
}

struct ProxyRuntimeSnapshot: Sendable {
    let catalog: ProviderCatalog
    let routes: RouteState
    let networkPolicy: NetworkPolicyPreferences
}

enum ProxyListenerState: Sendable {
    case setup
    case waiting(String)
    case ready
    case failed(String)
    case cancelled
}

final class LocalProxyServer: @unchecked Sendable {
    private static let upstreamRequestTimeout: TimeInterval = 600

    private struct ProxyStreamStats {
        var bytesForwarded = 0
        var chunksForwarded = 0
        var linesObserved = 0
        var firstByteLatencyMilliseconds: Int?
        var lastChunkForwardedAt: Date?
        var upstreamErrorSinceLastChunkMilliseconds: Int?
        var sseFailureSinceLastChunkMilliseconds: Int?
        var sawSSEFailure = false
        var sseFailureDetail: String?
    }

    private enum ProxyTransferError: Error {
        case downstream(Error, stats: ProxyStreamStats)
        case upstream(Error, stats: ProxyStreamStats)
    }

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
                send(.json(status: 413, body: ["error": "Request too large"], allowsCORS: true), on: connection)
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
                return .empty(status: 204, allowsCORS: true)
            }

            if request.method == "GET", request.path == "/__manager/health" {
                let snapshot = await MainActor.run { runtime.proxySnapshot() }
                return .json(status: 200, body: [
                    "ok": true,
                    "serverID": id.uuidString,
                    "providers": snapshot.catalog.providers.count,
                    "candidates": snapshot.catalog.candidates.count
                ], allowsCORS: true)
            }

            if request.method == "POST", request.path == "/__manager/reload" {
                _ = try await MainActor.run { try runtime.reloadProxyRuntime() }
                return .json(status: 200, body: ["ok": true], allowsCORS: true)
            }

            if request.method == "GET", request.path == "/__manager/catalog" {
                let snapshot = await MainActor.run { runtime.proxySnapshot() }
                return catalogResponse(snapshot)
            }

            if request.method == "GET", case let .models(appType) = ProxyRequestPath(request.path) {
                let snapshot = await MainActor.run { runtime.modelListSnapshot() }
                return await modelsResponse(snapshot, appType: appType)
            }

            if request.method == "POST", request.path == "/__manager/routes" {
                let body = try jsonObject(request.body)
                guard
                    let logicalModel = body["logicalModel"] as? String,
                    let providerRefText = body["providerRef"] as? String,
                    let providerRef = ProviderRef(description: providerRefText)
                else {
                    return .json(status: 400, body: ["error": "logicalModel and providerRef are required"], allowsCORS: true)
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

            return .json(status: 404, body: ["error": "Not found"], allowsCORS: true)
        } catch {
            return .json(status: 500, body: ["error": error.localizedDescription], allowsCORS: true)
        }
    }

    private func proxy(_ request: HTTPRequest, on connection: NWConnection) async {
        let startedAt = Date()
        let requestID = Self.makeRequestID()
        var requestAppType: String?
        var providerFailureAppType: String?
        var providerFailureContext: String?
        var resolvedContext: String?
        var metricKey: RequestMetricKey?
        var statusCode: Int?
        var responseHeadersSent = false
        var networkPolicyLog = "networkPolicy=-"
        do {
            let snapshot = await MainActor.run { runtime.proxySnapshot() }
            guard let route = proxyRoute(for: request.path) else {
                send(.json(status: 404, body: ["error": "Not found"]), on: connection)
                return
            }
            requestAppType = route.appType
            await recordProxyLog(
                requestID: requestID,
                phase: "received",
                message: "path=\(request.path) app=\(route.appType) inboundModel=\(Self.requestedModel(in: request.body) ?? "<missing>") bodyBytes=\(request.body.count) stream=\(Self.requestWantsStream(request.body))"
            )
            let resolved = try ProxyResolver.resolveRoute(
                catalog: snapshot.catalog,
                routes: snapshot.routes,
                protocolKind: route.protocolKind,
                appType: route.appType,
                path: request.path,
                body: request.body
            )
            providerFailureAppType = resolved.candidate.appType
            providerFailureContext = resolved.providerName
            resolvedContext = Self.resolvedContext(for: resolved)
            metricKey = Self.metricKey(for: resolved)
            let networkPolicy = NetworkPolicyResolver.effectiveMode(
                preferences: snapshot.networkPolicy,
                providerRef: resolved.candidate.upstreamProviderRef,
                host: resolved.upstreamURL.host
            )
            networkPolicyLog = "networkPolicy=\(networkPolicy.rawValue)"
            await MainActor.run {
                runtime.recordForwardedRequest(appType: route.appType)
            }
            await recordProxyLog(
                requestID: requestID,
                phase: "resolved",
                message: "\(networkPolicyLog) \(Self.resolvedContext(for: resolved))"
            )

            var upstreamRequest = URLRequest(url: resolved.upstreamURL)
            upstreamRequest.httpMethod = "POST"
            upstreamRequest.httpBody = resolved.body
            upstreamRequest.timeoutInterval = Self.upstreamRequestTimeout
            upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")

            for (key, value) in copyAllowedHeaders(request.headers) {
                upstreamRequest.setValue(value, forHTTPHeaderField: key)
            }
            for (key, value) in resolved.headers {
                upstreamRequest.setValue(value, forHTTPHeaderField: key)
            }

            await recordProxyLog(
                requestID: requestID,
                phase: "upstream-start",
                message: "method=POST timeoutSeconds=\(Int(Self.upstreamRequestTimeout)) \(networkPolicyLog) \(Self.resolvedContext(for: resolved))"
            )
            let upstreamStartedAt = Date()
            let upstreamSession = NetworkPolicySession.makeSession(for: networkPolicy)
            let (bytes, response) = try await upstreamSession.bytes(for: upstreamRequest)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            statusCode = status
            let headers = forwardResponseHeaders(http)
            let providerFailure = Self.isProviderFailureStatus(status)
            await recordProxyLog(
                requestID: requestID,
                phase: "upstream-headers",
                message: "status=\(status) providerFailure=\(providerFailure) contentType=\(Self.headerValue(headers, name: "content-type") ?? "-") \(networkPolicyLog) \(Self.resolvedContext(for: resolved))"
            )
            await MainActor.run {
                if providerFailure {
                    runtime.proxyProviderDidFail(
                        appType: resolved.candidate.appType,
                        message: "\(providerFailureContext ?? resolved.providerName) 返回 HTTP \(status)"
                    )
                }
            }
            if resolved.responseTransform != .none {
                try await sendTransformedResponse(
                    bytes: bytes,
                    status: status,
                    headers: headers,
                    resolved: resolved,
                    on: connection
                )
                await MainActor.run {
                    if !providerFailure, status >= 200 && status < 400 {
                        runtime.proxyProviderDidSucceed()
                    }
                    runtime.recordRequestMetric(
                        key: Self.metricKey(for: resolved),
                        statusCode: status,
                        latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        errorMessage: providerFailure ? "HTTP \(status)" : nil,
                        providerFailure: providerFailure
                    )
                }
                await recordProxyLog(
                    level: providerFailure ? .error : .info,
                    requestID: requestID,
                    phase: "transform-complete",
                    message: "status=\(status) durationMs=\(Int(Self.elapsedMilliseconds(since: startedAt))) \(networkPolicyLog) \(Self.resolvedContext(for: resolved))"
                )
                return
            }
            let head = HTTPResponseHead(
                status: status,
                headers: headers
            )
            do {
                try await sendHead(head, on: connection)
            } catch {
                throw ProxyTransferError.downstream(error, stats: ProxyStreamStats())
            }
            responseHeadersSent = true
            let stats = try await streamResponse(
                bytes: bytes,
                to: connection,
                requestID: requestID,
                upstreamStartedAt: upstreamStartedAt,
                networkPolicyLog: networkPolicyLog
            )
            let sseFailure = stats.sseFailureDetail
                ?? (stats.sawSSEFailure ? "response.failed event received without data" : nil)
            let completedProviderFailure = providerFailure || sseFailure != nil
            await MainActor.run {
                if let sseFailure {
                    runtime.proxyProviderDidFail(
                        appType: resolved.candidate.appType,
                        message: "\(providerFailureContext ?? resolved.providerName)：SSE response.failed：\(sseFailure)"
                    )
                } else if !providerFailure, status >= 200 && status < 400 {
                    runtime.proxyProviderDidSucceed()
                }
                runtime.recordRequestMetric(
                    key: Self.metricKey(for: resolved),
                    statusCode: status,
                    latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    errorMessage: sseFailure.map { "SSE response.failed: \($0)" } ?? (providerFailure ? "HTTP \(status)" : nil),
                    providerFailure: completedProviderFailure
                )
            }
            await recordProxyLog(
                level: completedProviderFailure ? .error : .info,
                requestID: requestID,
                phase: "stream-complete",
                message: "status=\(status) durationMs=\(Int(Self.elapsedMilliseconds(since: startedAt))) firstByteMs=\(Self.optionalMilliseconds(stats.firstByteLatencyMilliseconds)) bytes=\(stats.bytesForwarded) chunks=\(stats.chunksForwarded) lines=\(stats.linesObserved) sseFailed=\(sseFailure != nil) sseFailureSinceLastChunkMs=\(Self.optionalMilliseconds(stats.sseFailureSinceLastChunkMilliseconds)) \(networkPolicyLog) \(Self.resolvedContext(for: resolved))"
            )
            connection.cancel()
        } catch let error as ProxyResolverError {
            let model = Self.requestedModel(in: request.body) ?? "<missing>"
            await MainActor.run {
                runtime.recordProxyEvent(
                    level: .error,
                    message: Self.issueMessage(
                        appType: requestAppType,
                        group: "代理异常",
                        detail: "requestId=\(requestID) phase=resolve-error path=\(request.path) model=\(model) failed: \(error.localizedDescription)"
                    )
                )
                if let metricKey {
                    runtime.recordRequestMetric(
                        key: metricKey,
                        statusCode: Self.statusCode(for: error),
                        latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        errorMessage: error.localizedDescription,
                        providerFailure: false
                    )
                }
            }
            send(
                Self.proxyResolverErrorResponse(error),
                on: connection
            )
        } catch let error as ProxyTransferError {
            switch error {
            case let .downstream(sendError, stats):
                await MainActor.run {
                    if let metricKey {
                        runtime.recordRequestMetric(
                            key: metricKey,
                            statusCode: 499,
                            latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                            errorMessage: Self.logSafeError(sendError),
                            providerFailure: false
                        )
                    }
                }
                await recordProxyLog(
                    requestID: requestID,
                    phase: "downstream-disconnected",
                    message: "status=\(statusCode.map(String.init) ?? "-") durationMs=\(Int(Self.elapsedMilliseconds(since: startedAt))) firstByteMs=\(Self.optionalMilliseconds(stats.firstByteLatencyMilliseconds)) bytes=\(stats.bytesForwarded) chunks=\(stats.chunksForwarded) errorKind=\(Self.transportErrorKind(sendError)) error=\(Self.logSafeError(sendError)) \(networkPolicyLog) \(resolvedContext ?? "unresolved")"
                )
                connection.cancel()
            case let .upstream(streamError, stats):
                let metricStatus = Self.statusCode(forTransportError: streamError, fallback: statusCode ?? 502)
                await MainActor.run {
                    if let providerFailureAppType, let providerFailureContext {
                        runtime.proxyProviderDidFail(
                            appType: providerFailureAppType,
                            message: "\(providerFailureContext)：\(Self.logSafeError(streamError))"
                        )
                    }
                    if let metricKey {
                        runtime.recordRequestMetric(
                            key: metricKey,
                            statusCode: metricStatus,
                            latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                            errorMessage: Self.logSafeError(streamError),
                            providerFailure: providerFailureContext != nil
                        )
                    }
                }
                await recordProxyLog(
                    level: .error,
                    requestID: requestID,
                    phase: "upstream-stream-error",
                    message: "status=\(statusCode.map(String.init) ?? "-") metricStatus=\(metricStatus) durationMs=\(Int(Self.elapsedMilliseconds(since: startedAt))) firstByteMs=\(Self.optionalMilliseconds(stats.firstByteLatencyMilliseconds)) sinceLastChunkMs=\(Self.optionalMilliseconds(stats.upstreamErrorSinceLastChunkMilliseconds)) bytes=\(stats.bytesForwarded) chunks=\(stats.chunksForwarded) errorKind=\(Self.transportErrorKind(streamError)) error=\(Self.logSafeError(streamError)) \(networkPolicyLog) \(resolvedContext ?? "unresolved")"
                )
                connection.cancel()
            }
        } catch {
            let metricStatus = Self.statusCode(forTransportError: error, fallback: 502)
            await MainActor.run {
                if let providerFailureAppType, let providerFailureContext {
                    runtime.proxyProviderDidFail(
                        appType: providerFailureAppType,
                        message: "\(providerFailureContext)：\(Self.logSafeError(error))"
                    )
                } else {
                    runtime.proxyProviderDidFail(Self.logSafeError(error))
                    runtime.recordProxyEvent(
                        level: .error,
                        message: Self.issueMessage(
                            appType: requestAppType,
                            group: "代理异常",
                            detail: "requestId=\(requestID) phase=proxy-error path=\(request.path) \(networkPolicyLog) \(resolvedContext ?? "unresolved") errorKind=\(Self.transportErrorKind(error)) error=\(Self.logSafeError(error))"
                        )
                    )
                }
                if let metricKey {
                    runtime.recordRequestMetric(
                        key: metricKey,
                        statusCode: metricStatus,
                        latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        errorMessage: Self.logSafeError(error),
                        providerFailure: providerFailureContext != nil
                    )
                }
            }
            await recordProxyLog(
                level: .error,
                requestID: requestID,
                phase: "upstream-request-error",
                message: "status=\(statusCode.map(String.init) ?? "-") metricStatus=\(metricStatus) headersSent=\(responseHeadersSent) durationMs=\(Int(Self.elapsedMilliseconds(since: startedAt))) errorKind=\(Self.transportErrorKind(error)) error=\(Self.logSafeError(error)) \(networkPolicyLog) \(resolvedContext ?? "unresolved")"
            )
            if responseHeadersSent {
                connection.cancel()
            } else {
                send(.json(status: metricStatus, body: ["error": error.localizedDescription]), on: connection)
            }
        }
    }

    private func streamResponse(
        bytes: URLSession.AsyncBytes,
        to connection: NWConnection,
        requestID: String,
        upstreamStartedAt: Date,
        networkPolicyLog: String
    ) async throws -> ProxyStreamStats {
        var stats = ProxyStreamStats()
        var buffer = Data()
        buffer.reserveCapacity(8_192)
        var inspector = SSEFailureInspector()

        do {
            for try await byte in bytes {
                let now = Date()
                if stats.firstByteLatencyMilliseconds == nil {
                    stats.firstByteLatencyMilliseconds = Int(max(now.timeIntervalSince(upstreamStartedAt) * 1000, 0))
                }
                buffer.append(byte)
                if byte == 10 {
                    stats.linesObserved += 1
                }
                if let failureDetail = inspector.append(byte) {
                    stats.sawSSEFailure = true
                    stats.sseFailureDetail = failureDetail
                    stats.sseFailureSinceLastChunkMilliseconds = Self.milliseconds(from: stats.lastChunkForwardedAt, to: now)
                    await recordProxyLog(
                        level: .error,
                        requestID: requestID,
                        phase: "sse-response-failed",
                        message: "firstByteMs=\(Self.optionalMilliseconds(stats.firstByteLatencyMilliseconds)) sinceLastChunkMs=\(Self.optionalMilliseconds(stats.sseFailureSinceLastChunkMilliseconds)) \(networkPolicyLog) \(failureDetail)"
                    )
                }
                if buffer.count >= 8_192 || byte == 10 {
                    do {
                        try await send(buffer, on: connection)
                    } catch {
                        throw ProxyTransferError.downstream(error, stats: stats)
                    }
                    stats.bytesForwarded += buffer.count
                    stats.chunksForwarded += 1
                    stats.lastChunkForwardedAt = Date()
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        } catch let error as ProxyTransferError {
            throw error
        } catch {
            stats.upstreamErrorSinceLastChunkMilliseconds = Self.milliseconds(from: stats.lastChunkForwardedAt, to: Date())
            throw ProxyTransferError.upstream(error, stats: stats)
        }

        if !buffer.isEmpty {
            do {
                try await send(buffer, on: connection)
            } catch {
                throw ProxyTransferError.downstream(error, stats: stats)
            }
            stats.bytesForwarded += buffer.count
            stats.chunksForwarded += 1
            stats.lastChunkForwardedAt = Date()
        }
        return stats
    }

    private static func metricKey(for resolved: ResolvedRoute) -> RequestMetricKey {
        RequestMetricKey(
            appType: resolved.routeKey.appType,
            routeKey: resolved.routeKey.description,
            providerRef: resolved.candidate.providerRef.description,
            providerName: resolved.providerName
        )
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Double {
        max(Date().timeIntervalSince(startedAt) * 1000, 0)
    }

    private static func milliseconds(from startedAt: Date?, to endedAt: Date) -> Int? {
        guard let startedAt else {
            return nil
        }
        return Int(max(endedAt.timeIntervalSince(startedAt) * 1000, 0))
    }

    private static func optionalMilliseconds(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private func recordProxyLog(
        level: ProxyEvent.Level = .info,
        requestID: String,
        phase: String,
        message: String
    ) async {
        await MainActor.run {
            runtime.recordProxyEvent(
                level: level,
                message: "requestId=\(requestID) phase=\(phase) \(message)"
            )
        }
    }

    private static func makeRequestID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private static func requestWantsStream(_ body: Data) -> Bool {
        guard
            let value = try? JSONSerialization.jsonObject(with: body),
            let object = value as? [String: Any],
            let stream = object["stream"] as? Bool
        else {
            return false
        }
        return stream
    }

    private static func resolvedContext(for resolved: ResolvedRoute) -> String {
        [
            "model=\(resolved.requestedModel)",
            "routeKey=\(resolved.routeKey.description)",
            "provider=\(resolved.providerName)",
            "providerRef=\(resolved.candidate.providerRef.description)",
            "upstreamProviderRef=\(resolved.candidate.upstreamProviderRef.description)",
            "upstreamModel=\(resolved.outboundModel)",
            "url=\(resolved.upstreamURL.absoluteString)"
        ].joined(separator: " ")
    }

    private static func requestedModel(in body: Data) -> String? {
        guard
            let value = try? JSONSerialization.jsonObject(with: body),
            let object = value as? [String: Any],
            let model = object["model"] as? String
        else {
            return nil
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isProviderFailureStatus(_ status: Int) -> Bool {
        status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
    }

    private static func statusCode(forTransportError error: Error, fallback: Int) -> Int {
        switch transportErrorKind(error) {
        case "timeout":
            return 504
        default:
            return fallback
        }
    }

    private static func transportErrorKind(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timeout"
            case .cancelled:
                return "cancelled"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "connectivity"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "tls"
            case .networkConnectionLost, .notConnectedToInternet:
                return "network"
            default:
                return "url-error-\(urlError.errorCode)"
            }
        }

        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                return "nw-posix-\(code.rawValue)"
            case .dns:
                return "nw-dns"
            case .tls:
                return "nw-tls"
            case .wifiAware:
                return "nw-wifi-aware"
            @unknown default:
                return "nw-unknown"
            }
        }

        return String(describing: type(of: error))
    }

    private static func logSafeError(_ error: Error) -> String {
        error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func headerValue(_ headers: [String: String], name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func proxyResolverErrorResponse(
        _ error: ProxyResolverError
    ) -> HTTPResponse {
        .json(status: statusCode(for: error), body: [
            "error": [
                "message": error.localizedDescription,
                "type": errorType(for: error),
                "code": errorCode(for: error),
                "param": "model"
            ]
        ])
    }

    private static func statusCode(for error: ProxyResolverError) -> Int {
        switch error {
        case .noRoute, .unavailableRouteTarget:
            return 404
        case .invalidJSONBody, .missingModel, .transformRequired, .streamingTransformUnsupported, .invalidUpstreamURL:
            return 400
        case .missingProvider, .missingBaseURL:
            return 502
        }
    }

    private static func errorType(for error: ProxyResolverError) -> String {
        switch error {
        case .noRoute, .unavailableRouteTarget:
            return "invalid_request_error"
        case .missingProvider, .missingBaseURL:
            return "proxy_error"
        default:
            return "invalid_request_error"
        }
    }

    private static func errorCode(for error: ProxyResolverError) -> String {
        switch error {
        case .noRoute:
            return "model_not_found"
        case .unavailableRouteTarget:
            return "route_target_unavailable"
        case .missingModel:
            return "missing_model"
        case .invalidJSONBody:
            return "invalid_json"
        case .transformRequired:
            return "unsupported_protocol"
        case .streamingTransformUnsupported:
            return "unsupported_streaming_transform"
        case .missingProvider:
            return "missing_provider"
        case .missingBaseURL:
            return "missing_base_url"
        case .invalidUpstreamURL:
            return "invalid_upstream_url"
        }
    }

    private static func issueMessage(appType: String?, group: String, detail: String) -> String {
        let appName = appType.map(ProviderDisplay.appTypeLabel) ?? "Uni Gate"
        return "\(appName) · \(group)：\(detail)"
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
                "displayModelName": candidate.displayModelName,
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
                "supportsLongContext": candidate.supportsLongContext,
                "source": candidate.source.rawValue
            ]
        }

        return .json(status: 200, body: [
            "providers": providers,
            "candidates": candidates,
            "routes": routeDictionary(snapshot.routes)
        ], allowsCORS: true)
    }

    private func routesResponse(_ snapshot: ProxyRuntimeSnapshot) -> HTTPResponse {
        .json(status: 200, body: [
            "ok": true,
            "routes": routeDictionary(snapshot.routes)
        ], allowsCORS: true)
    }

    private func modelsResponse(_ snapshot: ProxyRuntimeSnapshot, appType: String?) async -> HTTPResponse {
        let appType = appType ?? "codex"
        let routeKeys = ProviderModelListing.routeKeys(from: snapshot.catalog, appType: appType)
        let modelIDs = Array(Set(routeKeys.map(\.logicalModel))).sorted()
        let data = modelIDs.map { ["id": $0, "object": "model"] }
        let models: Any = appType == UniGateAppRegistry.codex
            ? codexModelCatalog(routeKeys: routeKeys, candidates: snapshot.catalog.candidates)
            : modelIDs
        return .json(status: 200, body: [
            "object": "list",
            "data": data,
            "models": models
        ], allowsCORS: true)
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
    let allowsCORS: Bool

    init(status: Int, headers: [String: String], body: Data, allowsCORS: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.allowsCORS = allowsCORS
    }

    static func json(status: Int, body: [String: Any], allowsCORS: Bool = false) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: data + Data("\n".utf8),
            allowsCORS: allowsCORS
        )
    }

    static func empty(status: Int, allowsCORS: Bool = false) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: Data(), allowsCORS: allowsCORS)
    }

    var data: Data {
        var response = "HTTP/1.1 \(status) \(httpReasonPhrase(status))\r\n"
        var mergedHeaders = headers
        mergedHeaders["content-length"] = "\(body.count)"
        mergedHeaders["connection"] = "close"
        if allowsCORS {
            addLocalCORSHeaders(to: &mergedHeaders)
        }
        for (key, value) in mergedHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8) + body
    }
}

private struct SSEFailureInspector {
    private var currentLine = Data()
    private var currentEvent: String?
    private var currentDataLines: [String] = []

    mutating func append(_ byte: UInt8) -> String? {
        if byte == 10 {
            defer { currentLine.removeAll(keepingCapacity: true) }
            if currentLine.last == 13 {
                currentLine.removeLast()
            }
            guard let line = String(data: currentLine, encoding: .utf8) else {
                return nil
            }
            return processLine(line)
        }
        currentLine.append(byte)
        if currentLine.count > 65_536 {
            currentLine.removeAll(keepingCapacity: true)
        }
        return nil
    }

    private mutating func processLine(_ line: String) -> String? {
        if line.isEmpty {
            defer {
                currentEvent = nil
                currentDataLines.removeAll(keepingCapacity: true)
            }
            guard currentEvent == "response.failed" else {
                return nil
            }
            return failureDetail(from: currentDataLines.joined(separator: "\n"))
        }

        if line.hasPrefix(":") {
            return nil
        }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawField = parts.first else {
            return nil
        }
        let field = String(rawField)
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.first == " " {
            value.removeFirst()
        }

        switch field {
        case "event":
            currentEvent = value
        case "data":
            currentDataLines.append(value)
        default:
            break
        }
        return nil
    }

    private func failureDetail(from data: String) -> String {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "response.failed"
        }
        guard
            let jsonData = trimmed.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: jsonData),
            let object = value as? [String: Any]
        else {
            return "response.failed data=\(Self.compact(trimmed))"
        }

        var fields: [String] = []
        if let response = object["response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            appendErrorFields(error, to: &fields)
            if let status = response["status"] as? String {
                fields.append("status=\(status)")
            }
        } else if let error = object["error"] as? [String: Any] {
            appendErrorFields(error, to: &fields)
        } else if let type = object["type"] as? String {
            fields.append("type=\(type)")
        }

        if fields.isEmpty {
            fields.append("data=\(Self.compact(trimmed))")
        }
        return "response.failed \(fields.joined(separator: " "))"
    }

    private func appendErrorFields(_ error: [String: Any], to fields: inout [String]) {
        for key in ["message", "type", "code", "param"] {
            guard let value = error[key] else {
                continue
            }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                fields.append("\(key)=\(Self.compact(text))")
            }
        }
    }

    private static func compact(_ value: String, limit: Int = 320) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard oneLine.count > limit else {
            return oneLine
        }
        let endIndex = oneLine.index(oneLine.startIndex, offsetBy: limit)
        return String(oneLine[..<endIndex]) + "..."
    }
}

private struct HTTPResponseHead {
    let status: Int
    let headers: [String: String]

    var data: Data {
        var response = "HTTP/1.1 \(status) \(httpReasonPhrase(status))\r\n"
        var mergedHeaders = headers
        mergedHeaders["connection"] = "close"
        for (key, value) in mergedHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8)
    }
}

private func addLocalCORSHeaders(to headers: inout [String: String]) {
    headers["access-control-allow-origin"] = "*"
    headers["access-control-allow-methods"] = "GET,POST,OPTIONS"
    headers["access-control-allow-headers"] = "content-type,authorization"
}

private func httpReasonPhrase(_ status: Int) -> String {
    switch status {
    case 200:
        return "OK"
    case 204:
        return "No Content"
    case 400:
        return "Bad Request"
    case 404:
        return "Not Found"
    case 408:
        return "Request Timeout"
    case 409:
        return "Conflict"
    case 413:
        return "Payload Too Large"
    case 425:
        return "Too Early"
    case 429:
        return "Too Many Requests"
    case 500:
        return "Internal Server Error"
    case 502:
        return "Bad Gateway"
    case 503:
        return "Service Unavailable"
    case 504:
        return "Gateway Timeout"
    default:
        return "OK"
    }
}
