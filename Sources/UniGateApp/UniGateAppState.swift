import AppKit
import Foundation
import SwiftUI
import UniGateCore

@MainActor
final class UniGateAppState: ObservableObject {
    enum Screen {
        case routes
        case settings
    }

    enum CustomModelAvailability {
        case configured
        case unconfigured
        case missingTarget
    }

    @Published var screen: Screen = .routes
    @Published var catalog = ProviderCatalog(providers: [], candidates: [])
    @Published var routes = RouteState()
    @Published var preferences = AppPreferences()
    @Published var customModels = CustomModelState()
    @Published var uniGateModelScope = UniGateModelScope()
    @Published var proxyStatus: ProxyStatus = .starting
    @Published var proxyPort: UInt16 = 17888
    @Published var recentEvents: [ProxyEvent] = []
    @Published var forwardedRequestCounts: [String: Int] = [:]
    @Published var selectedAppType: String?
    @Published var expandedRouteKeyDescription: String?
    @Published var loadError: String?
    @Published var toast: String?

    var onSwitchProvider: (([ModelRouteKey], ProviderRef) -> Void)?
    var onReload: (() -> Void)?
    var onOpenAppFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSaveSettings: ((AppPreferences, CustomModelState) -> Void)?
    var onApplySettings: ((AppPreferences, CustomModelState) -> Void)?

    private var toastToken = UUID()
    private var settingsViewModel: SettingsViewModel?

    func updateSnapshot(
        catalog: ProviderCatalog,
        routes: RouteState,
        preferences: AppPreferences,
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        proxyStatus: ProxyStatus,
        proxyPort: UInt16,
        loadError: String? = nil
    ) {
        self.catalog = catalog
        self.routes = routes
        self.preferences = preferences
        self.customModels = customModels
        self.uniGateModelScope = uniGateModelScope
        self.proxyStatus = proxyStatus
        self.proxyPort = proxyPort
        self.loadError = loadError
        syncSelectedAppType()
        updateSettingsViewModel()
    }

    func updateProxyStatus(_ status: ProxyStatus, port: UInt16) {
        proxyStatus = status
        proxyPort = port
    }

    func updateRecentEvents(_ events: [ProxyEvent]) {
        recentEvents = events
    }

    func updateForwardedRequestCounts(_ counts: [String: Int]) {
        forwardedRequestCounts = counts
    }

