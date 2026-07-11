import Foundation

public enum ModelNameNormalizer {
    public static func stripOneMSuffix(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"\[\s*1m\s*\]\s*$"#, options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalized(_ model: String) -> String {
        stripOneMSuffix(model).lowercased()
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    public static func hasOneMMarker(_ model: String) -> Bool {
        model.range(of: #"\[\s*1m\s*\]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public enum ClaudeRouteRole: String, Sendable {
    case sonnet
    case opus
    case fable
    case haiku

    public var rank: Int {
        switch self {
        case .sonnet:
            return 0
        case .opus:
            return 1
        case .fable:
            return 2
        case .haiku:
            return 3
        }
    }

    public static func role(in model: String) -> ClaudeRouteRole? {
        let normalized = model.lowercased()
        if normalized.contains("sonnet") {
            return .sonnet
        }
        if normalized.contains("opus") {
            return .opus
        }
        if normalized.contains("fable") {
            return .fable
        }
        if normalized.contains("haiku") {
            return .haiku
        }
        return nil
    }

    public static func rank(for model: String) -> Int {
        role(in: model)?.rank ?? 4
    }

    public static func rank(for routeKey: ModelRouteKey) -> Int {
        guard ModelRouteVisibility.isClaudeLikeApp(routeKey.appType) else {
            return 99
        }
        return rank(for: routeKey.logicalModel)
    }
}

public enum ModelRouteVisibility {
    public static func isUniGateScopedApp(_ appType: String) -> Bool {
        UniGateAppRegistry.isUniGateScoped(appType)
    }

    public static func isClaudeLikeApp(_ appType: String) -> Bool {
        UniGateAppRegistry.isClaudeLike(appType)
    }

    public static func isCandidateSelectable(
        _ candidate: ModelCandidate,
        uniGateModelScope: UniGateModelScope
    ) -> Bool {
        if candidate.source == .custom {
            return true
        }
        if candidate.appType == UniGateAppRegistry.codex {
            return true
        }
        guard isUniGateScopedApp(candidate.appType) else {
            return true
        }
        return uniGateModelScope.contains(candidate)
    }

    public static func isCandidateSelectable(
        _ candidate: ModelCandidate,
        catalog _: ProviderCatalog,
        uniGateModelScope: UniGateModelScope
    ) -> Bool {
        return isCandidateSelectable(candidate, uniGateModelScope: uniGateModelScope)
    }

    public static func visibleConfiguredBaseRouteKeys(
        catalog: ProviderCatalog,
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        preferences: AppPreferences
    ) -> [ModelRouteKey] {
        let allRouteKeys = configuredBaseRouteKeys(
            catalog: catalog,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope
        )
        let visibleNonCodexRouteKeys = Set(preferences.visibleRouteKeyList(
            allRouteKeys: allRouteKeys.filter { $0.appType != UniGateAppRegistry.codex }
        ))
        return allRouteKeys.filter {
            $0.appType == UniGateAppRegistry.codex || visibleNonCodexRouteKeys.contains($0)
        }
    }

    public static func configuredBaseRouteKeys(
        catalog: ProviderCatalog,
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope
    ) -> [ModelRouteKey] {
        let customModelIdentities = Set(customModels.models.map {
            NormalizedRouteKeyIdentity(appType: $0.appType, logicalModel: $0.name)
        })
        var routeKeys = Set(catalog.candidates.compactMap { candidate -> ModelRouteKey? in
            guard candidate.providerRef == candidate.upstreamProviderRef,
                  !customModelIdentities.contains(NormalizedRouteKeyIdentity(routeKey: candidate.routeKey)) else {
                return nil
            }
            if candidate.appType == UniGateAppRegistry.codex {
                return candidate.routeKey
            }
            guard candidate.source.isRouteKeySeed,
                  isCandidateSelectable(candidate, uniGateModelScope: uniGateModelScope) else {
                return nil
            }
            return candidate.routeKey
        })

        for model in uniGateModelScope.models(for: UniGateAppRegistry.codex) {
            let routeKey = ModelRouteKey(appType: UniGateAppRegistry.codex, logicalModel: model)
            if !customModelIdentities.contains(NormalizedRouteKeyIdentity(routeKey: routeKey)) {
                routeKeys.insert(routeKey)
            }
        }
        for policy in customModels.codexRoutePolicies {
            if !customModelIdentities.contains(NormalizedRouteKeyIdentity(routeKey: policy.routeKey)) {
                routeKeys.insert(policy.routeKey)
            }
        }

        return Array(routeKeys).sorted(by: routeKeySort)
    }

    public static func addingCustomModelRouteKeys(
        to routeKeys: [ModelRouteKey],
        customModels: CustomModelState
    ) -> [ModelRouteKey] {
        (routeKeys + customModels.models.map { ModelRouteKey(appType: $0.appType, logicalModel: $0.name) })
            .uniqueRouteKeys()
            .sorted(by: routeKeySort)
    }

    private static func routeKeySort(_ lhs: ModelRouteKey, _ rhs: ModelRouteKey) -> Bool {
        let appCompare = ProviderDisplay.appTypeLabel(lhs.appType)
            .localizedStandardCompare(ProviderDisplay.appTypeLabel(rhs.appType))
        if appCompare != .orderedSame {
            return appCompare == .orderedAscending
        }
        return lhs.logicalModel.localizedStandardCompare(rhs.logicalModel) == .orderedAscending
    }
}

private struct NormalizedRouteKeyIdentity: Hashable {
    let appType: String
    let logicalModel: String

    init(appType: String, logicalModel: String) {
        self.appType = appType
        self.logicalModel = ModelNameNormalizer.normalized(logicalModel)
    }

    init(routeKey: ModelRouteKey) {
        self.init(appType: routeKey.appType, logicalModel: routeKey.logicalModel)
    }
}

private extension Array where Element == ModelRouteKey {
    func uniqueRouteKeys() -> [ModelRouteKey] {
        var seen = Set<ModelRouteKey>()
        var result: [ModelRouteKey] = []
        for routeKey in self where !seen.contains(routeKey) {
            seen.insert(routeKey)
            result.append(routeKey)
        }
        return result
    }
}
