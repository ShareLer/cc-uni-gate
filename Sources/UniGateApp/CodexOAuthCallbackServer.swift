import Foundation
import Network

enum CodexOAuthCallbackServerError: LocalizedError, Equatable {
    case portsUnavailable
    case listenerFailed(String)
    case timedOut
    case cancelled
    case authorizationDenied(String)
    case missingAuthorizationCode

    var errorDescription: String? {
        switch self {
        case .portsUnavailable:
            return "Codex 登录回调端口 1455 和 1457 均不可用"
        case let .listenerFailed(message):
            return "Codex 登录回调监听失败：\(message)"
        case .timedOut:
            return "Codex 登录已超时，请重试"
        case .cancelled:
            return "Codex 登录已取消"
        case let .authorizationDenied(message):
            return message
        case .missingAuthorizationCode:
            return "登录回调缺少授权码"
        }
    }
}

final class CodexOAuthCallbackServer: @unchecked Sendable {
    static let callbackPath = "/auth/callback"
    static let supportedPorts: [UInt16] = [1455, 1457]

    let port: UInt16
    let redirectURI: String

    private var expectedState: String?
    private let queue: DispatchQueue
    private let listener: NWListener
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var bufferedResult: Result<String, Error>?
    private var didFinish = false

    private init(port: UInt16) throws {
        self.port = port
        self.redirectURI = "http://localhost:\(port)\(Self.callbackPath)"
        self.queue = DispatchQueue(label: "unigate.codex-oauth-callback.\(port)")

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        self.listener = try NWListener(using: parameters)
    }

    static func start() async throws -> CodexOAuthCallbackServer {
        var lastError: Error?
        for port in supportedPorts {
            do {
                let server = try CodexOAuthCallbackServer(port: port)
                try await server.start()
                return server
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw CodexOAuthCallbackServerError.listenerFailed(lastError.localizedDescription)
        }
        throw CodexOAuthCallbackServerError.portsUnavailable
    }

    func configure(expectedState: String) {
        queue.sync {
            self.expectedState = expectedState
        }
    }

    func waitForAuthorizationCode(timeout: TimeInterval = 300) async throws -> String {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [self] in
                    try await callbackResult()
                }
                group.addTask { [weak self] in
                    let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    self?.finish(.failure(CodexOAuthCallbackServerError.timedOut))
                    throw CodexOAuthCallbackServerError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CodexOAuthCallbackServerError.cancelled
                }
                stop()
                return result
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(CodexOAuthCallbackServerError.cancelled))
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener.cancel()
            if !didFinish {
                finishOnQueue(.failure(CodexOAuthCallbackServerError.cancelled))
            }
        }
    }

    private func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                startupContinuation?.resume()
                startupContinuation = nil
            case let .waiting(error), let .failed(error):
                startupContinuation?.resume(throwing: error)
                startupContinuation = nil
                listener.cancel()
            case .cancelled:
                if let startupContinuation {
                    startupContinuation.resume(throwing: CodexOAuthCallbackServerError.cancelled)
                    self.startupContinuation = nil
                }
            case .setup:
                break
            @unknown default:
                startupContinuation?.resume(
                    throwing: CodexOAuthCallbackServerError.listenerFailed("未知监听状态")
                )
                startupContinuation = nil
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            startupContinuation = continuation
            listener.start(queue: queue)
        }
    }

    private func callbackResult() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CodexOAuthCallbackServerError.cancelled)
                    return
                }
                if let bufferedResult {
                    self.bufferedResult = nil
                    continuation.resume(with: bufferedResult)
                } else {
                    callbackContinuation = continuation
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, data: Data())
    }

    private func receive(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] chunk, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }
            var next = data
            if let chunk {
                next.append(chunk)
            }
            if next.range(of: Data("\r\n\r\n".utf8)) != nil {
                process(next, on: connection)
            } else if isComplete || next.count >= 32_768 {
                sendResponse(status: 400, title: "登录失败", message: "无效的回调请求", on: connection)
            } else {
                receive(on: connection, data: next)
            }
        }
    }

    private func process(_ data: Data, on connection: NWConnection) {
        guard
            let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
            let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8),
            let requestLine = headerText.components(separatedBy: "\r\n").first
        else {
            sendResponse(status: 400, title: "登录失败", message: "无效的回调请求", on: connection)
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0] == "GET" else {
            sendResponse(status: 405, title: "登录失败", message: "不支持的回调请求", on: connection)
            return
        }
        guard let components = URLComponents(string: "http://localhost\(parts[1])"),
              components.path == Self.callbackPath else {
            sendResponse(status: 404, title: "登录失败", message: "回调地址不匹配", on: connection)
            return
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        guard let expectedState, query["state"] == expectedState else {
            sendResponse(status: 400, title: "登录失败", message: "登录状态校验失败，请返回 UniGate 重试", on: connection)
            return
        }

        if let errorCode = nonEmpty(query["error"]) {
            let description = nonEmpty(query["error_description"])
            let message = description ?? (errorCode == "access_denied" ? "Codex 登录已取消" : "Codex 登录失败：\(errorCode)")
            sendResponse(status: 400, title: "登录失败", message: message, on: connection)
            finishOnQueue(.failure(CodexOAuthCallbackServerError.authorizationDenied(message)))
            return
        }
        guard let code = nonEmpty(query["code"]) else {
            sendResponse(status: 400, title: "登录失败", message: "登录回调缺少授权码", on: connection)
            finishOnQueue(.failure(CodexOAuthCallbackServerError.missingAuthorizationCode))
            return
        }

        sendResponse(status: 200, title: "登录成功", message: "可以关闭此页面并返回 UniGate", on: connection)
        finishOnQueue(.success(code))
    }

    private func sendResponse(
        status: Int,
        title: String,
        message: String,
        on connection: NWConnection
    ) {
        let escapedTitle = Self.escapeHTML(title)
        let escapedMessage = Self.escapeHTML(message)
        let body = Data("""
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(escapedTitle)</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;background:#f5f5f7;color:#1d1d1f}.content{max-width:520px;padding:32px;text-align:center}h1{font-size:28px;margin:0 0 12px}p{font-size:16px;line-height:1.5;color:#666}</style></head><body><main class="content"><h1>\(escapedTitle)</h1><p>\(escapedMessage)</p></main></body></html>
        """.utf8)
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let head = Data("HTTP/1.1 \(status) \(reason)\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: \(body.count)\r\nconnection: close\r\ncache-control: no-store\r\n\r\n".utf8)
        connection.send(content: head + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        queue.async { [weak self] in
            self?.finishOnQueue(result)
        }
    }

    private func finishOnQueue(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        didFinish = true
        listener.cancel()
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(with: result)
        } else {
            bufferedResult = result
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
