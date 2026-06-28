import AppKit
import Foundation
import SwiftUI
import UniGateCore

@MainActor
final class UniGateAppState: ObservableObject {
    enum Screen {
        case routes
        case modelDiscovery
        case settings
    }

    enum CustomModelAvailability {
        case configured
        case forceEnabled
        case unconfigured
        case missingTarget
    }

    @Published var screen: Screen = .routes
    @Published var catalog = ProviderCatalog(providers: [], candidates: [])
    @Published var routes = RouteState()
    @Published var preferences = AppPreferences()
    @Published var customModels = CustomModelState()
    @Published var customProviders = CustomProviderState()
    @Published var uniGateModelScope = UniGateModelScope()
    @Published var proxyStatus: ProxyStatus = .starting
    @Published var proxyPort: UInt16 = 17888
    @Published var recentEvents: [ProxyEvent] = []
    @Published var forwardedRequestCounts: [String: Int] = [:]
    @Published var integrationSnapshot: CcSwitchIntegrationSnapshot?
    @Published var requestMetrics = RequestMetricsState()
    @Published var discoveryState = ProviderModelDiscoveryState()
    @Published var networkDiagnostics: [String: NetworkPolicyDiagnostic] = [:]
    @Published var selectedAppType: String?
    @Published var expandedRouteKeyDescription: String?
    @Published var loadError: String?
    @Published var toast: String?
    @Published var isRefreshingModelDiscovery = false

