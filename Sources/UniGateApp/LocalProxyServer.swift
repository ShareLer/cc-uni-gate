import UniGateCore
import Foundation
import Network

protocol CodexOfficialAuthorizing: Sendable {
    func authorization(
        for providerRef: ProviderRef,
        forceRefresh: Bool,
        rejectingAccessToken: String?,
        rejectingAuthorizationFingerprint: String?
    ) async throws -> CodexOAuthUpstreamAuthorization
    func markExpired(
        for providerRef: ProviderRef,
        rejectingAccessToken: String?,
        rejectingAuthorizationFingerprint: String?
    ) async -> Bool
}

extension CodexOAuthManager: CodexOfficialAuthorizing {}

@MainActor
protocol LocalProxyRuntime: AnyObject {
    func proxySnapshot() -> ProxyRuntimeSnapshot
    // Claude model listing keeps the full imported catalog. Codex listing uses
    // the effective catalog so disabled routes disappear from /v1/models.
    func modelListSnapshot() -> ProxyRuntimeSnapshot
    func localProxyClientTokens() -> Set<String>
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
    func codexOfficialAuthorizationDidExpire(providerRef: ProviderRef)
    func proxyListenerDidChange(_ state: ProxyListenerState, serverID: UUID)
}

extension LocalProxyRuntime {
    func localProxyClientTokens() -> Set<String> { [] }
    func codexOfficialAuthorizationDidExpire(providerRef: ProviderRef) {}
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
    typealias UpstreamSessionFactory = @Sendable (
        _ mode: NetworkPolicyMode,
        _ originURL: URL,
        _ isCodexOfficial: Bool
    ) -> URLSession

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
        var upstreamUsage: UpstreamUsageSummary?
    }

    private struct ProxyTransformedResponseResult {
        let status: Int
        let upstreamUsage: UpstreamUsageSummary?
    }

    private enum ProxyTransferError: Error {
        case downstream(Error, stats: ProxyStreamStats)
        case upstream(Error, stats: ProxyStreamStats)
    }

    private enum CodexOfficialAuthorizationError: Error, LocalizedError {
        case localProxyCredentialRejected
        case notLoggedIn
        case refreshFailed
        case accountChanged
        case browserOriginDenied

        var statusCode: Int {
            switch self {
            case .localProxyCredentialRejected, .notLoggedIn, .refreshFailed:
                return 401
            case .accountChanged:
                return 409
            case .browserOriginDenied:
                return 403
            }
        }

        var responseCode: String {
            switch self {
            case .localProxyCredentialRejected:
                return "codex_local_proxy_credential_invalid"
            case .notLoggedIn:
                return "codex_not_logged_in"
            case .refreshFailed:
                return "codex_login_expired"
            case .accountChanged:
                return "codex_account_changed"
            case .browserOriginDenied:
                return "codex_browser_origin_denied"
            }
        }

        var errorDescription: String? {
            switch self {
            case .localProxyCredentialRejected:
                return "Codex 官方路由需要当前 UniGate 安装的本地凭据，请在 UniGate 设置中重新导入 cc-switch 供应商。"
            case .notLoggedIn:
                return "Codex 官方供应商尚未登录，请先在 UniGate 中完成登录。"
            case .refreshFailed:
                return "Codex 官方登录已失效或刷新失败，请重新登录。"
            case .accountChanged:
                return "Codex 账号在请求期间已变更，为避免跨账号重放，请重试该请求。"
            case .browserOriginDenied:
                return "Codex 官方订阅不接受来自网页的本地代理请求。"
            }
        }
    }

    private struct UpstreamTransportErrorContext: Sendable {
        let model: String
        let routeKey: String
        let provider: String
        let providerRef: String
        let upstreamProviderRef: String
        let upstreamModel: String
        let upstreamURL: String
    }

    let id = UUID()
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let runtime: any LocalProxyRuntime
    private let managerToken: String?
    private let localProxyToken: String?
    private let codexOfficialAuthorizer: (any CodexOfficialAuthorizing)?
    private let upstreamSessionFactory: UpstreamSessionFactory
    private let queue = DispatchQueue(label: "unigate.local-proxy")
    private var listener: NWListener?

    init(
        host: String = "127.0.0.1",
        port: UInt16 = 17888,
        runtime: any LocalProxyRuntime,
        managerToken: String? = nil,
        localProxyToken: String? = nil,
        codexOfficialAuthorizer: (any CodexOfficialAuthorizing)? = nil,
        upstreamSessionFactory: @escaping UpstreamSessionFactory = { mode, originURL, isCodexOfficial in
            if isCodexOfficial {
                return NetworkPolicySession.makeCodexOfficialSession(for: mode, originURL: originURL)
            }
            return NetworkPolicySession.makeSession(for: mode)
        }
    ) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.runtime = runtime
        self.managerToken = managerToken ?? Self.configuredManagerToken()
        self.localProxyToken = localProxyToken
        self.codexOfficialAuthorizer = codexOfficialAuthorizer
        self.upstreamSessionFactory = upstreamSessionFactory
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener = try NWListener(using: parameters)
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
            return false
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

    private func receive(on connection: NWConnection, data: Data, sentContinue: Bool = false) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var next = data
            if let chunk {
                next.append(chunk)
            }

            switch HTTPRequest.parse(next) {
            case let .complete(request):
                Task {
                    await self.handle(request, on: connection)
                }
            case .incomplete:
                if !sentContinue, HTTPRequest.expectsContinue(next) {
                let pendingData = next
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
                    self?.receive(on: connection, data: pendingData, sentContinue: true)
                })
                } else if next.count > 10_485_760 {
                    send(.json(status: 413, body: ["error": "Request too large"], allowsCORS: true), on: connection)
                } else if error != nil || isComplete {
                    connection.cancel()
                } else {
                    receive(on: connection, data: next, sentContinue: sentContinue)
                }
            case let .malformed(message):
                send(.json(status: 400, body: ["error": message], allowsCORS: true), on: connection)
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
                    "candidates": snapshot.catalog.candidates.count,
                    "managerAuth": [
                        "mutatingRequests": "bearer",
                        "tokenConfigured": managerToken != nil
                    ]
                ], allowsCORS: true)
            }

            if request.method == "POST", request.path == "/__manager/reload" {
                if let failure = managerAuthorizationFailure(for: request) {
                    return failure
                }
                _ = try await MainActor.run { try runtime.reloadProxyRuntime() }
                return .json(status: 200, body: ["ok": true], allowsCORS: true)
            }

            if request.method == "GET", request.path == "/__manager/catalog" {
                let snapshot = await MainActor.run { runtime.proxySnapshot() }
                if Self.headerValue(request.headers, name: "origin") != nil,
                   snapshot.catalog.providers.contains(where: { $0.backendKind == .codexOfficial }) {
                    return .json(status: 403, body: ["error": "Browser access is denied for Codex Official metadata"])
                }
                return catalogResponse(snapshot)
            }

            if request.method == "GET", case let .models(appType) = ProxyRequestPath(request.path) {
                let snapshot = await MainActor.run { runtime.modelListSnapshot() }
                if Self.headerValue(request.headers, name: "origin") != nil,
                   snapshot.catalog.providers.contains(where: {
                       $0.backendKind == .codexOfficial && (appType == nil || $0.appType == appType)
                   }) {
                    return .json(status: 403, body: ["error": "Browser access is denied for Codex Official models"])
                }
                return await modelsResponse(snapshot, appType: appType)
            }

            if request.method == "POST", request.path == "/__manager/routes" {
                if let failure = managerAuthorizationFailure(for: request) {
                    return failure
                }
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

    private static func configuredManagerToken() -> String? {
        let token = ProcessInfo.processInfo.environment["UNIGATE_MANAGER_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    private func managerAuthorizationFailure(for request: HTTPRequest) -> HTTPResponse? {
        guard let managerToken else {
            return .json(
                status: 403,
                body: ["error": "Manager token is not configured; set UNIGATE_MANAGER_TOKEN"],
                allowsCORS: true
            )
        }
        guard
            let authorization = request.headers["authorization"],
            Self.bearerToken(from: authorization) == managerToken
        else {
            return .json(status: 401, body: ["error": "Unauthorized"], allowsCORS: true)
        }
        return nil
    }

    private static func bearerToken(from authorization: String) -> String? {
        let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func proxy(_ request: HTTPRequest, on connection: NWConnection) async {
        let startedAt = Date()
        let requestID = Self.makeRequestID()
        var requestAppType: String?
        var providerFailureAppType: String?
        var providerFailureContext: String?
        var resolvedLogFields: [LogField]?
        var metricKey: RequestMetricKey?
        var statusCode: Int?
        var responseHeadersSent = false
        var networkPolicyMode: NetworkPolicyMode?
        var networkPolicyLogFields: [LogField] = [LogField("net", "-")]
        var transportErrorContext: UpstreamTransportErrorContext?
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
                fields: [
                    LogField("app", ProviderDisplay.appTypeLabel(route.appType)),
                    LogField("path", request.path),
                    LogField("clientProtocol", route.protocolKind.rawValue),
                    LogField("inboundModel", Self.requestedModel(in: request.body) ?? "<missing>"),
                    LogField("bodyBytes", request.body.count),
                    LogField("stream", Self.requestWantsStream(request.body))
                ]
            )
            let resolved = try ProxyResolver.resolveRoute(
                catalog: snapshot.catalog,
                routes: snapshot.routes,
                protocolKind: route.protocolKind,
                appType: route.appType,
                path: request.path,
                body: request.body
            )
            if case .codexOfficial = resolved.authorizationRequirement {
                let inboundToken = Self.headerValue(request.headers, name: "authorization")
                    .flatMap { Self.bearerToken(from: $0) }
                var expectedTokens = await MainActor.run { runtime.localProxyClientTokens() }
                if let localProxyToken {
                    expectedTokens.insert(localProxyToken)
                }
                guard LocalProxyAuthorizationPolicy.allows(
                    bearerToken: inboundToken,
                    expectedTokens: expectedTokens,
                    requirement: resolved.authorizationRequirement
                ) else {
                    throw CodexOfficialAuthorizationError.localProxyCredentialRejected
                }
                if Self.headerValue(request.headers, name: "origin") != nil {
                    throw CodexOfficialAuthorizationError.browserOriginDenied
                }
            }
            providerFailureAppType = resolved.candidate.appType
            providerFailureContext = resolved.providerName
            resolvedLogFields = Self.resolvedLogFields(for: resolved)
            metricKey = Self.metricKey(for: resolved)
            let networkPolicy = NetworkPolicyResolver.effectiveMode(
                preferences: snapshot.networkPolicy,
                providerRef: resolved.candidate.upstreamProviderRef,
                host: resolved.upstreamURL.host
            )
            networkPolicyMode = networkPolicy
            transportErrorContext = Self.upstreamTransportErrorContext(for: resolved)
            networkPolicyLogFields = [LogField("net", networkPolicy.rawValue)]
            await MainActor.run {
                runtime.recordForwardedRequest(appType: route.appType)
            }
            await recordProxyLog(
                requestID: requestID,
                phase: "resolved",
                fields: Self.resolvedLogFields(for: resolved) + networkPolicyLogFields + [
                    LogField("api", resolved.candidate.apiFormat.rawValue),
                    LogField("transform", resolved.responseTransform.rawValue),
                    LogField("url", resolved.upstreamURL.absoluteString)
                ]
            )
            if resolved.responseTransform == .openAIChatToAnthropicMessages,
               Self.isAnthropicCountTokensPath(request.path) {
                let body = try jsonObject(resolved.body)
                send(.json(status: 200, body: AnthropicChatBridge.countTokensBody(fromOpenAIChatRequest: body)), on: connection)
                await MainActor.run {
                    runtime.recordRequestMetric(
                        key: Self.metricKey(for: resolved),
                        statusCode: 200,
                        latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        errorMessage: nil,
                        providerFailure: false
                    )
                }
                await recordProxyLog(
                    requestID: requestID,
                    phase: "token-count-estimate",
                    fields: Self.resolvedLogFields(for: resolved) + [
                        LogField("status", 200),
                        LogField("durationMs", Int(Self.elapsedMilliseconds(since: startedAt)))
                    ]
                )
                return
            }

            var upstreamRequest = URLRequest(url: resolved.upstreamURL)
            upstreamRequest.httpMethod = "POST"
            upstreamRequest.httpBody = resolved.body
            upstreamRequest.timeoutInterval = Self.upstreamRequestTimeout
            upstreamRequest.setValue("application/json", forHTTPHeaderField: "content-type")

            for (key, value) in copyAllowedHeaders(
                request.headers,
                responseTransform: resolved.responseTransform,
                authorizationRequirement: resolved.authorizationRequirement
            ) {
                upstreamRequest.setValue(value, forHTTPHeaderField: key)
            }
            for (key, value) in resolved.headers {
                upstreamRequest.setValue(value, forHTTPHeaderField: key)
            }
            var codexAuthorizationContext: CodexOAuthUpstreamAuthorization?
            if case let .codexOfficial(providerRef) = resolved.authorizationRequirement {
                let authorization = try await codexAuthorization(
                    for: providerRef,
                    forceRefresh: false,
                    rejectingAccessToken: nil,
                    rejectingAuthorizationFingerprint: nil
                )
                codexAuthorizationContext = authorization
                Self.apply(authorization, to: &upstreamRequest)
            }

            await recordProxyLog(
                requestID: requestID,
                phase: "upstream-start",
                fields: Self.resolvedLogFields(for: resolved) + networkPolicyLogFields + [
                    LogField("method", "POST"),
                    LogField("timeoutSeconds", Int(Self.upstreamRequestTimeout))
                ]
            )
            let upstreamStartedAt = Date()
            let isCodexOfficial: Bool
            if case .codexOfficial = resolved.authorizationRequirement {
                isCodexOfficial = true
            } else {
                isCodexOfficial = false
            }
            var upstreamSession = upstreamSessionFactory(
                networkPolicy,
                resolved.upstreamURL,
                isCodexOfficial
            )
            defer {
                if isCodexOfficial {
                    upstreamSession.finishTasksAndInvalidate()
                }
            }
            var upstreamResult = try await upstreamSession.bytes(for: upstreamRequest)
            if case let .codexOfficial(providerRef) = resolved.authorizationRequirement,
               (upstreamResult.1 as? HTTPURLResponse)?.statusCode == 401 {
                upstreamSession.invalidateAndCancel()
                let authorization = try await codexAuthorization(
                    for: providerRef,
                    forceRefresh: true,
                    rejectingAccessToken: codexAuthorizationContext?.accessToken,
                    rejectingAuthorizationFingerprint: codexAuthorizationContext?.authorizationFingerprint
                )
                Self.apply(authorization, to: &upstreamRequest)
                upstreamSession = upstreamSessionFactory(
                    networkPolicy,
                    resolved.upstreamURL,
                    true
                )
                upstreamResult = try await upstreamSession.bytes(for: upstreamRequest)
                if (upstreamResult.1 as? HTTPURLResponse)?.statusCode == 401 {
                    _ = await codexOfficialAuthorizer?.markExpired(
                        for: providerRef,
                        rejectingAccessToken: authorization.accessToken,
                        rejectingAuthorizationFingerprint: authorization.authorizationFingerprint
                    )
                    await MainActor.run {
                        runtime.codexOfficialAuthorizationDidExpire(providerRef: providerRef)
                    }
                }
            }
            let (bytes, response) = upstreamResult
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            statusCode = status
            let headers = ProxyResponseHeaderPolicy.forwardedHeaders(
                from: http,
                stripCookies: isCodexOfficial
            )
            let providerFailure = Self.isProviderFailureStatus(status)
            await recordProxyLog(
                requestID: requestID,
                phase: "upstream-headers",
                fields: Self.resolvedLogFields(for: resolved) + networkPolicyLogFields + [
                    LogField("status", status),
                    LogField("providerFailure", providerFailure),
                    LogField("contentType", Self.headerValue(headers, name: "content-type"))
                ]
            )
            await MainActor.run {
                if providerFailure {
                    runtime.proxyProviderDidFail(
                        appType: resolved.candidate.appType,
                        message: "\(providerFailureContext ?? resolved.providerName) 返回 HTTP \(status)"
                    )
                }
            }
            if resolved.responseTransform == .openAIChatToAnthropicMessages,
               status >= 200 && status < 300,
               Self.isEventStream(headers) {
                var responseHeaders = headers
                removeEntityHeaders(from: &responseHeaders)
                responseHeaders["content-type"] = "text/event-stream; charset=utf-8"
                responseHeaders["cache-control"] = "no-cache"
                do {
                    try await sendHead(HTTPResponseHead(status: status, headers: responseHeaders), on: connection)
                } catch {
                    throw ProxyTransferError.downstream(error, stats: ProxyStreamStats())
                }
                responseHeadersSent = true
                let stats = try await streamOpenAIChatAsAnthropicSSE(
                    bytes: bytes,
                    resolved: resolved,
                    to: connection,
                    upstreamStartedAt: upstreamStartedAt
                )
                let transformedStreamFailure = stats.sseFailureDetail
                await MainActor.run {
                    if let transformedStreamFailure {
                        runtime.proxyProviderDidFail(
                            appType: resolved.candidate.appType,
                            message: "\(providerFailureContext ?? resolved.providerName)：SSE error：\(transformedStreamFailure)"
                        )
                    } else if !providerFailure {
                        runtime.proxyProviderDidSucceed()
                    }
                    runtime.recordRequestMetric(
                        key: Self.metricKey(for: resolved),
                        statusCode: status,
                        latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        errorMessage: transformedStreamFailure.map { "SSE error: \($0)" },
                        providerFailure: transformedStreamFailure != nil
                    )
                }
                await recordProxyLog(
                    level: transformedStreamFailure == nil ? .info : .error,
                    requestID: requestID,
                    phase: "transform-stream-complete",
                    fields: Self.resolvedLogFields(for: resolved) + networkPolicyLogFields + [
                        LogField("status", status),
                        LogField("outcome", transformedStreamFailure == nil ? "ok" : "sse_error"),
                        LogField("durationMs", Int(Self.elapsedMilliseconds(since: startedAt))),
                        LogField("firstByteMs", stats.firstByteLatencyMilliseconds),
                        LogField("bytes", stats.bytesForwarded),
                        LogField("chunks", stats.chunksForwarded),
                        LogField("error", transformedStreamFailure)
                    ] + Self.usageLogFields(stats.upstreamUsage)
                )
                connection.cancel()
                return
            }
            if resolved.responseTransform != .none {
                let transformedResponse = try await sendTransformedResponse(
                    bytes: bytes,
                    status: status,
                    headers: headers,
                    resolved: resolved,
                    on: connection
                )
                let transformedStatus = transformedResponse.status
                let transformedRequestFailure = transformedStatus < 200 || transformedStatus >= 400
                let transformedProviderFailure = providerFailure || Self.isProviderFailureStatus(transformedStatus)
                await MainActor.run {
                    if !transformedProviderFailure, transformedStatus >= 200 && transformedStatus < 400 {
                        runtime.proxyProviderDidSucceed()
                    }
                    runtime.recordRequestMetric(
                        key: Self.metricKey(for: resolved),
                        statusCode: transformedStatus,
                        latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        errorMessage: transformedRequestFailure ? "HTTP \(transformedStatus)" : nil,
                        providerFailure: transformedProviderFailure
                    )
                }
                await recordProxyLog(
                    level: transformedRequestFailure ? .error : .info,
                    requestID: requestID,
                    phase: "transform-complete",
                    fields: Self.resolvedLogFields(for: resolved) + networkPolicyLogFields + [
                        LogField("status", transformedStatus),
                        LogField("upstreamStatus", status),
                        LogField(
                            "outcome",
                            transformedProviderFailure ? "provider_failure" : (transformedRequestFailure ? "request_failure" : "ok")
                        ),
                        LogField("durationMs", Int(Self.elapsedMilliseconds(since: startedAt)))
                    ] + Self.usageLogFields(transformedResponse.upstreamUsage)
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
                contextFields: Self.resolvedLogFields(for: resolved),
                networkPolicyLogFields: networkPolicyLogFields
            )
            let sseFailure = stats.sseFailureDetail
                ?? (stats.sawSSEFailure ? "response.failed event received without data" : nil)
            let completedProviderFailure = providerFailure || sseFailure != nil
            await MainActor.run {
                if let sseFailure {
                    runtime.proxyProviderDidFail(
                        appType: resolved.candidate.appType,
                        message: "\(providerFailureContext ?? resolved.providerName)：SSE error：\(sseFailure)"
                    )
                } else if !providerFailure, status >= 200 && status < 400 {
                    runtime.proxyProviderDidSucceed()
                }
                runtime.recordRequestMetric(
                    key: Self.metricKey(for: resolved),
                    statusCode: status,
                    latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    errorMessage: sseFailure.map { "SSE error: \($0)" } ?? (providerFailure ? "HTTP \(status)" : nil),
                    providerFailure: completedProviderFailure
                )
            }
            await recordProxyLog(
                level: completedProviderFailure ? .error : .info,
                requestID: requestID,
                phase: "stream-complete",
                fields: Self.resolvedLogFields(for: resolved) + networkPolicyLogFields + [
                    LogField("status", status),
                    LogField("outcome", completedProviderFailure ? "provider_failure" : "ok"),
                    LogField("durationMs", Int(Self.elapsedMilliseconds(since: startedAt))),
                    LogField("firstByteMs", stats.firstByteLatencyMilliseconds),
                    LogField("bytes", stats.bytesForwarded),
                    LogField("chunks", stats.chunksForwarded),
                    LogField("lines", stats.linesObserved),
                    LogField("sseFailed", sseFailure != nil),
                    LogField("sseFailureMs", stats.sseFailureSinceLastChunkMilliseconds),
                    LogField("error", sseFailure)
                ] + Self.usageLogFields(stats.upstreamUsage)
            )
            connection.cancel()
        } catch let error as CodexOfficialAuthorizationError {
            statusCode = error.statusCode
            await MainActor.run {
                if let metricKey {
                    runtime.recordRequestMetric(
                        key: metricKey,
                        statusCode: error.statusCode,
                        latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                        errorMessage: error.localizedDescription,
                        providerFailure: false
                    )
                }
            }
            await recordProxyLog(
                level: .error,
                requestID: requestID,
                phase: "codex-auth-error",
                fields: (resolvedLogFields ?? Self.unresolvedLogFields()) + networkPolicyLogFields + [
                    LogField("status", error.statusCode),
                    LogField("error", error.localizedDescription)
                ]
            )
            send(Self.codexOfficialAuthorizationErrorResponse(error), on: connection)
        } catch let error as ProxyResolverError {
            let model = Self.requestedModel(in: request.body) ?? "<missing>"
            let fields = [
                LogField("path", request.path),
                LogField("model", model),
                LogField("error", error.localizedDescription)
            ]
            await MainActor.run {
                runtime.recordProxyEvent(
                    level: .error,
                    message: Self.issueMessage(
                        appType: requestAppType,
                        group: "代理异常",
                        detail: Self.proxyLogMessage(requestID: requestID, phase: "resolve-error", fields: fields)
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
                    fields: (resolvedLogFields ?? Self.unresolvedLogFields()) + networkPolicyLogFields + [
                        LogField("status", statusCode),
                        LogField("outcome", "client_disconnected"),
                        LogField("durationMs", Int(Self.elapsedMilliseconds(since: startedAt))),
                        LogField("firstByteMs", stats.firstByteLatencyMilliseconds),
                        LogField("bytes", stats.bytesForwarded),
                        LogField("chunks", stats.chunksForwarded),
                        LogField("errorKind", Self.transportErrorKind(sendError)),
                        LogField("error", Self.logSafeError(sendError))
                    ]
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
                    fields: (resolvedLogFields ?? Self.unresolvedLogFields()) + networkPolicyLogFields + [
                        LogField("status", statusCode),
                        LogField("metricStatus", metricStatus),
                        LogField("outcome", "upstream_stream_error"),
                        LogField("durationMs", Int(Self.elapsedMilliseconds(since: startedAt))),
                        LogField("firstByteMs", stats.firstByteLatencyMilliseconds),
                        LogField("sinceLastChunkMs", stats.upstreamErrorSinceLastChunkMilliseconds),
                        LogField("bytes", stats.bytesForwarded),
                        LogField("chunks", stats.chunksForwarded),
                        LogField("errorKind", Self.transportErrorKind(streamError)),
                        LogField("error", Self.logSafeError(streamError))
                    ]
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
                            detail: Self.proxyLogMessage(
                                requestID: requestID,
                                phase: "proxy-error",
                                fields: [
                                    LogField("path", request.path)
                                ] + networkPolicyLogFields + (resolvedLogFields ?? Self.unresolvedLogFields()) + [
                                    LogField("errorKind", Self.transportErrorKind(error)),
                                    LogField("error", Self.logSafeError(error))
                                ]
                            )
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
                fields: (resolvedLogFields ?? Self.unresolvedLogFields()) + networkPolicyLogFields + [
                    LogField("status", statusCode),
                    LogField("metricStatus", metricStatus),
                    LogField("outcome", "upstream_request_error"),
                    LogField("headersSent", responseHeadersSent),
                    LogField("durationMs", Int(Self.elapsedMilliseconds(since: startedAt))),
                    LogField("errorKind", Self.transportErrorKind(error)),
                    LogField("error", Self.logSafeError(error))
                ]
            )
            if responseHeadersSent {
                connection.cancel()
            } else {
                send(
                    Self.upstreamTransportErrorResponse(
                        status: metricStatus,
                        error: error,
                        networkPolicy: networkPolicyMode,
                        context: transportErrorContext
                    ),
                    on: connection
                )
            }
        }
    }

    private func streamResponse(
        bytes: URLSession.AsyncBytes,
        to connection: NWConnection,
        requestID: String,
        upstreamStartedAt: Date,
        contextFields: [LogField],
        networkPolicyLogFields: [LogField]
    ) async throws -> ProxyStreamStats {
        var stats = ProxyStreamStats()
        var buffer = Data()
        buffer.reserveCapacity(8_192)
        var inspector = SSEFailureInspector()
        var usageInspector = SSEUsageInspector()

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
                        fields: contextFields + networkPolicyLogFields + [
                            LogField("firstByteMs", stats.firstByteLatencyMilliseconds),
                            LogField("sinceLastChunkMs", stats.sseFailureSinceLastChunkMilliseconds),
                            LogField("error", failureDetail)
                        ]
                    )
                }
                if let usage = usageInspector.append(byte) {
                    stats.upstreamUsage = usage
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

    private func streamOpenAIChatAsAnthropicSSE(
        bytes: URLSession.AsyncBytes,
        resolved: ResolvedRoute,
        to connection: NWConnection,
        upstreamStartedAt: Date
    ) async throws -> ProxyStreamStats {
        var stats = ProxyStreamStats()
        var state = AnthropicChatStreamState()
        var lineBuffer = Data()
        var blockLines: [String] = []

        do {
            for try await byte in bytes {
                let now = Date()
                if stats.firstByteLatencyMilliseconds == nil {
                    stats.firstByteLatencyMilliseconds = Int(max(now.timeIntervalSince(upstreamStartedAt) * 1000, 0))
                }

                if byte == 10 {
                    stats.linesObserved += 1
                    let line = Self.sseLine(from: lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                    if line.isEmpty {
                        if let data = Self.sseDataPayload(from: blockLines) {
                            if let usage = UpstreamUsageSummary.fromSSEData(data) {
                                stats.upstreamUsage = usage
                            }
                            let events = try state.events(forOpenAIChatStreamData: data, fallbackModel: resolved.outboundModel)
                            for event in events {
                                if event.event == "error" {
                                    stats.sawSSEFailure = true
                                    stats.sseFailureDetail = Self.anthropicStreamErrorDetail(event)
                                }
                                let payload = try event.sseData()
                                do {
                                    try await send(payload, on: connection)
                                } catch {
                                    throw ProxyTransferError.downstream(error, stats: stats)
                                }
                                stats.bytesForwarded += payload.count
                                stats.chunksForwarded += 1
                                stats.lastChunkForwardedAt = Date()
                            }
                        }
                        blockLines.removeAll(keepingCapacity: true)
                    } else {
                        blockLines.append(line)
                    }
                } else {
                    lineBuffer.append(byte)
                    if lineBuffer.count > 1_048_576 {
                        throw AnthropicChatBridgeError.invalidChatStreamChunk
                    }
                }
            }

            if !lineBuffer.isEmpty {
                blockLines.append(Self.sseLine(from: lineBuffer))
            }
            if let data = Self.sseDataPayload(from: blockLines) {
                if let usage = UpstreamUsageSummary.fromSSEData(data) {
                    stats.upstreamUsage = usage
                }
                let events = try state.events(forOpenAIChatStreamData: data, fallbackModel: resolved.outboundModel)
                for event in events {
                    if event.event == "error" {
                        stats.sawSSEFailure = true
                        stats.sseFailureDetail = Self.anthropicStreamErrorDetail(event)
                    }
                    let payload = try event.sseData()
                    do {
                        try await send(payload, on: connection)
                    } catch {
                        throw ProxyTransferError.downstream(error, stats: stats)
                    }
                    stats.bytesForwarded += payload.count
                    stats.chunksForwarded += 1
                    stats.lastChunkForwardedAt = Date()
                }
            }

            guard state.hasTerminalChunk else {
                throw AnthropicChatBridgeError.truncatedChatStream
            }

            let finishEvents = state.finishEvents()
            for event in finishEvents {
                let payload = try event.sseData()
                do {
                    try await send(payload, on: connection)
                } catch {
                    throw ProxyTransferError.downstream(error, stats: stats)
                }
                stats.bytesForwarded += payload.count
                stats.chunksForwarded += 1
                stats.lastChunkForwardedAt = Date()
            }
        } catch let error as ProxyTransferError {
            throw error
        } catch let error as AnthropicChatBridgeError {
            stats.upstreamErrorSinceLastChunkMilliseconds = Self.milliseconds(from: stats.lastChunkForwardedAt, to: Date())
            let event = Self.anthropicStreamBridgeErrorEvent(error)
            stats.sawSSEFailure = true
            stats.sseFailureDetail = Self.anthropicStreamErrorDetail(event)
            let payload = try event.sseData()
            do {
                try await send(payload, on: connection)
            } catch {
                throw ProxyTransferError.downstream(error, stats: stats)
            }
            stats.bytesForwarded += payload.count
            stats.chunksForwarded += 1
            stats.lastChunkForwardedAt = Date()
            return stats
        } catch {
            stats.upstreamErrorSinceLastChunkMilliseconds = Self.milliseconds(from: stats.lastChunkForwardedAt, to: Date())
            throw ProxyTransferError.upstream(error, stats: stats)
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

    private func recordProxyLog(
        level: ProxyEvent.Level = .info,
        requestID: String,
        phase: String,
        fields: [LogField]
    ) async {
        await MainActor.run {
            runtime.recordProxyEvent(
                level: level,
                message: Self.proxyLogMessage(requestID: requestID, phase: phase, fields: fields)
            )
        }
    }

    private static func proxyLogMessage(requestID: String, phase: String, fields: [LogField]) -> String {
        LogFieldFormatter.format([
            LogField("event", "proxy"),
            LogField("requestId", requestID),
            LogField("phase", phase)
        ] + fields)
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

    private static func resolvedLogFields(for resolved: ResolvedRoute) -> [LogField] {
        [
            LogField("route", resolved.routeKey.description),
            LogField("model", resolved.requestedModel),
            LogField("provider", resolved.providerName),
            LogField("upstreamModel", resolved.outboundModel)
        ]
    }

    private static func usageLogFields(_ usage: UpstreamUsageSummary?) -> [LogField] {
        guard let usage else {
            return [LogField("usage", "missing")]
        }
        return [LogField("usage", "present")] + usage.logFields
    }

    private static func unresolvedLogFields() -> [LogField] {
        [
            LogField("route", "unresolved"),
            LogField("model", "unresolved"),
            LogField("provider", "unresolved"),
            LogField("upstreamModel", "unresolved")
        ]
    }

    private static func upstreamTransportErrorContext(for resolved: ResolvedRoute) -> UpstreamTransportErrorContext {
        UpstreamTransportErrorContext(
            model: resolved.requestedModel,
            routeKey: resolved.routeKey.description,
            provider: resolved.providerName,
            providerRef: resolved.candidate.providerRef.description,
            upstreamProviderRef: resolved.candidate.upstreamProviderRef.description,
            upstreamModel: resolved.outboundModel,
            upstreamURL: resolved.upstreamURL.absoluteString
        )
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

    private static func upstreamTransportErrorResponse(
        status: Int,
        error: Error,
        networkPolicy: NetworkPolicyMode?,
        context: UpstreamTransportErrorContext?
    ) -> HTTPResponse {
        let errorKind = transportErrorKind(error)
        var errorObject: [String: Any] = [
            "message": logSafeError(error),
            "type": "upstream_transport_error",
            "code": upstreamTransportErrorCode(errorKind),
            "transport_error_kind": errorKind,
            "network_policy": networkPolicy?.rawValue ?? "unknown",
            "upstream_returned_http_headers": false
        ]
        if let context {
            errorObject["model"] = context.model
            errorObject["route_key"] = context.routeKey
            errorObject["provider"] = context.provider
            errorObject["provider_ref"] = context.providerRef
            errorObject["upstream_provider_ref"] = context.upstreamProviderRef
            errorObject["upstream_model"] = context.upstreamModel
            errorObject["upstream_url"] = context.upstreamURL
        }
        return .json(status: status, body: [
            "type": "error",
            "error": errorObject
        ])
    }

    private static func upstreamTransportErrorCode(_ errorKind: String) -> String {
        switch errorKind {
        case "timeout":
            return "upstream_timeout"
        case "connectivity":
            return "upstream_connectivity_error"
        case "network":
            return "upstream_network_error"
        case "tls":
            return "upstream_tls_error"
        case "cancelled":
            return "upstream_cancelled"
        default:
            return "upstream_transport_error"
        }
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

    private static func codexOfficialAuthorizationErrorResponse(
        _ error: CodexOfficialAuthorizationError
    ) -> HTTPResponse {
        return .json(status: error.statusCode, body: [
            "error": [
                "message": error.localizedDescription,
                "type": "authentication_error",
                "code": error.responseCode
            ]
        ])
    }

    private static func statusCode(for error: ProxyResolverError) -> Int {
        switch error {
        case .noRoute, .unavailableRouteTarget:
            return 404
        case .invalidJSONBody, .invalidRequest, .missingModel, .transformRequired, .streamingTransformUnsupported,
             .invalidUpstreamURL:
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
        case .invalidRequest:
            return "invalid_request"
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
    ) async throws -> ProxyTransformedResponseResult {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > 10_485_760 {
                send(.json(status: 413, body: ["error": "Response too large"]), on: connection)
                return ProxyTransformedResponseResult(status: 413, upstreamUsage: nil)
            }
        }
        let upstreamUsage = UpstreamUsageSummary.fromBody(body)

        guard status >= 200 && status < 300 else {
            if resolved.responseTransform == .openAIChatToCodexResponse,
               let value = try? JSONSerialization.jsonObject(with: body),
               let object = value as? [String: Any] {
                var responseHeaders = headers
                removeEntityHeaders(from: &responseHeaders)
                responseHeaders["content-type"] = "application/json; charset=utf-8"
                let transformed = CodexChatBridge.responsesErrorBody(
                    fromOpenAIError: object,
                    fallbackMessage: httpReasonPhrase(status)
                )
                let responseBody = try JSONSerialization.data(withJSONObject: transformed, options: [])
                send(HTTPResponse(status: status, headers: responseHeaders, body: responseBody), on: connection)
                return ProxyTransformedResponseResult(status: status, upstreamUsage: upstreamUsage)
            }
            if resolved.responseTransform == .openAIChatToAnthropicMessages,
               let value = try? JSONSerialization.jsonObject(with: body),
               let object = value as? [String: Any] {
                var responseHeaders = headers
                removeEntityHeaders(from: &responseHeaders)
                responseHeaders["content-type"] = "application/json; charset=utf-8"
                let transformed = AnthropicChatBridge.anthropicErrorBody(
                    fromOpenAIError: object,
                    fallbackMessage: httpReasonPhrase(status)
                )
                let responseBody = try JSONSerialization.data(withJSONObject: transformed, options: [])
                send(HTTPResponse(status: status, headers: responseHeaders, body: responseBody), on: connection)
                return ProxyTransformedResponseResult(status: status, upstreamUsage: upstreamUsage)
            }
            let response = HTTPResponse(
                status: status,
                headers: headers,
                body: body
            )
            send(response, on: connection)
            return ProxyTransformedResponseResult(status: status, upstreamUsage: upstreamUsage)
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
        case .openAIChatToAnthropicMessages:
            let value = try JSONSerialization.jsonObject(with: body)
            guard let object = value as? [String: Any] else {
                throw AnthropicChatBridgeError.invalidChatResponse
            }
            let transformed = try AnthropicChatBridge.anthropicBody(
                from: object,
                fallbackModel: resolved.outboundModel
            )
            var responseHeaders = headers
            removeEntityHeaders(from: &responseHeaders)
            responseHeaders["content-type"] = "application/json; charset=utf-8"
            let responseBody = try JSONSerialization.data(withJSONObject: transformed, options: [])
            send(HTTPResponse(status: status, headers: responseHeaders, body: responseBody), on: connection)
        }
        return ProxyTransformedResponseResult(status: status, upstreamUsage: upstreamUsage)
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
        // The runtime keeps Claude listings on the full catalog while Codex uses
        // the effective route catalog so disabled Codex routes are not advertised.
        let listedRouteKeys = ProviderModelListing.routeKeys(from: snapshot.catalog, appType: appType)
        let routeKeys = appType == UniGateAppRegistry.codex
            ? listedRouteKeys.filter { routeKey in
                guard let route = snapshot.routes.routes[routeKey.description] else {
                    return false
                }
                return snapshot.catalog.candidates.contains {
                    $0.routeKey == routeKey && $0.providerRef == route.providerRef
                }
            }
            : listedRouteKeys
        let modelIDs = Array(Set(routeKeys.map(\.logicalModel))).sorted()
        let data = modelIDs.map { ["id": $0, "object": "model"] }
        let models: Any = appType == UniGateAppRegistry.codex
            ? Self.codexModelCatalog(routeKeys: routeKeys, candidates: snapshot.catalog.candidates)
            : modelIDs
        return .json(status: 200, body: [
            "object": "list",
            "data": data,
            "models": models
        ], allowsCORS: true)
    }

    static func codexModelCatalog(routeKeys: [ModelRouteKey], candidates: [ModelCandidate]) -> [[String: Any]] {
        routeKeys.map { key in
            let routeCandidates = candidates.filter {
                $0.appType == key.appType && $0.logicalModel == key.logicalModel
            }
            let hasSyntheticCandidates = routeCandidates.contains { $0.providerRef != $0.upstreamProviderRef }
            let displayName = routeCandidates
                .compactMap(\.label)
                .first { !$0.isEmpty && $0 != routeCandidates.first?.providerName }
            let resolvedDisplayName = hasSyntheticCandidates ? key.logicalModel : (displayName ?? key.logicalModel)
            let contextWindow = routeCandidates.contains(where: \.supportsLongContext) ? 1_000_000 : 128_000
            return [
                "slug": key.logicalModel,
                "display_name": resolvedDisplayName,
                "description": resolvedDisplayName,
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

    private func codexAuthorization(
        for providerRef: ProviderRef,
        forceRefresh: Bool,
        rejectingAccessToken: String?,
        rejectingAuthorizationFingerprint: String?
    ) async throws -> CodexOAuthUpstreamAuthorization {
        guard let codexOfficialAuthorizer else {
            throw CodexOfficialAuthorizationError.notLoggedIn
        }
        do {
            return try await codexOfficialAuthorizer.authorization(
                for: providerRef,
                forceRefresh: forceRefresh,
                rejectingAccessToken: rejectingAccessToken,
                rejectingAuthorizationFingerprint: rejectingAuthorizationFingerprint
            )
        } catch CodexOAuthError.notLoggedIn {
            throw CodexOfficialAuthorizationError.notLoggedIn
        } catch CodexOAuthError.authorizationSuperseded {
            throw CodexOfficialAuthorizationError.accountChanged
        } catch let oauthError as CodexOAuthError {
            if case .tokenRequestFailed = oauthError,
               !oauthError.isPermanentRefreshFailure {
                throw oauthError
            }
            _ = await codexOfficialAuthorizer.markExpired(
                for: providerRef,
                rejectingAccessToken: rejectingAccessToken,
                rejectingAuthorizationFingerprint: rejectingAuthorizationFingerprint
            )
            await MainActor.run {
                runtime.codexOfficialAuthorizationDidExpire(providerRef: providerRef)
            }
            throw CodexOfficialAuthorizationError.refreshFailed
        } catch {
            throw error
        }
    }

    private static func apply(
        _ authorization: CodexOAuthUpstreamAuthorization,
        to request: inout URLRequest
    ) {
        request.setValue(nil, forHTTPHeaderField: CodexOfficial.fedRAMPHeader)
        for (key, value) in authorization.headers {
            if key.caseInsensitiveCompare(CodexOfficial.originatorHeader) == .orderedSame,
               request.value(forHTTPHeaderField: key) != nil {
                continue
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func copyAllowedHeaders(
        _ headers: [String: String],
        responseTransform: ProxyResponseTransform,
        authorizationRequirement: ProxyAuthorizationRequirement
    ) -> [String: String] {
        var copied: [String: String] = [:]
        let allowed: [String]
        switch authorizationRequirement {
        case .staticProvider:
            allowed = responseTransform == .openAIChatToAnthropicMessages
                ? ["accept", "user-agent"]
                : ["accept", "anthropic-version", "anthropic-beta", "user-agent"]
        case .codexOfficial:
            allowed = [
                "accept",
                "conversation_id",
                "openai-beta",
                "originator",
                "session-id",
                "session_id",
                "thread-id",
                "user-agent",
                "version",
                "x-client-request-id",
                "x-codex-beta-features",
                "x-codex-installation-id",
                "x-codex-parent-thread-id",
                "x-codex-turn-metadata",
                "x-codex-turn-state",
                "x-codex-window-id",
                "x-openai-internal-codex-responses-lite",
                "x-openai-internal-codex-residency",
                "x-openai-memgen-request",
                "x-openai-subagent",
                "x-oai-attestation",
                "x-responsesapi-include-timing-metrics"
            ]
        }
        let blocked = Set([
            "authorization",
            "chatgpt-account-id",
            "proxy-authorization",
            "x-api-key"
        ])
        for key in allowed {
            if !blocked.contains(key), let value = headers[key] {
                copied[key] = value
            }
        }
        return copied
    }

    private static func isAnthropicCountTokensPath(_ path: String) -> Bool {
        let normalized = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return normalized == "/v1/messages/count_tokens"
            || normalized.hasSuffix("/v1/messages/count_tokens")
    }

    private static func isEventStream(_ headers: [String: String]) -> Bool {
        headerValue(headers, name: "content-type")?
            .lowercased()
            .contains("text/event-stream") == true
    }

    private static func sseLine(from data: Data) -> String {
        var line = data
        if line.last == 13 {
            line.removeLast()
        }
        return String(data: line, encoding: .utf8) ?? ""
    }

    private static func sseDataPayload(from lines: [String]) -> String? {
        var dataLines: [String] = []
        for line in lines {
            if line.hasPrefix(":") {
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawField = parts.first, rawField == "data" else {
                continue
            }
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.first == " " {
                value.removeFirst()
            }
            dataLines.append(value)
        }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }

    private static func anthropicStreamErrorDetail(_ event: AnthropicChatStreamEvent) -> String {
        guard let sse = try? event.sseData(),
              let text = String(data: sse, encoding: .utf8),
              let dataLine = text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
              let value = try? JSONSerialization.jsonObject(with: Data(dataLine.dropFirst("data: ".count).utf8)),
              let object = value as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return "stream error"
        }
        let type = error["type"] as? String ?? "api_error"
        let message = error["message"] as? String ?? "stream error"
        return "\(type): \(message)"
    }

    private static func anthropicStreamBridgeErrorEvent(_ error: AnthropicChatBridgeError) -> AnthropicChatStreamEvent {
        AnthropicChatStreamEvent(event: "error", data: [
            "type": .string("error"),
            "error": .object([
                "type": .string("api_error"),
                "message": .string(error.localizedDescription)
            ])
        ])
    }

}

enum ProxyResponseHeaderPolicy {
    static func forwardedHeaders(
        from response: HTTPURLResponse?,
        stripCookies: Bool = false
    ) -> [String: String] {
        guard let response else {
            return [:]
        }
        let blocked = Set([
            "connection",
            "content-length",
            "content-encoding",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "transfer-encoding",
            "upgrade"
        ])
        let sensitiveCookies = Set(["set-cookie", "set-cookie2"])

        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            let normalizedName = name.lowercased()
            if !blocked.contains(normalizedName),
               !(stripCookies && sensitiveCookies.contains(normalizedName)) {
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

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case malformed(String)
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed("Malformed HTTP headers")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .malformed("Malformed HTTP request line")
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return .malformed("Malformed HTTP request line")
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
        let bodyLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsedLength = Int(rawContentLength), parsedLength >= 0 else {
                return .malformed("Invalid Content-Length")
            }
            bodyLength = parsedLength
        } else {
            bodyLength = 0
        }

        let (bodyEnd, overflowed) = bodyStart.addingReportingOverflow(bodyLength)
        guard !overflowed else {
            return .malformed("Invalid Content-Length")
        }
        guard data.count >= bodyEnd else {
            return .incomplete
        }

        return .complete(HTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        ))
    }

    static func expectsContinue(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return false
        }
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name == "expect", value == "100-continue" {
                return true
            }
        }
        return false
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
            guard let currentEvent, currentEvent == "response.failed" || currentEvent == "error" else {
                return nil
            }
            return failureDetail(event: currentEvent, from: currentDataLines.joined(separator: "\n"))
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

    private func failureDetail(event: String, from data: String) -> String {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return event
        }
        guard
            let jsonData = trimmed.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: jsonData),
            let object = value as? [String: Any]
        else {
            return "\(event) data=\(Self.compact(trimmed))"
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
        return "\(event) \(fields.joined(separator: " "))"
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

private struct SSEUsageInspector {
    private var currentLine = Data()
    private var currentDataLines: [String] = []

    mutating func append(_ byte: UInt8) -> UpstreamUsageSummary? {
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

    private mutating func processLine(_ line: String) -> UpstreamUsageSummary? {
        if line.isEmpty {
            defer {
                currentDataLines.removeAll(keepingCapacity: true)
            }
            return UpstreamUsageSummary.fromSSEData(currentDataLines.joined(separator: "\n"))
        }

        if line.hasPrefix(":") {
            return nil
        }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawField = parts.first, rawField == "data" else {
            return nil
        }
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.first == " " {
            value.removeFirst()
        }
        currentDataLines.append(value)
        return nil
    }
}

private struct UpstreamUsageSummary: Equatable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let cachedTokens: Int?
    let cacheCreationTokens: Int?
    let cacheDenominatorTokens: Int?

    var logFields: [LogField] {
        [
            LogField("inputTokens", inputTokens),
            LogField("outputTokens", outputTokens),
            LogField("totalTokens", totalTokens),
            LogField("cachedTokens", cachedTokens),
            LogField("cacheCreationTokens", cacheCreationTokens),
            LogField("cacheHitRate", cacheHitRate)
        ]
    }

    private var cacheHitRate: String? {
        guard let cachedTokens, cachedTokens > 0 else {
            return "0.0000"
        }
        guard let cacheDenominatorTokens, cacheDenominatorTokens > 0 else {
            return nil
        }
        return String(format: "%.4f", Double(cachedTokens) / Double(cacheDenominatorTokens))
    }

    static func fromBody(_ body: Data) -> UpstreamUsageSummary? {
        guard
            let value = try? JSONSerialization.jsonObject(with: body),
            let object = value as? [String: Any]
        else {
            return nil
        }
        return fromObject(object)
    }

    static func fromSSEData(_ data: String) -> UpstreamUsageSummary? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else {
            return nil
        }
        guard
            let jsonData = trimmed.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: jsonData),
            let object = value as? [String: Any]
        else {
            return nil
        }
        return fromObject(object)
    }

    private static func fromObject(_ object: [String: Any]) -> UpstreamUsageSummary? {
        if let usage = object["usage"] as? [String: Any] {
            return fromUsageObject(usage)
        }
        if let response = object["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any] {
            return fromUsageObject(usage)
        }
        return nil
    }

    private static func fromUsageObject(_ usage: [String: Any]) -> UpstreamUsageSummary {
        let inputTokens = intValue(usage["input_tokens"] ?? usage["prompt_tokens"])
        let cachedTokens = cachedTokens(from: usage)
        let cacheCreationTokens = intValue(usage["cache_creation_input_tokens"])
            ?? intValue(usage["cache_creation_tokens"])
        return UpstreamUsageSummary(
            inputTokens: inputTokens,
            outputTokens: intValue(usage["output_tokens"] ?? usage["completion_tokens"]),
            totalTokens: intValue(usage["total_tokens"]),
            cachedTokens: cachedTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheDenominatorTokens: cacheDenominatorTokens(
                usage: usage,
                inputTokens: inputTokens,
                cachedTokens: cachedTokens,
                cacheCreationTokens: cacheCreationTokens
            )
        )
    }

    private static func cachedTokens(from usage: [String: Any]) -> Int? {
        intValue(usage["cache_read_input_tokens"])
            ?? intValue(usage["cached_tokens"])
            ?? intValue((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? intValue((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
    }

    private static func cacheDenominatorTokens(
        usage: [String: Any],
        inputTokens: Int?,
        cachedTokens: Int?,
        cacheCreationTokens: Int?
    ) -> Int? {
        guard let inputTokens else {
            return nil
        }
        if usage["cache_read_input_tokens"] != nil || usage["cache_creation_input_tokens"] != nil {
            return inputTokens + (cachedTokens ?? 0) + (cacheCreationTokens ?? 0)
        }
        return inputTokens
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
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
    case 401:
        return "Unauthorized"
    case 403:
        return "Forbidden"
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
        return "Error"
    }
}
