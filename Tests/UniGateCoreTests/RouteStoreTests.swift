import UniGateCore
import Foundation
import Testing

struct RouteStoreTests {
    @Test
    func switchesModelProvider() throws {
        let candidates = [
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "codex", id: "p1"),
                providerName: "Provider 1",
                appType: "codex",
                clientProtocol: .codexResponses,
                apiFormat: .openaiResponses,
                upstreamModel: "gpt-5.5",
                baseURL: "https://p1.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            ),
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "codex", id: "p2"),
                providerName: "Provider 2",
                appType: "codex",
                clientProtocol: .codexResponses,
                apiFormat: .openaiResponses,
                upstreamModel: "gpt-5.5",
                baseURL: "https://p2.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            )
        ]
        let catalog = ProviderCatalog(providers: [], candidates: candidates)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        let key = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5").description

        let initial = try store.load(catalog: catalog)
        #expect(initial.routes[key]?.providerRef == ProviderRef(appType: "codex", id: "p1"))

        let switched = try store.switchRoute(
            initial,
            catalog: catalog,
            appType: "codex",
            logicalModel: "gpt-5.5",
            providerRef: ProviderRef(appType: "codex", id: "p2"),
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(switched.routes[key]?.providerRef == ProviderRef(appType: "codex", id: "p2"))
    }

    @Test
    func rejectsSwitchingToStaleDiscoveredCandidates() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://p1.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
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
            supportsLongContext: false,
            source: .staleDiscovered
        )
        let catalog = ProviderCatalog(providers: [provider], candidates: [candidate])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)

        #expect(throws: RouteStoreError.self) {
            _ = try store.switchRoute(
                RouteState(),
                catalog: catalog,
                appType: "codex",
                logicalModel: "gpt-5.5",
                providerRef: provider.ref,
                now: Date(timeIntervalSince1970: 1)
            )
        }
    }

    @Test
    func defaultStateDoesNotSelectStaleDiscoveredCandidates() {
        let staleCandidate = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: ProviderRef(appType: "codex", id: "stale"),
            providerName: "Stale Provider",
            appType: "codex",
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: "https://stale.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .staleDiscovered
        )
        let activeCandidate = ModelCandidate(
            logicalModel: "qwen3.6",
            providerRef: ProviderRef(appType: "codex", id: "active"),
            providerName: "Active Provider",
            appType: "codex",
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "qwen3.6",
            baseURL: "https://active.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )

        let staleOnly = RouteStore.defaultState(candidates: [staleCandidate])
        let mixed = RouteStore.defaultState(candidates: [staleCandidate, activeCandidate])

        #expect(staleOnly.routes.isEmpty)
        #expect(mixed.routes["codex:qwen3.6"]?.providerRef == activeCandidate.providerRef)
    }

    @Test
    func defaultStatePrefersCustomCandidateOverDiscoveredCandidate() {
        let discoveredProvider = ProviderRef(appType: "codex", id: "discovered")
        let customProvider = ProviderRef(appType: "codex", id: "custom")
        let discoveredCandidate = ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: discoveredProvider,
            providerName: "Discovered Provider",
            appType: "codex",
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: "https://discovered.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .discovered
        )
        let customCandidate = ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: customProvider,
            providerName: "Custom Provider",
            appType: "codex",
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "gpt-5.5",
            baseURL: "https://custom.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .custom
        )

        let state = RouteStore.defaultState(candidates: [discoveredCandidate, customCandidate])

        #expect(state.routes["codex:gpt-5.5"]?.providerRef == customProvider)
    }

    @Test
    func switchesGroupedModelProvidersTogether() throws {
        let provider1 = ProviderRef(appType: "claude-desktop", id: "p1")
        let provider2 = ProviderRef(appType: "claude-desktop", id: "p2")
        let flash = ModelRouteKey(appType: "claude-desktop", logicalModel: "deepseek-v4-flash")
        let pro = ModelRouteKey(appType: "claude-desktop", logicalModel: "deepseek-v4-pro")
        let candidates = [
            candidate(routeKey: flash, providerRef: provider1, providerName: "Provider 1"),
            candidate(routeKey: pro, providerRef: provider1, providerName: "Provider 1"),
            candidate(routeKey: flash, providerRef: provider2, providerName: "Provider 2"),
            candidate(routeKey: pro, providerRef: provider2, providerName: "Provider 2")
        ]
        let catalog = ProviderCatalog(providers: [], candidates: candidates)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        let initial = RouteStore.defaultState(candidates: candidates)

        let switched = try store.switchRoutes(
            initial,
            catalog: catalog,
            routeKeys: [flash, pro],
            providerRef: provider2,
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(switched.routes[flash.description]?.providerRef == provider2)
        #expect(switched.routes[pro.description]?.providerRef == provider2)
    }

    @Test
    func loadDropsRoutesOutsideProxyScopedCatalog() throws {
        let dasu = ProviderRef(appType: "codex", id: "dasu")
        let free = ProviderRef(appType: "codex", id: "free")
        let rawCatalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.4"),
                providerRef: dasu,
                providerName: "dasu-gpt-plus-0.077"
            ),
            candidate(
                routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5"),
                providerRef: free,
                providerName: "gpt-free"
            )
        ])
        let scopedCatalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(modelsByApp: ["codex": ["gpt-5.5"]]),
            customModels: CustomModelState(codexRoutePolicies: [
                CodexModelRoutePolicy(
                    routeKey: ModelRouteKey(appType: "codex", logicalModel: "gpt-5.4"),
                    isDisabled: true
                )
            ])
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            "codex:gpt-5.4": ActiveRoute(
                appType: "codex",
                logicalModel: "gpt-5.4",
                providerRef: dasu,
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            "codex:gpt-5.5": ActiveRoute(
                appType: "codex",
                logicalModel: "gpt-5.5",
                providerRef: free,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))

        let loaded = try store.load(catalog: scopedCatalog)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(RouteState.self, from: Data(contentsOf: tmp))

        #expect(loaded.routes["codex:gpt-5.4"] == nil)
        #expect(loaded.routes["codex:gpt-5.5"]?.providerRef == free)
        #expect(persisted.routes["codex:gpt-5.4"]?.providerRef == dasu)
        #expect(persisted.routes["codex:gpt-5.5"]?.providerRef == free)
    }

    @Test
    func loadKeepsRoutesWhenSelectedTargetDisappearsButRouteKeyStillExists() throws {
        let stale = ProviderRef(appType: "codex", id: "stale")
        let active = ProviderRef(appType: "codex", id: "active")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "customer_model")
        let catalog = ProviderCatalog(providers: [], candidates: [
            candidate(
                routeKey: routeKey,
                providerRef: active,
                providerName: "Active Provider"
            )
        ])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            routeKey.description: ActiveRoute(
                appType: routeKey.appType,
                logicalModel: routeKey.logicalModel,
                providerRef: stale,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))

        let loaded = try store.load(catalog: catalog)

        #expect(loaded.routes[routeKey.description]?.providerRef == stale)
    }

    @Test
    func loadDoesNotPersistEmptyCatalogOverExistingRoutes() throws {
        let defaultProvider = ProviderRef(appType: "codex", id: "p1")
        let selectedProvider = ProviderRef(appType: "codex", id: "p2")
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        let existing = RouteState(routes: [
            routeKey.description: ActiveRoute(
                appType: routeKey.appType,
                logicalModel: routeKey.logicalModel,
                providerRef: selectedProvider,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ])
        try store.save(existing)

        let loaded = try store.load(catalog: ProviderCatalog(providers: [], candidates: []))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(RouteState.self, from: Data(contentsOf: tmp))
        let reloaded = try store.load(catalog: ProviderCatalog(providers: [], candidates: [
            candidate(
                routeKey: routeKey,
                providerRef: defaultProvider,
                providerName: "Default Provider"
            ),
            candidate(
                routeKey: routeKey,
                providerRef: selectedProvider,
                providerName: "Selected Provider"
            )
        ]))

        #expect(loaded.routes.isEmpty)
        #expect(persisted.routes[routeKey.description]?.providerRef == selectedProvider)
        #expect(reloaded.routes[routeKey.description]?.providerRef == selectedProvider)
    }

    @Test
    func loadDoesNotPersistPartialCatalogOverExistingRoutes() throws {
        let missingProvider = ProviderRef(appType: "codex", id: "missing")
        let visibleProvider = ProviderRef(appType: "codex", id: "visible")
        let missingKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.4")
        let visibleKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            missingKey.description: ActiveRoute(
                appType: missingKey.appType,
                logicalModel: missingKey.logicalModel,
                providerRef: missingProvider,
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            visibleKey.description: ActiveRoute(
                appType: visibleKey.appType,
                logicalModel: visibleKey.logicalModel,
                providerRef: visibleProvider,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))

        let partialCatalog = ProviderCatalog(providers: [], candidates: [
            candidate(routeKey: visibleKey, providerRef: visibleProvider, providerName: "Visible Provider")
        ])
        let loaded = try store.load(catalog: partialCatalog)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(RouteState.self, from: Data(contentsOf: tmp))

        #expect(loaded.routes[missingKey.description] == nil)
        #expect(loaded.routes[visibleKey.description]?.providerRef == visibleProvider)
        #expect(persisted.routes[missingKey.description]?.providerRef == missingProvider)
        #expect(persisted.routes[visibleKey.description]?.providerRef == visibleProvider)
    }

    @Test
    func defaultStatePrefersConfiguredCandidateOverDiscoveredCandidate() {
        let routeKey = ModelRouteKey(appType: "codex", logicalModel: "gpt-5.5")
        let discovered = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: ProviderRef(appType: "codex", id: "discovered"),
            providerName: "A Discovered Provider",
            appType: routeKey.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: routeKey.logicalModel,
            baseURL: "https://discovered.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .discovered
        )
        let configured = ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: ProviderRef(appType: "codex", id: "configured"),
            providerName: "Z Configured Provider",
            appType: routeKey.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: routeKey.logicalModel,
            baseURL: "https://configured.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false,
            source: .configured
        )

        let state = RouteStore.defaultState(candidates: [discovered, configured])

        #expect(state.routes[routeKey.description]?.providerRef == configured.providerRef)
    }

    @Test
    func defaultStatePrefersNativeResponsesOverHigherPriorityChatBridge() {
        let chat = codexCandidate(
            id: "chat",
            providerName: "A Chat Provider",
            apiFormat: .openaiChat,
            source: .configured
        )
        let responses = codexCandidate(
            id: "responses",
            providerName: "Z Responses Provider",
            apiFormat: .openaiResponses,
            source: .discovered
        )

        let state = RouteStore.defaultState(candidates: [chat, responses])

        #expect(state.routes["codex:gpt-5.5"]?.providerRef == responses.providerRef)
    }

    @Test
    func defaultStatePrefersSupportedChatBridgeOverUnsupportedCodexFormat() {
        let unsupported = codexCandidate(
            id: "anthropic",
            providerName: "A Anthropic Provider",
            apiFormat: .anthropic
        )
        let chat = codexCandidate(
            id: "chat",
            providerName: "Z Chat Provider",
            apiFormat: .openaiChat
        )

        let state = RouteStore.defaultState(candidates: [unsupported, chat])

        #expect(state.routes["codex:gpt-5.5"]?.providerRef == chat.providerRef)
    }

    @Test
    func loadUpgradesAutomaticallySelectedChatRouteToNativeResponses() throws {
        let chat = codexCandidate(id: "chat", providerName: "Chat Provider", apiFormat: .openaiChat)
        let responses = codexCandidate(
            id: "responses",
            providerName: "Responses Provider",
            apiFormat: .openaiResponses
        )
        let catalog = ProviderCatalog(providers: [], candidates: [chat, responses])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            chat.routeKey.description: ActiveRoute(
                appType: chat.appType,
                logicalModel: chat.logicalModel,
                providerRef: chat.providerRef,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        ]))

        let loaded = try store.load(catalog: catalog)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(RouteState.self, from: Data(contentsOf: tmp))

        #expect(loaded.routes[chat.routeKey.description]?.providerRef == responses.providerRef)
        #expect(persisted.routes[chat.routeKey.description]?.providerRef == responses.providerRef)
    }

    @Test
    func loadPreservesManuallySelectedChatRoute() throws {
        let chat = codexCandidate(id: "chat", providerName: "Chat Provider", apiFormat: .openaiChat)
        let responses = codexCandidate(
            id: "responses",
            providerName: "Responses Provider",
            apiFormat: .openaiResponses
        )
        let catalog = ProviderCatalog(providers: [], candidates: [chat, responses])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            chat.routeKey.description: ActiveRoute(
                appType: chat.appType,
                logicalModel: chat.logicalModel,
                providerRef: chat.providerRef,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))

        let loaded = try store.load(catalog: catalog)

        #expect(loaded.routes[chat.routeKey.description]?.providerRef == chat.providerRef)
    }

    @Test
    func loadPreservesExplicitPreferredChatRoute() throws {
        let chat = codexCandidate(id: "chat", providerName: "Chat Provider", apiFormat: .openaiChat)
        let responses = codexCandidate(
            id: "responses",
            providerName: "Responses Provider",
            apiFormat: .openaiResponses
        )
        let catalog = ProviderCatalog(providers: [], candidates: [chat, responses])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            chat.routeKey.description: ActiveRoute(
                appType: chat.appType,
                logicalModel: chat.logicalModel,
                providerRef: chat.providerRef,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        ]))

        let loaded = try store.load(
            catalog: catalog,
            preferredProviderRefsByRouteKey: [chat.routeKey.description: chat.providerRef]
        )

        #expect(loaded.routes[chat.routeKey.description]?.providerRef == chat.providerRef)
    }

    @Test
    func defaultStatePrefersSelectedCustomModelTarget() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let fast = ModelCandidate(
            logicalModel: "fast",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "fast-upstream",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let pro = ModelCandidate(
            logicalModel: "pro",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "pro-upstream",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let fastTarget = CustomModelTarget(routeKey: fast.routeKey, providerRef: provider.ref)
        let proTarget = CustomModelTarget(routeKey: pro.routeKey, providerRef: provider.ref)
        let imported = ProviderCatalog(providers: [provider], candidates: [fast, pro])
        let customModels = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [fastTarget, proTarget],
                selectedTargetID: proTarget.id
            )
        ])
        let catalog = ProviderCatalog(
            providers: imported.providers,
            candidates: imported.candidates + customModels.expandedCandidates(from: imported)
        )

        let state = RouteStore.defaultState(
            candidates: catalog.candidates,
            preferredProviderRefsByRouteKey: customModels.preferredProviderRefsByRouteKey()
        )

        #expect(
            state.routes["codex:customer_model"]?.providerRef
                == CustomModelState.syntheticProviderRef(appType: "codex", target: proTarget)
        )
    }

    @Test
    func defaultStateDoesNotFallBackWhenSelectedCustomModelTargetIsMissing() {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let fast = ModelCandidate(
            logicalModel: "fast",
            providerRef: provider.ref,
            providerName: provider.name,
            appType: provider.appType,
            clientProtocol: .codexResponses,
            apiFormat: .openaiResponses,
            upstreamModel: "fast-upstream",
            baseURL: provider.baseURL,
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
        let fastTarget = CustomModelTarget(routeKey: fast.routeKey, providerRef: provider.ref)
        let missingTarget = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "pro"),
            providerRef: provider.ref
        )
        let imported = ProviderCatalog(providers: [provider], candidates: [fast])
        let customModels = CustomModelState(models: [
            CustomModelDefinition(
                appType: "codex",
                name: "customer_model",
                targets: [fastTarget, missingTarget],
                selectedTargetID: missingTarget.id
            )
        ])
        let catalog = ProviderCatalog(
            providers: imported.providers,
            candidates: imported.candidates + customModels.expandedCandidates(from: imported)
        )

        let state = RouteStore.defaultState(
            candidates: catalog.candidates,
            preferredProviderRefsByRouteKey: customModels.preferredProviderRefsByRouteKey()
        )

        #expect(state.routes["codex:customer_model"] == nil)
    }

    @Test
    func loadMigratesLegacyCodexSyntheticRouteForActiveNonSelectedTarget() throws {
        let provider = ImportedProvider(
            id: "p1",
            appType: "codex",
            name: "Provider 1",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://api.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("key-1")])],
            meta: [:]
        )
        let fast = candidate(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "fast"),
            providerRef: provider.ref,
            providerName: provider.name
        )
        let pro = candidate(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "pro"),
            providerRef: provider.ref,
            providerName: provider.name
        )
        let fastTarget = CustomModelTarget(routeKey: fast.routeKey, providerRef: provider.ref)
        let proTarget = CustomModelTarget(routeKey: pro.routeKey, providerRef: provider.ref)
        let destination = ModelRouteKey(appType: "codex", logicalModel: "customer_model")
        let customModels = CustomModelState(models: [
            CustomModelDefinition(
                appType: destination.appType,
                name: destination.logicalModel,
                targets: [fastTarget, proTarget],
                selectedTargetID: proTarget.id
            )
        ])
        let rawCatalog = ProviderCatalog(providers: [provider], candidates: [fast, pro])
        let catalog = rawCatalog.scopedForProxy(
            uniGateModelScope: UniGateModelScope(),
            customModels: customModels
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        let updatedAt = Date(timeIntervalSince1970: 123)
        try store.save(RouteState(routes: [
            destination.description: ActiveRoute(
                appType: destination.appType,
                logicalModel: destination.logicalModel,
                providerRef: CustomModelState.legacySyntheticProviderRef(
                    appType: "codex",
                    target: fastTarget
                ),
                updatedAt: updatedAt
            )
        ]))

        let loaded = try store.load(
            catalog: catalog,
            preferredProviderRefsByRouteKey: customModels.preferredProviderRefsByRouteKey(
                availableIn: catalog
            ),
            providerRefMigrationPlan: customModels.codexProviderRefMigrationPlan()
        )
        let reloaded = try store.load(
            catalog: catalog,
            preferredProviderRefsByRouteKey: customModels.preferredProviderRefsByRouteKey(
                availableIn: catalog
            ),
            providerRefMigrationPlan: customModels.codexProviderRefMigrationPlan()
        )

        let expected = CustomModelState.syntheticProviderRef(appType: "codex", target: fastTarget)
        #expect(loaded.routes[destination.description]?.providerRef == expected)
        #expect(loaded.routes[destination.description]?.updatedAt == updatedAt)
        #expect(reloaded.routes[destination.description]?.providerRef == expected)
    }

    @Test
    func loadFailsClosedWhenLegacyCodexSyntheticRouteIsAmbiguous() throws {
        let firstTarget = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "c"),
            providerRef: ProviderRef(appType: "codex", id: "a|codex:b")
        )
        let secondTarget = CustomModelTarget(
            routeKey: ModelRouteKey(appType: "codex", logicalModel: "b|codex:c"),
            providerRef: ProviderRef(appType: "codex", id: "a")
        )
        let destination = ModelRouteKey(appType: "codex", logicalModel: "customer_model")
        let customModels = CustomModelState(models: [
            CustomModelDefinition(
                appType: destination.appType,
                name: destination.logicalModel,
                targets: [firstTarget, secondTarget],
                selectedTargetID: firstTarget.id
            )
        ])
        let legacy = CustomModelState.legacySyntheticProviderRef(
            appType: "codex",
            target: firstTarget
        )
        let maliciousProvider = ImportedProvider(
            id: legacy.id,
            appType: "codex",
            name: "Collision Provider",
            category: nil,
            sortIndex: 1,
            isCurrent: false,
            apiFormat: .openaiResponses,
            baseURL: "https://collision.example.com",
            hasSecret: true,
            settings: ["auth": .object(["OPENAI_API_KEY": .string("collision-key")])],
            meta: [:]
        )
        let maliciousCandidate = candidate(
            routeKey: destination,
            providerRef: maliciousProvider.ref,
            providerName: maliciousProvider.name
        )
        let catalog = ProviderCatalog(
            providers: [maliciousProvider],
            candidates: [maliciousCandidate]
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("routes.json")
        let store = RouteStore(fileURL: tmp)
        try store.save(RouteState(routes: [
            destination.description: ActiveRoute(
                appType: destination.appType,
                logicalModel: destination.logicalModel,
                providerRef: legacy,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        ]))

        let loaded = try store.load(
            catalog: catalog,
            providerRefMigrationPlan: customModels.codexProviderRefMigrationPlan()
        )
        let activeProviderRef = try #require(loaded.routes[destination.description]?.providerRef)

        #expect(activeProviderRef.appType == "__unigate_unresolved__")
        #expect(activeProviderRef != maliciousProvider.ref)
    }

    @Test
    func keepsSameModelSeparateAcrossApps() {
        let candidates = [
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "codex", id: "p1"),
                providerName: "Codex Provider",
                appType: "codex",
                clientProtocol: .codexResponses,
                apiFormat: .openaiResponses,
                upstreamModel: "gpt-5.5",
                baseURL: "https://codex.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            ),
            ModelCandidate(
                logicalModel: "gpt-5.5",
                providerRef: ProviderRef(appType: "claude", id: "p2"),
                providerName: "Claude Provider",
                appType: "claude",
                clientProtocol: .anthropicMessages,
                apiFormat: .anthropic,
                upstreamModel: "gpt-5.5",
                baseURL: "https://claude.example.com",
                requiresTransform: false,
                label: nil,
                supportsLongContext: false
            )
        ]

        let state = RouteStore.defaultState(candidates: candidates)

        #expect(state.routes["codex:gpt-5.5"]?.providerRef == ProviderRef(appType: "codex", id: "p1"))
        #expect(state.routes["claude:gpt-5.5"]?.providerRef == ProviderRef(appType: "claude", id: "p2"))
    }

    private func candidate(
        routeKey: ModelRouteKey,
        providerRef: ProviderRef,
        providerName: String
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: routeKey.logicalModel,
            providerRef: providerRef,
            providerName: providerName,
            appType: routeKey.appType,
            clientProtocol: .anthropicMessages,
            apiFormat: .anthropic,
            upstreamModel: "deepseek-v4-flash",
            baseURL: "https://api.example.com",
            requiresTransform: false,
            label: nil,
            supportsLongContext: false
        )
    }

    private func codexCandidate(
        id: String,
        providerName: String,
        apiFormat: ApiFormat,
        source: ModelCandidateSource = .configured
    ) -> ModelCandidate {
        ModelCandidate(
            logicalModel: "gpt-5.5",
            providerRef: ProviderRef(appType: "codex", id: id),
            providerName: providerName,
            appType: "codex",
            clientProtocol: .codexResponses,
            apiFormat: apiFormat,
            upstreamModel: "gpt-5.5",
            baseURL: "https://api.example.com",
            requiresTransform: apiFormat != .openaiResponses,
            label: nil,
            supportsLongContext: false,
            source: source
        )
    }

}