    var onSwitchProvider: (([ModelRouteKey], ProviderRef) -> Void)?
    var onReload: (() -> Void)?
    var onOpenAppFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSaveSettings: ((AppPreferences, CustomModelState) -> Void)?
    var onApplySettings: ((AppPreferences, CustomModelState) -> Void)?
    var onSaveCustomProvider: ((CustomProviderDefinition, String?, CustomProviderDefinition?) -> Void)?
    var onDeleteCustomProvider: ((CustomProviderDefinition) -> Void)?
    var onRefreshModelDiscovery: ((String?) -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onExportConfiguration: (() -> Void)?
    var onImportConfiguration: (() -> Void)?
    var onResetConfiguration: (() -> Void)?
    var onSetProviderNetworkPolicy: ((ProviderRef, ProviderNetworkPolicyOverride) -> Void)?

    private var toastToken = UUID()
    private var settingsViewModel: SettingsViewModel?

    func updateSnapshot(
        catalog: ProviderCatalog,
        routes: RouteState,
        preferences: AppPreferences,
        customModels: CustomModelState,
        customProviders: CustomProviderState = CustomProviderState(),
        uniGateModelScope: UniGateModelScope,
        proxyStatus: ProxyStatus,
        proxyPort: UInt16,
        integrationSnapshot: CcSwitchIntegrationSnapshot? = nil,
        loadError: String? = nil
    ) {
        self.catalog = catalog
        self.routes = routes
        self.preferences = preferences
        self.customModels = customModels
        self.customProviders = customProviders
        self.uniGateModelScope = uniGateModelScope
        self.proxyStatus = proxyStatus
        self.proxyPort = proxyPort
        self.integrationSnapshot = integrationSnapshot
        self.loadError = loadError
        syncSelectedAppType()
        updateSettingsViewModel()
    }

    func customProviders(for appType: String? = nil) -> [CustomProviderDefinition] {
        let definitions = customProviders.definitions
        guard let appType else {
            return definitions.sorted {
                ProviderDisplay.appTypeLabel($0.appType)
                    .localizedStandardCompare(ProviderDisplay.appTypeLabel($1.appType)) == .orderedAscending
            }
        }
        return definitions.filter { $0.appType == appType }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func customProvider(for ref: ProviderRef) -> CustomProviderDefinition? {
        customProviders.definition(for: ref)
    }

    func hasCustomProviderSecret(_ definition: CustomProviderDefinition) -> Bool {
        customProviders.hasSecret(for: definition.providerRef)
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

    func updateIntegrationSnapshot(_ snapshot: CcSwitchIntegrationSnapshot?) {
        integrationSnapshot = snapshot
    }

    func updateRequestMetrics(_ metrics: RequestMetricsState) {
        requestMetrics = metrics
    }

    func updateDiscoveryState(_ state: ProviderModelDiscoveryState) {
        discoveryState = state
    }

    func updateNetworkDiagnostics(_ diagnostics: [String: NetworkPolicyDiagnostic]) {
        networkDiagnostics = diagnostics
    }

    func updateModelDiscoveryRefreshing(_ isRefreshing: Bool) {
        withAnimation(.easeInOut(duration: 0.22)) {
            isRefreshingModelDiscovery = isRefreshing
        }
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
        ModelRouteVisibility.visibleConfiguredBaseRouteKeys(
            catalog: catalog,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            preferences: preferences
        )
    }

    var displayRouteKeys: [ModelRouteKey] {
        displayRouteGroups.map(\.routeKey)
    }

    var displayRouteGroups: [ModelRouteGroup] {
        let candidates = scopedBaseCandidates()
        let routeKeys = visibleRouteKeys
        let visibleGroups = ModelRouteGrouping.groups(
            routeKeys: routeKeys,
            candidates: candidates
        )
        let customGroups = customModels.models.map {
            let routeKey = ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
            return ModelRouteGroup(routeKey: routeKey, routeKeys: [routeKey])
        }
        return visibleGroups + customGroups
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
        guard let definition = customModel(for: routeKey) else {
            let candidates = catalog.candidates(for: routeKey)
            return candidates.filter(isCandidateInUniGateScope)
        }
        return customModels.displayCandidates(for: definition, from: catalog)
    }

    func candidates(for routeGroup: ModelRouteGroup) -> [ModelCandidate] {
        let candidates = routeGroup.routeKeys.flatMap { self.candidates(for: $0) }
        let isCustomModel = customModel(for: routeGroup.routeKey) != nil
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
        activeCandidate(for: routeGroup)?.id == candidate.id
    }

    func isUnavailableCandidate(_ candidate: ModelCandidate, for routeGroup: ModelRouteGroup) -> Bool {
        if candidate.isDiscoveryStale(in: catalog) {
            return true
        }
        guard customModelAvailability(for: routeGroup.routeKey) == .missingTarget else {
            return false
        }
        guard let definition = customModel(for: routeGroup.routeKey),
              let selectedTarget = definition.selectedTarget else {
            return false
        }
        return candidate.providerRef == selectedTarget.providerRef
            && candidate.routeKey == selectedTarget.routeKey
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

    func modelTitleText(for routeGroup: ModelRouteGroup) -> String {
        let routeKey = routeGroup.routeKey
        guard customModelAvailability(for: routeKey) == nil else {
            return routeKey.logicalModel
        }
        return ModelCandidate.stripOneMSuffix(routeKey.logicalModel)
    }

    func modelDetailText(for routeGroup: ModelRouteGroup) -> String {
        let routeKey = routeGroup.routeKey
        if let availability = customModelAvailability(for: routeKey) {
            switch availability {
            case .configured:
                break
            case .forceEnabled:
                break
            case .unconfigured:
                return "未在 cc-switch 中配置"
            case .missingTarget:
                return "自定义模型目标失效"
            }
        }
        if routeStatusText(for: routeGroup) == "目标失效" {
            return "当前路由目标失效"
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
        guard let definition = customModel(for: routeKey) else {
            return nil
        }
        guard definition.hasSelectedTarget(in: catalog) else {
            return .missingTarget
        }
        guard isConfigured(routeKey) else {
            return definition.forceEnabled ? .forceEnabled : .unconfigured
        }
        return .configured
    }

    func isRouteOperable(_ routeGroup: ModelRouteGroup) -> Bool {
        switch customModelAvailability(for: routeGroup.routeKey) {
        case .none, .configured, .forceEnabled:
            return true
        case .missingTarget:
            return candidates(for: routeGroup).count > 1
        case .unconfigured:
            return false
        }
    }

    func routeStatusText(for routeGroup: ModelRouteGroup) -> String? {
        if let availability = customModelAvailability(for: routeGroup.routeKey) {
            switch availability {
            case .unconfigured:
                return "未配置"
            case .missingTarget:
                return "目标失效"
            case .configured, .forceEnabled:
                break
            }
        }

        if let active = activeCandidate(for: routeGroup), active.isDiscoveryStale(in: catalog) {
            return "目标失效"
        }

        guard routes.routes[routeGroup.routeKey.description] != nil else {
            return nil
        }
        return activeCandidate(for: routeGroup) == nil ? "目标失效" : nil
    }

    func switchProvider(routeGroup: ModelRouteGroup, providerRef: ProviderRef) {
        onSwitchProvider?(routeGroup.routeKeys, providerRef)
    }

    func customModelBaseCandidates(preserving definition: CustomModelDefinition? = nil) -> [ModelCandidate] {
        customModels.baseCandidates(
            from: catalog,
            preserving: definition?.targets ?? [],
            preservingRouteKeys: definition.map {
                [ModelRouteKey(appType: $0.appType, logicalModel: $0.name)]
            } ?? []
        )
    }

    func customModel(for routeKey: ModelRouteKey) -> CustomModelDefinition? {
        customModels.models.first {
            $0.appType == routeKey.appType && $0.name == routeKey.logicalModel
        }
    }

    func saveCustomModel(_ definition: CustomModelDefinition, replacing existing: CustomModelDefinition? = nil) {
        var nextCustomModels = customModels
        var savedDefinition = definition
        if let existing {
            savedDefinition.appType = existing.appType
        }
        let oldRouteKey = existing.map {
            ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
        }
        let newRouteKey = ModelRouteKey(appType: savedDefinition.appType, logicalModel: savedDefinition.name)

        if let existing,
           let index = nextCustomModels.models.firstIndex(where: { $0.id == existing.id }) {
            nextCustomModels.models[index] = savedDefinition
        } else if let index = nextCustomModels.models.firstIndex(where: { $0.id == savedDefinition.id }) {
            nextCustomModels.models[index] = savedDefinition
        } else {
            nextCustomModels.models.append(savedDefinition)
        }
        nextCustomModels = nextCustomModels.normalized()

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
        selectedAppType = savedDefinition.appType
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

    func saveCustomProvider(
        _ definition: CustomProviderDefinition,
        secret: String?,
        replacing existing: CustomProviderDefinition? = nil
    ) {
        onSaveCustomProvider?(definition, secret, existing)
    }

    func deleteCustomProvider(_ definition: CustomProviderDefinition) {
        onDeleteCustomProvider?(definition)
    }

    func reload() {
        onReload?()
    }

    func openModelDiscovery() {
        screen = .modelDiscovery
        expandedRouteKeyDescription = nil
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
            providers: catalog.providers,
            customModels: customModels,
            customProviders: customProviders,
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

    func refreshModelDiscovery() {
        onRefreshModelDiscovery?(currentAppType)
    }

    func copyDiagnostics() {
        onCopyDiagnostics?()
    }

    func exportConfiguration() {
        onExportConfiguration?()
    }

    func importConfiguration() {
        onImportConfiguration?()
    }

    func resetConfiguration() {
        onResetConfiguration?()
    }

    func setProviderNetworkPolicy(providerRef: ProviderRef, override: ProviderNetworkPolicyOverride) {
        onSetProviderNetworkPolicy?(providerRef, override)
    }

    func quit() {
        onQuit?()
    }

    var healthReport: ConfigurationHealthReport {
        ConfigurationHealthReport.build(
            databasePath: preferences.resolvedCcSwitchDBPath,
            databaseExists: FileManager.default.fileExists(atPath: preferences.resolvedCcSwitchDBPath),
            catalogLoadError: loadError,
            proxySeverity: proxyStatus.healthSeverity,
            proxyDetail: proxyStatus.healthDetail(port: proxyPort),
            catalog: catalog,
            routes: routes,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            integration: integrationSnapshot
        )
    }

    var diagnosticsText: String {
        DiagnosticsReportGenerator.text(DiagnosticsReportInput(
            databasePath: preferences.resolvedCcSwitchDBPath,
            proxyStatus: proxyStatus.healthDetail(port: proxyPort),
            proxyPort: proxyPort,
            catalog: catalog,
            routes: routes,
            preferences: preferences,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            integration: integrationSnapshot,
            healthReport: healthReport,
            recentEvents: recentEvents.map { DiagnosticEvent(date: $0.date, level: $0.level.rawValue, message: $0.message) },
            requestMetrics: requestMetrics,
            discoveryState: discoveryState,
            networkDiagnostics: networkDiagnostics.values.sorted {
                $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending
            }
        ))
    }

    var currentRequestMetrics: [(RequestMetricKey, RequestMetricRecord)] {
        guard let appType = currentAppType else {
            return requestMetrics.records.sorted { $0.key.description.localizedStandardCompare($1.key.description) == .orderedAscending }
        }
        return requestMetrics.records(appType: appType)
    }

    var currentModelDiscoveryItems: [ModelDiscoveryProviderItem] {
        let providers = catalog.providers
            .filter { currentAppType == nil || $0.appType == currentAppType }
            .sorted {
                let appCompare = ProviderDisplay.appTypeLabel($0.appType)
                    .localizedStandardCompare(ProviderDisplay.appTypeLabel($1.appType))
                if appCompare != .orderedSame {
                    return appCompare == .orderedAscending
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        let results = discoveryState.results
        return providers.map { provider in
            ModelDiscoveryProviderItem(
                provider: provider,
                result: results[provider.ref.description]
            )
        }
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
            providers: catalog.providers,
            customModels: customModels,
            customProviders: customProviders,
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
        guard ModelRouteVisibility.isUniGateScopedApp(routeKey.appType) else {
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
        ModelRouteVisibility.isCandidateSelectable(candidate, uniGateModelScope: uniGateModelScope)
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
        return candidate.upstreamModelDisplayName
    }

}

struct ModelDiscoveryProviderItem: Identifiable {
    let provider: ImportedProvider
    let result: ProviderModelDiscoveryResult?

    var id: String {
        provider.ref.description
    }
}

private extension ProxyStatus {
    var healthSeverity: ConfigurationHealthSeverity {
        switch self {
        case .starting:
            return .error
        case .running:
            return .ok
        case .providerIssue:
            return .warning
        case .failed:
            return .error
        }
    }

    func healthDetail(port: UInt16) -> String {
        title(port: port)
    }
}
