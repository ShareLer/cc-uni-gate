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

    var onSwitchProvider: ((ModelRouteKey, ProviderRef) -> Void)?
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
        settingsViewModel?.proxyStatus = status
    }

    func updateRecentEvents(_ events: [ProxyEvent]) {
        recentEvents = events
    }

    func updateForwardedRequestCounts(_ counts: [String: Int]) {
        forwardedRequestCounts = counts
    }

    func routeKeysForCurrentApp() -> [ModelRouteKey] {
        let appType = currentAppType
        let keys = displayRouteKeys.filter { appType == nil || $0.appType == appType }
        return keys
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
        let routeAppTypes = Array(Set(displayRouteKeys.map(\.appType))).sorted {
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
        let customRouteKeys = Set(customModels.models.map {
            ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
        })
        let configuredRouteKeys = catalog.routeKeys.filter { key in
            guard !customRouteKeys.contains(key) else {
                return false
            }
            guard key.appType == "claude" || key.appType == "codex" else {
                return true
            }
            return uniGateModelScope.contains(key)
        }
        return preferences.visibleRouteKeyList(allRouteKeys: configuredRouteKeys)
    }

    var displayRouteKeys: [ModelRouteKey] {
        let visible = visibleRouteKeys
        let customKeys = customModels.models
            .map { ModelRouteKey(appType: $0.appType, logicalModel: $0.name) }
        return visible + customKeys
    }

    var modelCountText: String {
        guard let appType = currentAppType else {
            return "\(displayRouteKeys.count) 个模型"
        }
        let appKeys = displayRouteKeys.filter { $0.appType == appType }
        return "\(appKeys.count) 个模型"
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
        catalog.candidates(for: routeKey)
    }

    func activeCandidate(for routeKey: ModelRouteKey) -> ModelCandidate? {
        guard let providerRef = routes.routes[routeKey.description]?.providerRef else {
            return nil
        }
        return candidates(for: routeKey).first { $0.providerRef == providerRef }
    }

    func isActive(_ candidate: ModelCandidate, for routeKey: ModelRouteKey) -> Bool {
        routes.routes[routeKey.description]?.providerRef == candidate.providerRef
    }

    func isExpanded(_ routeKey: ModelRouteKey) -> Bool {
        expandedRouteKeyDescription == routeKey.description
    }

    func toggleExpanded(_ routeKey: ModelRouteKey) {
        if isExpanded(routeKey) {
            expandedRouteKeyDescription = nil
        } else {
            expandedRouteKeyDescription = routeKey.description
        }
    }

    func providerTitle(_ candidate: ModelCandidate) -> String {
        var parts = [candidate.providerName]
        let displayUpstreamModel = stripOneMSuffix(candidate.upstreamModel)
        let displayLogicalModel = stripOneMSuffix(candidate.logicalModel)
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

    func modelDetailText(for routeKey: ModelRouteKey) -> String {
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
        guard let active = activeCandidate(for: routeKey) else {
            return ProviderDisplay.appTypeLabel(routeKey.appType)
        }
        let upstream = upstreamDisplayName(active)
        return "上游模型：\(upstream)"
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

    func isRouteOperable(_ routeKey: ModelRouteKey) -> Bool {
        customModelAvailability(for: routeKey).map { $0 == .configured } ?? true
    }

    func switchProvider(routeKey: ModelRouteKey, providerRef: ProviderRef) {
        onSwitchProvider?(routeKey, providerRef)
    }

    func customModelBaseCandidates() -> [ModelCandidate] {
        catalog.candidates.filter { candidate in
            candidate.providerRef == candidate.upstreamProviderRef
                &&
            !customModels.models.contains {
                $0.appType == candidate.appType && $0.name == candidate.logicalModel
            }
        }
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
            providers: catalog.providers,
            candidates: catalog.candidates,
            routeKeys: catalog.routeKeys,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            proxyStatus: proxyStatus,
            preferences: preferences,
            onSave: { [weak self] preferences, customModels in
                self?.onSaveSettings?(preferences, customModels)
            },
            onApply: { [weak self] preferences, customModels in
                if let onApplySettings = self?.onApplySettings {
                    onApplySettings(preferences, customModels)
                } else {
                    self?.onSaveSettings?(preferences, customModels)
                }
            }
        )
        settingsViewModel.onClose = { [weak self] in
            self?.closeSettings()
        }
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
            providers: catalog.providers,
            candidates: catalog.candidates,
            routeKeys: catalog.routeKeys,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            proxyStatus: proxyStatus,
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
        guard routeKey.appType == "claude" || routeKey.appType == "codex" else {
            return true
        }
        return uniGateModelScope.contains(routeKey)
    }

    private func routeInteractivityRank(_ routeKey: ModelRouteKey) -> Int {
        guard isRouteOperable(routeKey) else {
            return 2
        }
        return candidates(for: routeKey).count > 1 ? 0 : 1
    }

    private func upstreamDisplayName(_ candidate: ModelCandidate) -> String {
        if candidate.upstreamModel != candidate.logicalModel {
            return candidate.upstreamModel
        }
        if let label = candidate.label, label != candidate.providerName {
            return label
        }
        return candidate.upstreamModel
    }

    private func stripOneMSuffix(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"\[\s*1m\s*\]\s*$"#, options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
