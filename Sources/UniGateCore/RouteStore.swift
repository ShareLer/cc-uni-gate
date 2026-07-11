import Foundation

public final class RouteStore: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = RouteStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultFileURL() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("routes.json", isDirectory: false)
    }

    public func load(
        catalog: ProviderCatalog,
        preferredProviderRefsByRouteKey: [String: ProviderRef] = [:]
    ) throws -> RouteState {
        let state: RouteState
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            state = try decoder.decode(RouteState.self, from: data)
        } else {
            state = RouteStore.defaultState(
                candidates: catalog.candidates,
                preferredProviderRefsByRouteKey: preferredProviderRefsByRouteKey
            )
        }

        let merged = merge(
            state,
            catalog: catalog,
            preferredProviderRefsByRouteKey: preferredProviderRefsByRouteKey
        )
        if state.routes.isEmpty || (!merged.routes.isEmpty && !dropsExistingRouteKeys(state, catalog: catalog)) {
            try save(merged)
        }
        return merged
    }

    public func save(_ state: RouteState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    public func switchRoute(
        _ state: RouteState,
        catalog: ProviderCatalog,
        appType: String,
        logicalModel: String,
        providerRef: ProviderRef,
        now: Date = Date()
    ) throws -> RouteState {
        let exists = catalog.candidates.contains {
            $0.appType == appType
                && $0.logicalModel == logicalModel
                && $0.providerRef == providerRef
                && isSwitchableCandidate($0, in: catalog)
        }
        guard exists else {
            throw RouteStoreError.invalidCandidate(
                routeKey: ModelRouteKey(appType: appType, logicalModel: logicalModel).description,
                providerRef: providerRef.description
            )
        }

        var next = state
        let key = ModelRouteKey(appType: appType, logicalModel: logicalModel)
        next.routes[key.description] = ActiveRoute(
            appType: appType,
            logicalModel: logicalModel,
            providerRef: providerRef,
            updatedAt: now
        )
        try save(next)
        return next
    }

    public func switchRoutes(
        _ state: RouteState,
        catalog: ProviderCatalog,
        routeKeys: [ModelRouteKey],
        providerRef: ProviderRef,
        now: Date = Date()
    ) throws -> RouteState {
        var next = state
        for routeKey in routeKeys {
            let exists = catalog.candidates.contains {
                $0.appType == routeKey.appType
                    && $0.logicalModel == routeKey.logicalModel
                    && $0.providerRef == providerRef
                    && isSwitchableCandidate($0, in: catalog)
            }
            guard exists else {
                throw RouteStoreError.invalidCandidate(
                    routeKey: routeKey.description,
                    providerRef: providerRef.description
                )
            }
            next.routes[routeKey.description] = ActiveRoute(
                appType: routeKey.appType,
                logicalModel: routeKey.logicalModel,
                providerRef: providerRef,
                updatedAt: now
            )
        }
        try save(next)
        return next
    }

    public static func defaultState(
        candidates: [ModelCandidate],
        preferredProviderRefsByRouteKey: [String: ProviderRef] = [:]
    ) -> RouteState {
        var grouped: [String: [ModelCandidate]] = [:]
        for candidate in candidates {
            guard candidate.source != .staleDiscovered else {
                continue
            }
            grouped[candidate.routeKey.description, default: []].append(candidate)
        }

        var routes: [String: ActiveRoute] = [:]
        for (key, candidates) in grouped {
            if let preferredProviderRef = preferredProviderRefsByRouteKey[key] {
                if let preferred = candidates.first(where: { $0.providerRef == preferredProviderRef }) {
                    routes[key] = ActiveRoute(
                        appType: preferred.appType,
                        logicalModel: preferred.logicalModel,
                        providerRef: preferred.providerRef,
                        updatedAt: Date(timeIntervalSince1970: 0)
                    )
                }
                continue
            }
            let sortedCandidates = candidates.sorted(by: defaultCandidateSort)
            guard let selected = sortedCandidates.first else {
                continue
            }
            routes[key] = ActiveRoute(
                appType: selected.appType,
                logicalModel: selected.logicalModel,
                providerRef: selected.providerRef,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
        return RouteState(routes: routes)
    }

    private func merge(
        _ state: RouteState,
        catalog: ProviderCatalog,
        preferredProviderRefsByRouteKey: [String: ProviderRef] = [:]
    ) -> RouteState {
        let availableRouteKeys = Set(catalog.routeKeys)
        let defaults = RouteStore.defaultState(
            candidates: catalog.candidates,
            preferredProviderRefsByRouteKey: preferredProviderRefsByRouteKey
        )
        var merged = RouteState()

        for (rawKey, route) in state.routes {
            let routeKey = ModelRouteKey(description: rawKey)
                ?? ModelRouteKey(appType: route.appType, logicalModel: route.logicalModel)
            guard availableRouteKeys.contains(routeKey) else {
                continue
            }
            if
                preferredProviderRefsByRouteKey[routeKey.description] == nil,
                let defaultRoute = defaults.routes[routeKey.description],
                shouldUpgradeAutomaticallySelectedRoute(
                    route,
                    to: defaultRoute,
                    routeKey: routeKey,
                    catalog: catalog
                )
            {
                merged.routes[routeKey.description] = defaultRoute
            } else {
                merged.routes[routeKey.description] = route
            }
        }

        for (key, route) in defaults.routes where merged.routes[key] == nil {
            merged.routes[key] = route
        }
        return merged
    }

    private func dropsExistingRouteKeys(_ state: RouteState, catalog: ProviderCatalog) -> Bool {
        let availableRouteKeys = Set(catalog.routeKeys)
        return state.routes.contains { rawKey, route in
            let routeKey = ModelRouteKey(description: rawKey)
                ?? ModelRouteKey(appType: route.appType, logicalModel: route.logicalModel)
            return !availableRouteKeys.contains(routeKey)
        }
    }

    private static func defaultCandidateSort(_ lhs: ModelCandidate, _ rhs: ModelCandidate) -> Bool {
        if lhs.protocolCompatibility != rhs.protocolCompatibility {
            return lhs.protocolCompatibility.rawValue < rhs.protocolCompatibility.rawValue
        }
        if lhs.source != rhs.source {
            return sourcePriority(lhs.source) < sourcePriority(rhs.source)
        }
        return lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
    }

    private func shouldUpgradeAutomaticallySelectedRoute(
        _ route: ActiveRoute,
        to defaultRoute: ActiveRoute,
        routeKey: ModelRouteKey,
        catalog: ProviderCatalog
    ) -> Bool {
        guard route.updatedAt == Date(timeIntervalSince1970: 0) else {
            return false
        }
        guard
            let currentCandidate = catalog.candidates.first(where: {
                $0.routeKey == routeKey && $0.providerRef == route.providerRef
            }),
            let defaultCandidate = catalog.candidates.first(where: {
                $0.routeKey == routeKey && $0.providerRef == defaultRoute.providerRef
            })
        else {
            return false
        }
        return defaultCandidate.protocolCompatibility.rawValue
            < currentCandidate.protocolCompatibility.rawValue
    }

    private static func sourcePriority(_ source: ModelCandidateSource) -> Int {
        switch source {
        case .configured:
            return 0
        case .custom:
            return 1
        case .discovered:
            return 2
        case .staleDiscovered:
            return 3
        }
    }

    private func isSwitchableCandidate(_ candidate: ModelCandidate, in catalog: ProviderCatalog) -> Bool {
        !candidate.isDiscoveryStale(in: catalog)
    }
}

public enum RouteStoreError: Error, LocalizedError {
    case invalidCandidate(routeKey: String, providerRef: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidCandidate(routeKey, ref):
            return "\(ref) is not a candidate for \(routeKey)"
        }
    }
}
