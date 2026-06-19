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

    public func load(catalog: ProviderCatalog) throws -> RouteState {
        let state: RouteState
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            state = try decoder.decode(RouteState.self, from: data)
        } else {
            state = RouteStore.defaultState(candidates: catalog.candidates)
        }

        let merged = merge(state, catalog: catalog)
        try save(merged)
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
            $0.appType == appType && $0.logicalModel == logicalModel && $0.providerRef == providerRef
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

    public static func defaultState(candidates: [ModelCandidate]) -> RouteState {
        var grouped: [String: [ModelCandidate]] = [:]
        for candidate in candidates {
            grouped[candidate.routeKey.description, default: []].append(candidate)
        }

        var routes: [String: ActiveRoute] = [:]
        for (key, candidates) in grouped {
            guard
                let selected = candidates.first(where: { !$0.requiresTransform })
                    ?? candidates.first
            else {
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

    private func merge(_ state: RouteState, catalog: ProviderCatalog) -> RouteState {
        var merged = RouteStore.defaultState(candidates: catalog.candidates)
        for (rawKey, route) in state.routes {
            let routeKey = ModelRouteKey(description: rawKey)
                ?? ModelRouteKey(appType: route.appType, logicalModel: route.logicalModel)
            let stillValid = catalog.candidates.contains {
                $0.appType == routeKey.appType
                    && $0.logicalModel == routeKey.logicalModel
                    && $0.providerRef == route.providerRef
            }
            if stillValid {
                merged.routes[routeKey.description] = ActiveRoute(
                    appType: routeKey.appType,
                    logicalModel: routeKey.logicalModel,
                    providerRef: route.providerRef,
                    updatedAt: route.updatedAt
                )
                continue
            }

            if let match = normalizedClaudeMatch(routeKey: routeKey, route: route, catalog: catalog) {
                merged.routes[match.routeKey.description] = ActiveRoute(
                    appType: match.appType,
                    logicalModel: match.logicalModel,
                    providerRef: route.providerRef,
                    updatedAt: route.updatedAt
                )
                continue
            }

            let legacyMatches = catalog.candidates.filter {
                $0.logicalModel == rawKey && $0.providerRef == route.providerRef
            }
            for match in legacyMatches {
                merged.routes[match.routeKey.description] = ActiveRoute(
                    appType: match.appType,
                    logicalModel: match.logicalModel,
                    providerRef: route.providerRef,
                    updatedAt: route.updatedAt
                )
            }
        }
        return merged
    }

    private func normalizedClaudeMatch(
        routeKey: ModelRouteKey,
        route: ActiveRoute,
        catalog: ProviderCatalog
    ) -> ModelCandidate? {
        guard routeKey.appType == "claude" || routeKey.appType == "claude-desktop" else {
            return nil
        }
        let normalizedModel = stripOneMSuffix(routeKey.logicalModel)
        return catalog.candidates.first {
            $0.appType == routeKey.appType
                && $0.providerRef == route.providerRef
                && stripOneMSuffix($0.logicalModel).caseInsensitiveCompare(normalizedModel) == .orderedSame
        }
    }

    private func stripOneMSuffix(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"\[\s*1m\s*\]\s*$"#, options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
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
