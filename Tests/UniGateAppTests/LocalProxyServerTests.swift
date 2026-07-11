@testable import UniGateApp
import UniGateCore
import Foundation
import Network
import Testing

@Suite(.serialized)
struct LocalProxyServerTests {
    private static let localProxyToken = "sk-unigate-test-installation-token"

    @Test
    @MainActor
    func codexModelCatalogKeepsCustomAliasDisplayName() {
        let provider = ImportedProvider(
            id: "configured",
            appType: UniGateAppRegistry.codex,
            name: "Configured Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://configured.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let baseCandidate = ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: UniGateAppRegistry.codex,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "gpt-5.5",
            supportsLongContext: false
        )
        let customTarget = CustomModelTarget(routeKey: baseCandidate.routeKey, providerRef: provider.ref)
        let customCandidate = ModelCandidate(
            logicalModel: "gpt-5.4",
            providerRef: CustomModelState.syntheticProviderRef(
                appType: UniGateAppRegistry.codex,
                target: customTarget
            ),
            providerName: provider.name,
            appType: UniGateAppRegistry.codex,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: "gpt-5.5",
            supportsLongContext: false,
            upstreamProviderRef: provider.ref,
            source: .configured
        )

        let models = LocalProxyServer.codexModelCatalog(
            routeKeys: [ModelRouteKey(appType: UniGateAppRegistry.codex, logicalModel: "gpt-5.4")],
            candidates: [baseCandidate, customCandidate]
        )

        #expect(models.count == 1)
        #expect(models.first?["slug"] as? String == "gpt-5.4")
        #expect(models.first?["display_name"] as? String == "gpt-5.4")
        #expect(models.first?["description"] as? String == "gpt-5.4")
    }