    func routeGroupsForCurrentApp() -> [ModelRouteGroup] {
        let appType = currentAppType
        let groups = displayRouteGroups.filter { appType == nil || $0.routeKey.appType == appType }
        return groups
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = routeInteractivityRank(lhs.element)
                let rhsRank = routeInteractivityRank(rhs.element)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    var appTypes: [String] {
        let routeAppTypes = Array(Set(displayRouteGroups.map(\.routeKey.appType))).sorted {
            ProviderDisplay.appTypeLabel($0)
                .localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
        if !routeAppTypes.isEmpty {
            return routeAppTypes
        }
        return catalog.appTypes
    }

    var currentAppType: String? {
        if let selectedAppType, appTypes.contains(selectedAppType) {
            return selectedAppType
        }
        return appTypes.first
    }

    var visibleRouteKeys: [ModelRouteKey] {
        let candidates = scopedBaseCandidates()
        let scopedRouteKeys = Set(candidates.map(\.routeKey))
        let configuredRouteKeys = catalog.routeKeys.filter {
            $0.appType != "claude-desktop" && scopedRouteKeys.contains($0)
        }
        let desktopRouteKeys = claudeDesktopVisibleModelKeys(candidates: candidates)
        return preferences.visibleRouteKeyList(allRouteKeys: configuredRouteKeys)
            + preferences.visibleRouteKeyList(allRouteKeys: desktopRouteKeys)
    }

    var displayRouteKeys: [ModelRouteKey] {
        displayRouteGroups.map(\.routeKey)
    }

    var displayRouteGroups: [ModelRouteGroup] {
        let candidates = scopedBaseCandidates()
        let routeKeys = visibleRouteKeys
        let visibleGroups = ModelRouteGrouping.groups(
            routeKeys: routeKeys.filter { $0.appType != "claude-desktop" },
            candidates: candidates
        )
        let desktopGroups = claudeDesktopModelGroups(
            routeKeys: routeKeys.filter { $0.appType == "claude-desktop" },
            candidates: candidates
        )
        let customGroups = customModels.models.map {
            let routeKey = ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
            return ModelRouteGroup(routeKey: routeKey, routeKeys: [routeKey])
        }
        return visibleGroups + desktopGroups + customGroups
    }

    var modelCountText: String {
        guard let appType = currentAppType else {
            return "\(displayRouteGroups.count) 个模型"
        }
        let appGroups = displayRouteGroups.filter { $0.routeKey.appType == appType }
        return "\(appGroups.count) 个模型"
    }

    var providerCountText: String {
        guard let appType = currentAppType else {
            return "\(catalog.providers.count) 个供应商"
        }
        let count = catalog.providers.filter { $0.appType == appType }.count
        return "\(count) 个供应商"
    }

    func selectApp(_ appType: String) {
        selectedAppType = appType
        expandedRouteKeyDescription = nil
    }

    func candidates(for routeKey: ModelRouteKey) -> [ModelCandidate] {
        let candidates = catalog.candidates(for: routeKey)
        guard customModel(for: routeKey) == nil else {
            return candidates
        }
        return candidates.filter(isCandidateInUniGateScope)
    }

    func candidates(for routeGroup: ModelRouteGroup) -> [ModelCandidate] {
        var candidates = routeGroup.routeKeys.flatMap { self.candidates(for: $0) }
        let isCustomModel = customModel(for: routeGroup.routeKey) != nil
        if isSyntheticClaudeDesktopGroup(routeGroup), !isCustomModel {
            candidates = candidates.filter {
                modelNameMatches($0.upstreamModelDisplayName, routeGroup.routeKey.logicalModel)
            }
        }
        return ModelRouteGrouping.displayCandidates(
            candidates,
            activeProviderRef: activeProviderRef(for: routeGroup),
            restrictToActiveDisplayIdentity: !isCustomModel
        )
            .sorted { lhs, rhs in
                let providerCompare = lhs.providerName.localizedStandardCompare(rhs.providerName)
                if providerCompare != .orderedSame {
                    return providerCompare == .orderedAscending
                }
                return lhs.displayModelName.localizedStandardCompare(rhs.displayModelName) == .orderedAscending
            }
    }

    func activeCandidate(for routeKey: ModelRouteKey) -> ModelCandidate? {
        guard let providerRef = routes.routes[routeKey.description]?.providerRef else {
            return nil
        }
        return candidates(for: routeKey).first { $0.providerRef == providerRef }
    }

    func activeCandidate(for routeGroup: ModelRouteGroup) -> ModelCandidate? {
        guard let providerRef = activeProviderRef(for: routeGroup) else {
            return nil
        }
        return candidates(for: routeGroup).first { $0.providerRef == providerRef }
    }

    func isActive(_ candidate: ModelCandidate, for routeGroup: ModelRouteGroup) -> Bool {
        activeProviderRef(for: routeGroup) == candidate.providerRef
    }

    func isExpanded(_ routeGroup: ModelRouteGroup) -> Bool {
        expandedRouteKeyDescription == routeGroup.id
    }

    func toggleExpanded(_ routeGroup: ModelRouteGroup) {
        if isExpanded(routeGroup) {
            expandedRouteKeyDescription = nil
        } else {
            expandedRouteKeyDescription = routeGroup.id
        }
    }

    func providerTitle(_ candidate: ModelCandidate) -> String {
        var parts = [candidate.providerName]
        let displayUpstreamModel = candidate.upstreamModelDisplayName
        let displayLogicalModel = ModelCandidate.stripOneMSuffix(candidate.logicalModel)
        if displayUpstreamModel != displayLogicalModel {
            parts.append(displayUpstreamModel)
        }
        if candidate.requiresTransform {
            parts.append("需要转换")
        } else {
            parts.append(candidate.apiFormat.rawValue)
        }
        return parts.joined(separator: " · ")
    }

    func modelTitleText(for routeGroup: ModelRouteGroup) -> String {
        let routeKey = routeGroup.routeKey
        guard customModelAvailability(for: routeKey) == nil else {
            return routeKey.logicalModel
        }
        guard routeKey.appType == "claude-desktop",
              let candidate = activeCandidate(for: routeGroup) ?? candidates(for: routeGroup).first
        else {
            return ModelCandidate.stripOneMSuffix(routeKey.logicalModel)
        }
        return candidate.displayModelName
    }

    func modelDetailText(for routeGroup: ModelRouteGroup) -> String {
        let routeKey = routeGroup.routeKey
        if let availability = customModelAvailability(for: routeKey) {
            switch availability {
            case .configured:
                break
            case .unconfigured:
                return "未在 cc-switch 中配置"
            case .missingTarget:
                return "自定义模型目标失效"
            }
        }
        if routeKey.appType == "claude-desktop" {
            guard let candidate = activeCandidate(for: routeGroup) ?? candidates(for: routeGroup).first else {
                return ProviderDisplay.appTypeLabel(routeKey.appType)
            }
            return "请求模型：\(candidate.upstreamModelDisplayName) · 路由：\(routeAliasSummary(for: routeGroup))"
        }
        guard let active = activeCandidate(for: routeGroup) else {
            return ProviderDisplay.appTypeLabel(routeKey.appType)
        }
        var parts = ["上游模型：\(upstreamDisplayName(active))"]
        if routeGroup.routeKeys.count > 1 {
            parts.append("\(routeGroup.routeKeys.count) 个路由")
        }
        return parts.joined(separator: " · ")
    }

    func customModelAvailability(for routeKey: ModelRouteKey) -> CustomModelAvailability? {
        guard customModels.models.contains(where: {
            $0.appType == routeKey.appType && $0.name == routeKey.logicalModel
        }) else {
            return nil
        }
        guard !candidates(for: routeKey).isEmpty else {
            return .missingTarget
        }
        guard isConfigured(routeKey) else {
            return .unconfigured
        }
        return .configured
    }

    func isRouteOperable(_ routeGroup: ModelRouteGroup) -> Bool {
        customModelAvailability(for: routeGroup.routeKey).map { $0 == .configured } ?? true
    }

    func switchProvider(routeGroup: ModelRouteGroup, providerRef: ProviderRef) {
        onSwitchProvider?(routeGroup.routeKeys, providerRef)
    }

    func customModelBaseCandidates(preserving definition: CustomModelDefinition? = nil) -> [ModelCandidate] {
        customModels.baseCandidates(from: catalog, preserving: definition?.targets ?? [])
    }

    func customModel(for routeKey: ModelRouteKey) -> CustomModelDefinition? {
        customModels.models.first {
            $0.appType == routeKey.appType && $0.name == routeKey.logicalModel
        }
    }

    func saveCustomModel(_ definition: CustomModelDefinition, replacing existing: CustomModelDefinition? = nil) {
        var nextCustomModels = customModels
        let oldRouteKey = existing.map {
            ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
        }
        let newRouteKey = ModelRouteKey(appType: definition.appType, logicalModel: definition.name)

        if let existing,
           let index = nextCustomModels.models.firstIndex(where: { $0.id == existing.id }) {
            nextCustomModels.models[index] = definition
        } else if let index = nextCustomModels.models.firstIndex(where: { $0.id == definition.id }) {
            nextCustomModels.models[index] = definition
        } else {
            nextCustomModels.models.append(definition)
        }

        var nextPreferences = preferences
        if var visibleModels = nextPreferences.visibleModels {
            if let oldRouteKey {
                visibleModels.remove(oldRouteKey.description)
            }
            visibleModels.insert(newRouteKey.description)
            nextPreferences.visibleModels = visibleModels
        }

        if expandedRouteKeyDescription == oldRouteKey?.description {
            expandedRouteKeyDescription = nil
        }
        selectedAppType = definition.appType
        onSaveSettings?(nextPreferences, nextCustomModels)
    }

    func deleteCustomModel(_ definition: CustomModelDefinition) {
        var nextCustomModels = customModels
        nextCustomModels.models.removeAll { $0.id == definition.id }

        let routeKey = ModelRouteKey(appType: definition.appType, logicalModel: definition.name)
        var nextPreferences = preferences
        if var visibleModels = nextPreferences.visibleModels {
            visibleModels.remove(routeKey.description)
            visibleModels.remove(routeKey.logicalModel)
            nextPreferences.visibleModels = visibleModels
        }

        if expandedRouteKeyDescription == routeKey.description {
            expandedRouteKeyDescription = nil
        }
        onSaveSettings?(nextPreferences, nextCustomModels)
    }

    func reload() {
        onReload?()
    }

    func openSettings() {
        screen = .settings
        updateSettingsViewModel()
    }

    func closeSettings() {
        screen = .routes
    }

    func settingsModel() -> SettingsViewModel {
        if let settingsViewModel {
            return settingsViewModel
        }
        let settingsViewModel = SettingsViewModel(
            candidates: catalog.candidates,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            preferences: preferences,
            onApply: { [weak self] preferences, customModels in
                if let onApplySettings = self?.onApplySettings {
                    onApplySettings(preferences, customModels)
                } else {
                    self?.onSaveSettings?(preferences, customModels)
                }
            }
        )
        self.settingsViewModel = settingsViewModel
        return settingsViewModel
    }

    func openAppFolder() {
        onOpenAppFolder?()
    }

    func quit() {
        onQuit?()
    }

    func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.12)) {
            toast = message
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard toastToken == token else {
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                if toast == message {
                    toast = nil
                }
            }
        }
    }

    private func updateSettingsViewModel() {
        settingsViewModel?.update(
            candidates: catalog.candidates,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            preferences: preferences
        )
    }

    private func syncSelectedAppType() {
        guard let selectedAppType, appTypes.contains(selectedAppType) else {
            selectedAppType = appTypes.first
            return
        }
    }

    private func isConfigured(_ routeKey: ModelRouteKey) -> Bool {
        guard isUniGateScopedApp(routeKey.appType) else {
            return true
        }
        return uniGateModelScope.contains(routeKey)
    }

    private func scopedBaseCandidates() -> [ModelCandidate] {
        let customRouteKeys = Set(customModels.models.map {
            ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
        })
        return catalog.candidates.filter { candidate in
            !customRouteKeys.contains(candidate.routeKey)
                && isCandidateInUniGateScope(candidate)
        }
    }

    private func isCandidateInUniGateScope(_ candidate: ModelCandidate) -> Bool {
        guard isUniGateScopedApp(candidate.appType) else {
            return true
        }
        return uniGateModelScope.contains(candidate)
    }

    private func isUniGateScopedApp(_ appType: String) -> Bool {
        appType == "claude" || appType == "claude-desktop" || appType == "codex"
    }

    private func claudeDesktopVisibleModelKeys(candidates: [ModelCandidate]) -> [ModelRouteKey] {
        let candidateModels = Set(
            candidates
                .filter { $0.appType == "claude-desktop" }
                .map(\.upstreamModelDisplayName)
                .map(normalizedModelName)
        )
        let customModels = Set(
            customModels.models
                .filter { $0.appType == "claude-desktop" }
                .map(\.name)
                .map(normalizedModelName)
        )
        return uniGateModelScope.models(for: "claude-desktop")
            .filter { candidateModels.contains(normalizedModelName($0)) }
            .filter { !customModels.contains(normalizedModelName($0)) }
            .map { ModelRouteKey(appType: "claude-desktop", logicalModel: $0) }
    }

    private func claudeDesktopModelGroups(
        routeKeys: [ModelRouteKey],
        candidates: [ModelCandidate]
    ) -> [ModelRouteGroup] {
        var usedRouteKeys = Set<ModelRouteKey>()
        return routeKeys.compactMap { modelKey in
            let matchingRouteKeys = candidates
                .filter {
                    $0.appType == "claude-desktop"
                        && modelNameMatches($0.upstreamModelDisplayName, modelKey.logicalModel)
                }
                .map(\.routeKey)
                .uniqueRouteKeys()
                .sorted { lhs, rhs in
                    let lhsUsed = usedRouteKeys.contains(lhs)
                    let rhsUsed = usedRouteKeys.contains(rhs)
                    if lhsUsed != rhsUsed {
                        return !lhsUsed
                    }
                    return claudeRouteRoleRank(lhs) < claudeRouteRoleRank(rhs)
                }

            guard let routeKey = matchingRouteKeys.first else {
                return nil
            }
            usedRouteKeys.insert(routeKey)
            return ModelRouteGroup(routeKey: modelKey, routeKeys: [routeKey])
        }
    }

    private func isSyntheticClaudeDesktopGroup(_ routeGroup: ModelRouteGroup) -> Bool {
        routeGroup.routeKey.appType == "claude-desktop"
            && !routeGroup.routeKeys.contains(routeGroup.routeKey)
    }

    private func modelNameMatches(_ lhs: String, _ rhs: String) -> Bool {
        normalizedModelName(lhs) == normalizedModelName(rhs)
    }

    private func normalizedModelName(_ model: String) -> String {
        ModelCandidate.stripOneMSuffix(model).lowercased()
    }

    private func claudeRouteRoleRank(_ routeKey: ModelRouteKey) -> Int {
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

    private func activeProviderRef(for routeGroup: ModelRouteGroup) -> ProviderRef? {
        if let providerRef = routes.routes[routeGroup.routeKey.description]?.providerRef {
            return providerRef
        }
        return routeGroup.routeKeys.compactMap {
            routes.routes[$0.description]
        }
        .sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
        .first?.providerRef
    }

    private func routeInteractivityRank(_ routeGroup: ModelRouteGroup) -> Int {
        guard isRouteOperable(routeGroup) else {
            return 2
        }
        return candidates(for: routeGroup).count > 1 ? 0 : 1
    }

    private func upstreamDisplayName(_ candidate: ModelCandidate) -> String {
        if candidate.upstreamModelDisplayName != ModelCandidate.stripOneMSuffix(candidate.logicalModel) {
            return candidate.upstreamModelDisplayName
        }
        if let label = candidate.label, label != candidate.providerName {
            return ModelCandidate.stripOneMSuffix(label)
        }
        return candidate.upstreamModelDisplayName
    }

    private func routeAliasSummary(for routeGroup: ModelRouteGroup) -> String {
        routeGroup.routeKeys.map { routeKey in
            guard routeKey.appType == "claude-desktop" else {
                return ModelCandidate.stripOneMSuffix(routeKey.logicalModel)
            }
            let normalized = routeKey.logicalModel.lowercased()
            if normalized.contains("sonnet") {
                return "Sonnet"
            }
            if normalized.contains("opus") {
                return "Opus"
            }
            if normalized.contains("fable") {
                return "Fable"
            }
            if normalized.contains("haiku") {
                return "Haiku"
            }
            return ModelCandidate.stripOneMSuffix(routeKey.logicalModel)
        }
        .joined(separator: " / ")
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
