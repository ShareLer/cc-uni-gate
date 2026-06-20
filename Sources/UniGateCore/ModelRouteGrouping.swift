import Foundation

public struct ModelCandidateTargetIdentity: Hashable, Sendable {
    public let appType: String
    public let providerRef: ProviderRef
    public let upstreamProviderRef: ProviderRef
    public let clientProtocol: ClientProtocolKind
    public let apiFormat: ApiFormat
    public let upstreamModel: String
    public let baseURL: String
    public let requiresTransform: Bool

    public init(candidate: ModelCandidate) {
        self.appType = candidate.appType
        self.providerRef = candidate.providerRef
        self.upstreamProviderRef = candidate.upstreamProviderRef
        self.clientProtocol = candidate.clientProtocol
        self.apiFormat = candidate.apiFormat
        self.upstreamModel = candidate.upstreamModelDisplayName
        self.baseURL = candidate.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.requiresTransform = candidate.requiresTransform
    }
}

public struct ModelDisplayIdentity: Hashable, Sendable {
    public let appType: String
    public let upstreamModel: String

    public init(candidate: ModelCandidate) {
        self.appType = candidate.appType
        self.upstreamModel = candidate.upstreamModelDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public struct ModelRouteGroup: Hashable, Identifiable, Sendable {
    public let routeKey: ModelRouteKey
    public let routeKeys: [ModelRouteKey]

    public var id: String {
        routeKey.description
    }

    public init(routeKey: ModelRouteKey, routeKeys: [ModelRouteKey]) {
        self.routeKey = routeKey
        self.routeKeys = routeKeys
    }
}

public enum ModelRouteGrouping {
    public static func displayCandidates(
        _ candidates: [ModelCandidate],
        activeProviderRef: ProviderRef? = nil,
        restrictToActiveDisplayIdentity: Bool = true
    ) -> [ModelCandidate] {
        let deduplicatedCandidates = CustomModelState.deduplicatedTargetCandidates(candidates)
        guard restrictToActiveDisplayIdentity else {
            return deduplicatedCandidates
        }
        let displayIdentity = displayIdentity(
            in: candidates,
            activeProviderRef: activeProviderRef
        )
        return deduplicatedCandidates.filter { candidate in
            displayIdentity.map { ModelDisplayIdentity(candidate: candidate) == $0 } ?? true
        }
    }

    public static func groups(
        routeKeys: [ModelRouteKey],
        candidates: [ModelCandidate]
    ) -> [ModelRouteGroup] {
        let candidatesByRouteKey = Dictionary(grouping: candidates, by: \.routeKey)
        var orderedIdentities: [RouteGroupIdentity] = []
        var keysByIdentity: [RouteGroupIdentity: [ModelRouteKey]] = [:]

        for routeKey in routeKeys {
            let routeCandidates = candidatesByRouteKey[routeKey] ?? []
            let identity = RouteGroupIdentity(routeKey: routeKey, candidates: routeCandidates)
            if keysByIdentity[identity] == nil {
                orderedIdentities.append(identity)
            }
            keysByIdentity[identity, default: []].append(routeKey)
        }

        return orderedIdentities.compactMap { identity in
            guard let routeKeys = keysByIdentity[identity], !routeKeys.isEmpty else {
                return nil
            }
            return ModelRouteGroup(
                routeKey: preferredRouteKey(in: routeKeys),
                routeKeys: routeKeys
            )
        }
    }

    private static func preferredRouteKey(in routeKeys: [ModelRouteKey]) -> ModelRouteKey {
        routeKeys.min { lhs, rhs in
            let lhsNormalized = ModelCandidate.stripOneMSuffix(lhs.logicalModel)
            let rhsNormalized = ModelCandidate.stripOneMSuffix(rhs.logicalModel)
            let lhsHasSuffix = lhsNormalized != lhs.logicalModel
            let rhsHasSuffix = rhsNormalized != rhs.logicalModel
            if lhsHasSuffix != rhsHasSuffix {
                return !lhsHasSuffix
            }

            let lhsRank = claudeRouteRoleRank(lhs)
            let rhsRank = claudeRouteRoleRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            let nameCompare = lhsNormalized.localizedStandardCompare(rhsNormalized)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            return lhs.description.localizedStandardCompare(rhs.description) == .orderedAscending
        } ?? routeKeys[0]
    }

    private static func claudeRouteRoleRank(_ routeKey: ModelRouteKey) -> Int {
        guard routeKey.appType == "claude" || routeKey.appType == "claude-desktop" else {
            return 99
        }
        let normalized = routeKey.logicalModel.lowercased()
        if normalized.contains("sonnet") {
            return 0
        }
        if normalized.contains("opus") {
            return 1
        }
        if normalized.contains("fable") {
            return 2
        }
        if normalized.contains("haiku") {
            return 3
        }
        return 4
    }

    private static func displayIdentity(
        in candidates: [ModelCandidate],
        activeProviderRef: ProviderRef?
    ) -> ModelDisplayIdentity? {
        if let activeProviderRef,
           let active = candidates.first(where: { $0.providerRef == activeProviderRef }) {
            return ModelDisplayIdentity(candidate: active)
        }
        return candidates.first.map(ModelDisplayIdentity.init)
    }
}

private struct RouteGroupIdentity: Hashable {
    let appType: String
    let targetIdentities: Set<ModelCandidateTargetIdentity>
    let fallbackRouteKeyDescription: String?

    init(routeKey: ModelRouteKey, candidates: [ModelCandidate]) {
        self.appType = routeKey.appType
        self.targetIdentities = Set(candidates.map(ModelCandidateTargetIdentity.init))
        self.fallbackRouteKeyDescription = candidates.isEmpty ? routeKey.description : nil
    }
}