    @Test
    @MainActor
    func modelsEndpointsUseEffectiveCodexSnapshotButKeepFullClaudeListing() async throws {
        let codexProvider = Self.provider(
            id: "codex-provider",
            appType: UniGateAppRegistry.codex,
            apiFormat: .openaiResponses
        )
        let claudeProvider = Self.provider(
            id: "claude-provider",
            appType: UniGateAppRegistry.claudeCode,
            apiFormat: .anthropic
        )
        let disabledCodex = Self.candidate(provider: codexProvider, model: "gpt-5.5")
        let enabledCodex = Self.candidate(provider: codexProvider, model: "gpt-5.6-sol")
        let claudeSonnet = Self.candidate(provider: claudeProvider, model: "claude-sonnet")
        let claudeOpus = Self.candidate(provider: claudeProvider, model: "claude-opus")
        let fullCatalog = ProviderCatalog(
            providers: [codexProvider, claudeProvider],
            candidates: [disabledCodex, enabledCodex, claudeSonnet, claudeOpus]
        )
        let customModels = CustomModelState(codexRoutePolicies: [
            CodexModelRoutePolicy(routeKey: disabledCodex.routeKey, isDisabled: true)
        ])
        let effectiveCatalog = fullCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: customModels
        )
        let modelListCatalog = ProviderCatalog(
            providers: fullCatalog.providers,
            candidates: fullCatalog.candidates.filter {
                $0.appType != UniGateAppRegistry.codex
            } + effectiveCatalog.candidates.filter {
                $0.appType == UniGateAppRegistry.codex
            }
        )
        let fullSnapshot = ProxyRuntimeSnapshot(
            catalog: fullCatalog,
            routes: RouteStore.defaultState(candidates: fullCatalog.candidates),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        )
        let modelListSnapshot = ProxyRuntimeSnapshot(
            catalog: modelListCatalog,
            routes: RouteStore.defaultState(candidates: effectiveCatalog.candidates),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        )
        let runtime = MockProxyRuntime(
            snapshot: fullSnapshot,
            modelListSnapshot: modelListSnapshot
        )
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let codexResponse = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\n\r\n"
        )
        let claudeResponse = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: "GET /claude/v1/models HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\n\r\n"
        )

        #expect(codexResponse.contains("HTTP/1.1 200 OK"))
        #expect(try Self.listedModelIDs(in: codexResponse) == [enabledCodex.logicalModel])
        #expect(claudeResponse.contains("HTTP/1.1 200 OK"))
        #expect(try Self.listedModelIDs(in: claudeResponse) == [
            claudeOpus.logicalModel,
            claudeSonnet.logicalModel
        ])
    }

    @Test
    @MainActor
    func codexModelsEndpointOmitsExplicitRouteWhoseSelectedTargetIsMissing() async throws {
        let provider = Self.provider(
            id: "codex-provider",
            appType: UniGateAppRegistry.codex,
            apiFormat: .openaiResponses
        )
        let alternate = Self.candidate(provider: provider, model: "gpt-5.6-sol")
        let routeKey = ModelRouteKey(
            appType: UniGateAppRegistry.codex,
            logicalModel: "gpt-5.5"
        )
        let alternateTarget = CustomModelTarget(
            routeKey: alternate.routeKey,
            providerRef: provider.ref
        )
        let missingTarget = CustomModelTarget(
            routeKey: ModelRouteKey(
                appType: UniGateAppRegistry.codex,
                logicalModel: "gpt-5.7-missing"
            ),
            providerRef: provider.ref
        )
        var customModels = CustomModelState()
        customModels.setCodexExplicitRoute(
            routeKey: routeKey,
            targets: [alternateTarget, missingTarget],
            selectedTargetID: missingTarget.id
        )
        let fullCatalog = ProviderCatalog(providers: [provider], candidates: [alternate])
        let effectiveCatalog = fullCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: customModels
        )
        let routes = RouteStore.defaultState(
            candidates: effectiveCatalog.candidates,
            preferredProviderRefsByRouteKey: customModels.preferredProviderRefsByRouteKey(
                availableIn: effectiveCatalog
            )
        )
        let snapshot = ProxyRuntimeSnapshot(
            catalog: effectiveCatalog,
            routes: routes,
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        )
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\n\r\n"
        )

        #expect(response.contains("HTTP/1.1 200 OK"))
        #expect(try Self.listedModelIDs(in: response) == [alternate.logicalModel])
        #expect(effectiveCatalog.candidates(for: routeKey).count == 1)
        #expect(routes.routes[routeKey.description] == nil)
    }

    @Test
    @MainActor
    func disabledCodexRouteReturnsModelNotFoundWithoutCallingUpstream() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [200])
        let provider = Self.provider(
            id: "codex-provider",
            appType: UniGateAppRegistry.codex,
            apiFormat: .openaiResponses
        )
        let disabledCandidate = Self.candidate(provider: provider, model: "gpt-5.5")
        let fullCatalog = ProviderCatalog(providers: [provider], candidates: [disabledCandidate])
        let customModels = CustomModelState(codexRoutePolicies: [
            CodexModelRoutePolicy(routeKey: disabledCandidate.routeKey, isDisabled: true)
        ])
        let effectiveCatalog = fullCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: customModels
        )
        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: effectiveCatalog,
            routes: RouteStore.defaultState(candidates: effectiveCatalog.candidates),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(port: proxyPort, additionalHeaders: "")

        #expect(response.contains("HTTP/1.1 404 Not Found"))
        #expect(response.contains(#""model_not_found""#))
        #expect(MockCodexUpstreamURLProtocol.recordedRequests().isEmpty)
    }

    @Test
    @MainActor
    func disabledCodexCustomAliasReturnsModelNotFoundInsteadOfUnavailableTarget() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [200])
        let provider = Self.provider(
            id: "codex-provider",
            appType: UniGateAppRegistry.codex,
            apiFormat: .openaiResponses
        )
        let upstream = Self.candidate(provider: provider, model: "gpt-5.6-sol")
        let routeKey = ModelRouteKey(appType: UniGateAppRegistry.codex, logicalModel: "gpt-5.5")
        let target = CustomModelTarget(routeKey: upstream.routeKey, providerRef: provider.ref)
        let definition = CustomModelDefinition(
            appType: routeKey.appType,
            name: routeKey.logicalModel,
            targets: [target],
            selectedTargetID: target.id
        )
        let enabledModels = CustomModelState(models: [definition])
        let rawCatalog = ProviderCatalog(providers: [provider], candidates: [upstream])
        let enabledCatalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: enabledModels
        )
        let activeAlias = try #require(enabledCatalog.candidates(for: routeKey).first)
        let disabledModels = CustomModelState(
            models: [definition],
            codexRoutePolicies: [CodexModelRoutePolicy(routeKey: routeKey, isDisabled: true)]
        )
        let disabledCatalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: disabledModels
        )
        let routeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let routeStore = RouteStore(fileURL: routeURL)
        try routeStore.save(RouteState(routes: [
            routeKey.description: ActiveRoute(
                appType: routeKey.appType,
                logicalModel: routeKey.logicalModel,
                providerRef: activeAlias.providerRef,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))
        let routes = try routeStore.load(
            catalog: disabledCatalog,
            preferredProviderRefsByRouteKey: disabledModels.preferredProviderRefsByRouteKey(
                availableIn: disabledCatalog
            ),
            providerRefMigrationPlan: disabledModels.codexProviderRefMigrationPlan()
        )
        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: disabledCatalog,
            routes: routes,
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(port: proxyPort, additionalHeaders: "")

        #expect(routes.routes[routeKey.description] == nil)
        #expect(response.contains("HTTP/1.1 404 Not Found"))
        #expect(response.contains(#""model_not_found""#))
        #expect(!response.contains(#""route_target_unavailable""#))
        #expect(MockCodexUpstreamURLProtocol.recordedRequests().isEmpty)
    }

    @Test
    @MainActor
    func rejectsNegativeContentLengthWithoutCrashing() async throws {
        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: ProviderCatalog(providers: [], candidates: []),
            routes: RouteState(routes: [:]),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))

        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: "POST /__manager/health HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\nContent-Length: -1\r\n\r\n"
        )

        #expect(response.contains("HTTP/1.1 400"))
        #expect(response.contains("Invalid Content-Length"))
    }

    @Test
    @MainActor
    func rejectsOverflowingContentLengthWithoutCrashing() async throws {
        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: ProviderCatalog(providers: [], candidates: []),
            routes: RouteState(routes: [:]),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))

        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: "POST /__manager/health HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\nContent-Length: 9223372036854775807\r\n\r\n"
        )

        #expect(response.contains("HTTP/1.1 400"))
        #expect(response.contains("Invalid Content-Length"))
    }

    @Test
    @MainActor
    func malformedProxyJSONReturns400WithoutProviderFailure() async throws {
        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: ProviderCatalog(providers: [], candidates: []),
            routes: RouteState(routes: [:]),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))

        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: """
            POST /v1/responses HTTP/1.1\r
            Host: 127.0.0.1:\(proxyPort)\r
            Content-Type: application/json\r
            Content-Length: 1\r
            \r
            {
            """
        )

        #expect(response.contains("HTTP/1.1 400"))
        #expect(response.contains(#""invalid_json""#))
        #expect(runtime.failures.isEmpty)
    }

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
        let rawResponse = try await Self.rawHTTPResponseFromBackgroundTask(
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

        #expect(rawResponse.contains("HTTP/1.1 200 OK"))
        #expect(runtime.failures.contains { $0.contains("SSE error") }, "\(runtime.events)")
        #expect(rawResponse.contains("event: error"), "\(rawResponse)\n\(runtime.events)")
        #expect(rawResponse.contains("Upstream OpenAI Chat stream chunk must be a JSON object"), "\(rawResponse)\n\(runtime.events)")
    }

    @Test
    @MainActor
    func logsUpstreamUsageForTransformedOpenAIChatResponse() async throws {
        let upstream = try MockSSEUpstream(
            contentType: "application/json",
            body: Data("""
            {
              "id": "chatcmpl-1",
              "model": "luban-glm",
              "choices": [
                {
                  "message": {"role": "assistant", "content": "ok"},
                  "finish_reason": "stop"
                }
              ],
              "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 5,
                "total_tokens": 105,
                "prompt_tokens_details": {"cached_tokens": 40}
              }
            }
            """.utf8)
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
            upstreamModel: "luban-glm",
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
          "messages": [
            {"role": "user", "content": "hello"}
          ]
        }
        """
        let rawResponse = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: """
            POST /v1/messages HTTP/1.1\r
            Host: 127.0.0.1:\(proxyPort)\r
            Content-Type: application/json\r
            Content-Length: \(Data(requestBody.utf8).count)\r
            \r
            \(requestBody)
            """
        )

        #expect(rawResponse.contains("HTTP/1.1 200 OK"))
        #expect(runtime.events.contains { event in
            event.contains("phase=transform-complete")
                && event.contains("usage=present")
                && event.contains("inputTokens=100")
                && event.contains("outputTokens=5")
                && event.contains("cachedTokens=40")
                && event.contains("cacheHitRate=0.4000")
        }, "\(runtime.events)")
    }

    @Test
    @MainActor
    func logsUpstreamUsageForTransformedOpenAIChatStream() async throws {
        let upstream = try MockSSEUpstream(
            body: Data("""
            data: {"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{"content":"ok"},"finish_reason":null}]}

            data: {"id":"chatcmpl-1","model":"luban-glm","choices":[{"delta":{},"finish_reason":"stop"}]}

            data: {"id":"chatcmpl-1","model":"luban-glm","choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"total_tokens":105,"prompt_tokens_details":{"cached_tokens":40}}}

            data: [DONE]

            """.utf8)
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
            upstreamModel: "luban-glm",
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
        let rawResponse = try await Self.rawHTTPResponseFromBackgroundTask(
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

        #expect(rawResponse.contains("HTTP/1.1 200 OK"))
        #expect(runtime.events.contains { event in
            event.contains("phase=transform-stream-complete")
                && event.contains("usage=present")
                && event.contains("inputTokens=100")
                && event.contains("outputTokens=5")
                && event.contains("cachedTokens=40")
                && event.contains("cacheHitRate=0.4000")
        }, "\(runtime.events)")
    }

    @Test
    @MainActor
    func forwardsExpectContinueBeforeReadingBody() async throws {
        let upstream = try MockSSEUpstream(
            body: Data("data: [DONE]\n\n".utf8)
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
            upstreamModel: "luban-glm",
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

        let body = #"{"model":"claude-sonnet","messages":[{"role":"user","content":"hello"}]}"#
        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: """
            POST /v1/messages HTTP/1.1\r
            Host: 127.0.0.1:\(proxyPort)\r
            Expect: 100-continue\r
            Content-Type: application/json\r
            Content-Length: \(Data(body.utf8).count)\r
            \r
            \(body)
            """
        )

        #expect(response.contains("HTTP/1.1 200 OK"))
    }

    @Test
    @MainActor
    func stripsContentEncodingFromForwardedResponseHeaders() async throws {
        let upstream = try MockSSEUpstream(
            contentType: "application/json",
            headers: ["content-encoding": "identity"],
            body: Data("""
            {
              "id": "chatcmpl-1",
              "model": "luban-glm",
              "choices": [
                {
                  "message": {"role": "assistant", "content": "ok"},
                  "finish_reason": "stop"
                }
              ],
              "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 1,
                "total_tokens": 11
              }
            }
            """.utf8)
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
            upstreamModel: "luban-glm",
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

        let body = #"{"model":"claude-sonnet","messages":[{"role":"user","content":"hello"}]}"#
        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: """
            POST /v1/messages HTTP/1.1\r
            Host: 127.0.0.1:\(proxyPort)\r
            Content-Type: application/json\r
            Content-Length: \(Data(body.utf8).count)\r
            \r
            \(body)
            """
        )

        #expect(response.contains("HTTP/1.1 200 OK"))
        #expect(!response.lowercased().contains("content-encoding"))
    }

    @Test
    @MainActor
    func managerWriteEndpointsRequireBearerToken() async throws {
        // Management write endpoints (/__manager/reload, /__manager/routes) must be
        // gated by the configured Bearer token: a missing or wrong token yields 401,
        // and the correct token passes through to the handler. A server with no token
        // configured rejects all writes with 403. The token is injected explicitly so
        // the test does not depend on the UNIGATE_MANAGER_TOKEN environment variable.
        let token = "test-manager-token"
        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: ProviderCatalog(providers: [], candidates: []),
            routes: RouteState(routes: [:]),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))

        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime, managerToken: token)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let reloadPath = "POST /__manager/reload HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\nContent-Length: 0\r\n"
        let missingToken = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: reloadPath + "Authorization: \r\n\r\n"
        )
        #expect(missingToken.contains("HTTP/1.1 401"))

        let wrongToken = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: reloadPath + "Authorization: Bearer wrong-token\r\n\r\n"
        )
        #expect(wrongToken.contains("HTTP/1.1 401"))

        let correctToken = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: reloadPath + "Authorization: Bearer \(token)\r\n\r\n"
        )
        #expect(correctToken.contains("HTTP/1.1 200"))
    }

    @Test
    @MainActor
    func managerWriteEndpointsRejectWhenTokenUnconfigured() async throws {
        // With no token configured, every management write must be rejected (403) so a
        // fresh install is secure-by-default. We unset UNIGATE_MANAGER_TOKEN for the
        // duration of the test so configuredManagerToken() deterministically returns nil
        // regardless of the host environment.
        let previousToken = ProcessInfo.processInfo.environment["UNIGATE_MANAGER_TOKEN"]
        setenv("UNIGATE_MANAGER_TOKEN", "", 1)
        defer {
            if let previousToken {
                setenv("UNIGATE_MANAGER_TOKEN", previousToken, 1)
            } else {
                unsetenv("UNIGATE_MANAGER_TOKEN")
            }
        }

        let runtime = MockProxyRuntime(snapshot: ProxyRuntimeSnapshot(
            catalog: ProviderCatalog(providers: [], candidates: []),
            routes: RouteState(routes: [:]),
            networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
        ))

        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(port: proxyPort, runtime: runtime, managerToken: nil)
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: "POST /__manager/reload HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\nContent-Length: 0\r\n\r\n"
        )

        #expect(response.contains("HTTP/1.1 403"))
        #expect(response.contains("Manager token is not configured"))
    }

    @Test
    @MainActor
    func codexOfficial401RefreshesOnceAndIsolatesAuthenticationHeaders() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [401, 200])
        let (snapshot, providerRef) = Self.proxySnapshot(backendKind: .codexOfficial)
        let authorizer = MockCodexOfficialAuthorizer()
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: authorizer,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let body = #"{"model":"gpt-5.5","input":"hello"}"#
        let response = try await Self.rawHTTPResponseFromBackgroundTask(
            port: proxyPort,
            request: """
            POST /openai/v1/responses HTTP/1.1\r
            Host: 127.0.0.1:\(proxyPort)\r
            Content-Type: application/json\r
            Authorization: Bearer \(Self.localProxyToken)\r
            ChatGPT-Account-ID: inbound-account\r
            Originator: inbound-originator\r
            X-Codex-Turn-Metadata: safe-turn\r
            X-Client-Request-Id: safe-request\r
            X-OpenAI-Internal-Codex-Residency: us\r
            X-OpenAI-Memgen-Request: true\r
            X-OAI-Attestation: signed-attestation\r
            X-Evil: must-not-forward\r
            Content-Length: \(Data(body.utf8).count)\r
            \r
            \(body)
            """
        )

        #expect(response.contains("HTTP/1.1 200 OK"))
        let requests = MockCodexUpstreamURLProtocol.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
        #expect(requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-1")
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
        #expect(requests.last?.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-1")
        #expect(requests.last?.value(forHTTPHeaderField: "Originator") == "inbound-originator")
        #expect(requests.last?.value(forHTTPHeaderField: "X-Codex-Turn-Metadata") == "safe-turn")
        #expect(requests.last?.value(forHTTPHeaderField: "X-Client-Request-Id") == "safe-request")
        #expect(requests.last?.value(forHTTPHeaderField: "X-OpenAI-Internal-Codex-Residency") == "us")
        #expect(requests.last?.value(forHTTPHeaderField: "X-OpenAI-Memgen-Request") == "true")
        #expect(requests.last?.value(forHTTPHeaderField: "X-OAI-Attestation") == "signed-attestation")
        #expect(requests.last?.value(forHTTPHeaderField: "X-Evil") == nil)
        let state = await authorizer.snapshot()
        #expect(state.forceRefreshCalls == [false, true])
        #expect(state.rejectingAccessTokens == [nil, "old-token"])
        #expect(state.rejectingAuthorizationFingerprints == [
            nil,
            CodexOAuthUpstreamAuthorization(
                accessToken: "old-token",
                accountID: "account-1"
            ).authorizationFingerprint
        ])
        #expect(state.expiredProviderRefs.isEmpty)
        #expect(state.requestedProviderRefs == [providerRef, providerRef])
    }

    @Test
    @MainActor
    func codexOfficialSecond401MarksLoginExpiredWithoutFurtherRetry() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [401, 401, 200])
        let (snapshot, providerRef) = Self.proxySnapshot(backendKind: .codexOfficial)
        let authorizer = MockCodexOfficialAuthorizer()
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: authorizer,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(port: proxyPort)

        #expect(response.contains("HTTP/1.1 401"))
        #expect(MockCodexUpstreamURLProtocol.recordedRequests().count == 2)
        let state = await authorizer.snapshot()
        #expect(state.forceRefreshCalls == [false, true])
        #expect(state.rejectingAccessTokens == [nil, "old-token"])
        #expect(state.expiredProviderRefs == [providerRef])
    }

    @Test
    @MainActor
    func codexOfficial403DoesNotRefreshOrRetry() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [403, 200])
        let (snapshot, _) = Self.proxySnapshot(backendKind: .codexOfficial)
        let authorizer = MockCodexOfficialAuthorizer()
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: authorizer,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(port: proxyPort)

        #expect(response.contains("HTTP/1.1 403"))
        #expect(MockCodexUpstreamURLProtocol.recordedRequests().count == 1)
        let state = await authorizer.snapshot()
        #expect(state.forceRefreshCalls == [false])
        #expect(state.expiredProviderRefs.isEmpty)
    }

    @Test
    @MainActor
    func codexOfficialDoesNotExposeUpstreamCookiesToTheLocalClient() async throws {
        MockCodexUpstreamURLProtocol.configure(
            statusCodes: [200],
            responseHeaders: [
                "Set-Cookie": "chatgpt_session=secret; Path=/; Secure; HttpOnly",
                "X-Upstream-Test": "visible"
            ]
        )
        let (snapshot, _) = Self.proxySnapshot(backendKind: .codexOfficial)
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: MockCodexOfficialAuthorizer(),
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(port: proxyPort)
        let normalizedResponse = response.lowercased()

        #expect(response.contains("HTTP/1.1 200 OK"))
        #expect(normalizedResponse.contains("set-cookie:") == false)
        #expect(normalizedResponse.contains("x-upstream-test: visible"))
    }

    @Test
    @MainActor
    func codexOfficialRejectsBrowserOriginBeforeUsingSubscription() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [200])
        let (snapshot, _) = Self.proxySnapshot(backendKind: .codexOfficial)
        let authorizer = MockCodexOfficialAuthorizer()
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: authorizer,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(
            port: proxyPort,
            additionalHeaders: "Authorization: Bearer \(Self.localProxyToken)\r\nOrigin: https://malicious.example\r\n"
        )

        #expect(response.contains("HTTP/1.1 403 Forbidden"))
        #expect(response.contains("codex_browser_origin_denied"))
        #expect(MockCodexUpstreamURLProtocol.recordedRequests().isEmpty)
        let state = await authorizer.snapshot()
        #expect(state.forceRefreshCalls.isEmpty)
    }

    @Test
    @MainActor
    func signedOutCodexOfficialReturnsClear401WithoutCallingUpstream() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [200])
        let (snapshot, _) = Self.proxySnapshot(backendKind: .codexOfficial)
        let authorizer = MockCodexOfficialAuthorizer(isSignedOut: true)
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: authorizer,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(port: proxyPort)

        #expect(response.contains("HTTP/1.1 401"))
        #expect(response.contains("codex_not_logged_in"))
        #expect(MockCodexUpstreamURLProtocol.recordedRequests().isEmpty)
    }

    @Test
    @MainActor
    func codexOfficialRejectsLegacyFixedLocalKeyWithReimportGuidance() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [200])
        let (snapshot, _) = Self.proxySnapshot(backendKind: .codexOfficial)
        let authorizer = MockCodexOfficialAuthorizer()
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: authorizer,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(
            port: proxyPort,
            additionalHeaders: "Authorization: Bearer \(CcSwitchDeepLink.localAPIKey)\r\n"
        )

        #expect(response.contains("HTTP/1.1 401 Unauthorized"))
        #expect(response.contains("codex_local_proxy_credential_invalid"))
        #expect(response.contains("重新导入 cc-switch"))
        #expect(MockCodexUpstreamURLProtocol.recordedRequests().isEmpty)
        let state = await authorizer.snapshot()
        #expect(state.forceRefreshCalls.isEmpty)
    }

    @Test
    @MainActor
    func standardProviderKeepsStaticAuthenticationAndSkipsOAuth() async throws {
        MockCodexUpstreamURLProtocol.configure(statusCodes: [200])
        let (snapshot, _) = Self.proxySnapshot(backendKind: .standard)
        let authorizer = MockCodexOfficialAuthorizer()
        let runtime = MockProxyRuntime(snapshot: snapshot)
        let proxyPort = try Self.availablePort()
        let server = LocalProxyServer(
            port: proxyPort,
            runtime: runtime,
            localProxyToken: Self.localProxyToken,
            codexOfficialAuthorizer: authorizer,
            upstreamSessionFactory: Self.mockUpstreamSessionFactory
        )
        try server.start()
        defer { server.stop() }
        try await runtime.waitUntilReady()

        let response = try await Self.sendCodexRequest(
            port: proxyPort,
            additionalHeaders: "Authorization: Bearer \(CcSwitchDeepLink.localAPIKey)\r\nChatGPT-Account-ID: inbound-account\r\n"
        )

        #expect(response.contains("HTTP/1.1 200 OK"))
        let requests = MockCodexUpstreamURLProtocol.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer static-key")
        #expect(requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
        let state = await authorizer.snapshot()
        #expect(state.forceRefreshCalls.isEmpty)
    }

    private static let mockUpstreamSessionFactory: LocalProxyServer.UpstreamSessionFactory = { _, _, _ in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCodexUpstreamURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func provider(
        id: String,
        appType: String,
        apiFormat: ApiFormat
    ) -> ImportedProvider {
        ImportedProvider(
            id: id,
            appType: appType,
            name: id,
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: apiFormat,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("static-key")])],
            meta: [:]
        )
    }

    private static func candidate(provider: ImportedProvider, model: String) -> ModelCandidate {
        ModelCandidate(
            logicalModel: model,
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: provider.appType == UniGateAppRegistry.codex
                ? .codexResponses
                : .anthropicMessages,
            apiFormat: provider.apiFormat,
            upstreamModel: model,
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
    }

    private static func listedModelIDs(in response: String) throws -> Set<String> {
        guard let bodyStart = response.range(of: "\r\n\r\n")?.upperBound else {
            throw TestError("HTTP response is missing a body")
        }
        let body = Data(response[bodyStart...].utf8)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = object["data"] as? [[String: Any]] else {
            throw TestError("Models response is not a JSON model list")
        }
        return Set(data.compactMap { $0["id"] as? String })
    }

    private static func proxySnapshot(
        backendKind: ProviderBackendKind
    ) -> (ProxyRuntimeSnapshot, ProviderRef) {
        let provider = ImportedProvider(
            id: backendKind == .codexOfficial ? "official" : "standard",
            appType: UniGateAppRegistry.codex,
            name: backendKind == .codexOfficial ? "Codex 官方" : "Standard Provider",
            category: backendKind == .codexOfficial ? "official" : nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: backendKind == .codexOfficial
                ? "https://attacker.example.com/must-not-be-used"
                : "https://api.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("static-key")])],
            meta: [:],
            backendKind: backendKind
        )
        let candidate = ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        return (
            ProxyRuntimeSnapshot(
                catalog: catalog,
                routes: RouteStore.defaultState(candidates: catalog.candidates),
                networkPolicy: NetworkPolicyPreferences(globalMode: .direct)
            ),
            provider.ref
        )
    }

    private static func sendCodexRequest(
        port: UInt16,
        additionalHeaders: String = "Authorization: Bearer sk-unigate-test-installation-token\r\n"
    ) async throws -> String {
        let body = #"{"model":"gpt-5.5","input":"hello"}"#
        return try await rawHTTPResponseFromBackgroundTask(
            port: port,
            request: "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n\(additionalHeaders)Content-Length: \(Data(body.utf8).count)\r\n\r\n\(body)"
        )
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

    private static func rawHTTPResponseFromBackgroundTask(port: UInt16, request: String) async throws -> String {
        // Keep blocking socket I/O off the MainActor. Some proxy handlers hop to
        // MainActor before responding, and a synchronous read there would starve
        // that hop until SO_RCVTIMEO fires.
        try await Task.detached {
            try Self.rawHTTPResponse(port: port, request: request)
        }.value
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

        // Guard against a malformed request or an unresponsive server hanging the
        // whole test run: bound the read so a request that never yields a response
        // fails fast instead of blocking forever.
        var readTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

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
                // errno EAGAIN/EWOULDBLOCK from the SO_RCVTIMEO: return whatever was
                // read so the caller can assert on a partial response (or an empty one
                // when the server never replied) instead of throwing opaquely.
                if !response.isEmpty { break }
                throw TestError("read failed (no response within timeout)")
            }
        }
        return String(data: response, encoding: .utf8) ?? ""
    }
}

@MainActor
private final class MockProxyRuntime: LocalProxyRuntime {
    private var snapshot: ProxyRuntimeSnapshot
    private var modelListSnapshotValue: ProxyRuntimeSnapshot
    private var listenerStates: [ProxyListenerState] = []
    private(set) var failures: [String] = []
    private(set) var events: [String] = []

    init(
        snapshot: ProxyRuntimeSnapshot,
        modelListSnapshot: ProxyRuntimeSnapshot? = nil
    ) {
        self.snapshot = snapshot
        self.modelListSnapshotValue = modelListSnapshot ?? snapshot
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
        modelListSnapshotValue
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

private actor MockCodexOfficialAuthorizer: CodexOfficialAuthorizing {
    private let isSignedOut: Bool
    private var forceRefreshCalls: [Bool] = []
    private var rejectingAccessTokens: [String?] = []
    private var rejectingAuthorizationFingerprints: [String?] = []
    private var requestedProviderRefs: [ProviderRef] = []
    private var expiredProviderRefs: [ProviderRef] = []

    init(isSignedOut: Bool = false) {
        self.isSignedOut = isSignedOut
    }

    func authorization(
        for providerRef: ProviderRef,
        forceRefresh: Bool,
        rejectingAccessToken: String?,
        rejectingAuthorizationFingerprint: String?
    ) async throws -> CodexOAuthUpstreamAuthorization {
        requestedProviderRefs.append(providerRef)
        forceRefreshCalls.append(forceRefresh)
        rejectingAccessTokens.append(rejectingAccessToken)
        rejectingAuthorizationFingerprints.append(rejectingAuthorizationFingerprint)
        if isSignedOut {
            throw CodexOAuthError.notLoggedIn
        }
        return CodexOAuthUpstreamAuthorization(
            accessToken: forceRefresh ? "new-token" : "old-token",
            accountID: "account-1"
        )
    }

    func markExpired(
        for providerRef: ProviderRef,
        rejectingAccessToken: String?,
        rejectingAuthorizationFingerprint: String?
    ) async -> Bool {
        expiredProviderRefs.append(providerRef)
        return true
    }

    func snapshot() -> (
        forceRefreshCalls: [Bool],
        rejectingAccessTokens: [String?],
        rejectingAuthorizationFingerprints: [String?],
        requestedProviderRefs: [ProviderRef],
        expiredProviderRefs: [ProviderRef]
    ) {
        (
            forceRefreshCalls,
            rejectingAccessTokens,
            rejectingAuthorizationFingerprints,
            requestedProviderRefs,
            expiredProviderRefs
        )
    }
}

private final class MockCodexUpstreamURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusCodes: [Int] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var responseHeaders: [String: String] = [:]

    static func configure(
        statusCodes: [Int],
        responseHeaders: [String: String] = [:]
    ) {
        lock.lock()
        self.statusCodes = statusCodes
        requests = []
        self.responseHeaders = responseHeaders
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = Self.statusCodes.isEmpty ? 500 : Self.statusCodes.removeFirst()
        let responseHeaders = Self.responseHeaders
        Self.lock.unlock()

        let headerFields = responseHeaders.merging(
            ["content-type": "application/json"],
            uniquingKeysWith: { existing, _ in existing }
        )
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headerFields
              ) else {
            client?.urlProtocol(self, didFailWithError: TestError("invalid mock response"))
            return
        }
        let body = status >= 200 && status < 300
            ? Data(#"{"ok":true}"#.utf8)
            : Data(#"{"error":"mock"}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockSSEUpstream: @unchecked Sendable {
    private let contentType: String
    private let headers: [String: String]
    private let body: Data
    private let queue = DispatchQueue(label: "unigate.test.upstream")
    private let listener: NWListener

    init(contentType: String = "text/event-stream", headers: [String: String] = [:], body: Data) throws {
        self.contentType = contentType
        self.headers = headers
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
        var headerText = "HTTP/1.1 200 OK\r\ncontent-type: \(contentType)\r\ncache-control: no-cache\r\ncontent-length: \(body.count)\r\n"
        for (key, value) in headers {
            headerText += "\(key): \(value)\r\n"
        }
        headerText += "\r\n"
        let head = Data(headerText.utf8)
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
