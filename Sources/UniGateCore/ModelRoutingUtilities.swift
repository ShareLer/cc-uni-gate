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
        appType == "claude" || appType == "claude-desktop" || appType == "codex"
    }

    public static func isClaudeLikeApp(_ appType: String) -> Bool {
        appType == "claude" || appType == "claude-desktop"
    }

    public static func isCandidateSelectable(
        _ candidate: ModelCandidate,
        uniGateModelScope: UniGateModelScope
    ) -> Bool {
        guard isUniGateScopedApp(candidate.appType) else {
            return true
        }
        return uniGateModelScope.contains(candidate)
    }

    public static func isModelSelectable(
        _ routeKey: ModelRouteKey,
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope
    ) -> Bool {
        guard isUniGateScopedApp(routeKey.appType) else {
            return true
        }
        if routeKey.appType == "claude-desktop" {
            return true
        }
        return uniGateModelScope.contains(routeKey)
    }

    public static func claudeDesktopVisibleModelKeys(
        candidates: [ModelCandidate],
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope
    ) -> [ModelRouteKey] {
        let customModelNames = Set(
            customModels.models
                .filter { $0.appType == "claude-desktop" }
                .map(\.name)
                .map(ModelNameNormalizer.normalized)
        )
        return candidates
            .filter { $0.appType == "claude-desktop" }
            .filter { uniGateModelScope.contains($0) }
            .map(\.routeKey)
            .filter { !customModelNames.contains(ModelNameNormalizer.normalized($0.logicalModel)) }
            .uniqueRouteKeys()
            .sorted { lhs, rhs in
                lhs.logicalModel.localizedStandardCompare(rhs.logicalModel) == .orderedAscending
            }
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
