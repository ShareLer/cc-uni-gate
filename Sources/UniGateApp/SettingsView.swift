import AppKit
import SwiftUI
import UniGateCore

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var candidates: [ModelCandidate]
    @Published var providers: [ImportedProvider]
    @Published var customModels: CustomModelState
    @Published var preferences: AppPreferences
    @Published var portText: String
    @Published var ccSwitchDBPathText: String
    @Published var brandColor: BrandColorPreset
    @Published var bubbleNotificationsEnabled: Bool
    @Published var launchAtLoginEnabled: Bool
    @Published var networkGlobalMode: NetworkPolicyMode
    @Published var providerNetworkOverrides: [String: ProviderNetworkPolicyOverride]
    @Published var directDomainRulesText: String
    @Published var toast: String?

    private var uniGateModelScope: UniGateModelScope
    private let onApply: (AppPreferences, CustomModelState) -> Void
    private var toastToken = UUID()

    init(
        candidates: [ModelCandidate],
        providers: [ImportedProvider],
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        preferences: AppPreferences,
        onApply: @escaping (AppPreferences, CustomModelState) -> Void
    ) {
        self.candidates = candidates
        self.providers = providers
        self.customModels = customModels
        self.uniGateModelScope = uniGateModelScope
        self.preferences = preferences
        self.portText = "\(preferences.normalizedPort)"
        self.ccSwitchDBPathText = preferences.resolvedCcSwitchDBPath
        self.brandColor = preferences.brandColor
        self.bubbleNotificationsEnabled = preferences.bubbleNotificationsEnabled
        self.launchAtLoginEnabled = preferences.launchAtLoginEnabled
        self.networkGlobalMode = preferences.networkPolicy.globalMode
        self.providerNetworkOverrides = preferences.networkPolicy.providerOverrides
        self.directDomainRulesText = preferences.networkPolicy.directDomainRules.joined(separator: "\n")
        self.onApply = onApply
    }

    func update(
        candidates: [ModelCandidate],
        providers: [ImportedProvider],
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        preferences: AppPreferences
    ) {
        self.candidates = candidates
        self.providers = providers
        self.customModels = customModels
        self.uniGateModelScope = uniGateModelScope
        self.preferences = preferences
        self.portText = "\(preferences.normalizedPort)"
        self.ccSwitchDBPathText = preferences.resolvedCcSwitchDBPath
        self.brandColor = preferences.brandColor
        self.bubbleNotificationsEnabled = preferences.bubbleNotificationsEnabled
        self.launchAtLoginEnabled = preferences.launchAtLoginEnabled
        self.networkGlobalMode = preferences.networkPolicy.globalMode
        self.providerNetworkOverrides = preferences.networkPolicy.providerOverrides
        self.directDomainRulesText = preferences.networkPolicy.directDomainRules.joined(separator: "\n")
    }

    var generalSettingsValidationText: String? {
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmedPort), port > 0 else {
            return "端口必须是 1-65535"
        }
        return nil
    }

    func applyGeneralSettings(commitDatabasePath: Bool = true) -> Bool {
        guard let nextPreferences = currentPreferences(
            brandColor: brandColor,
            commitDatabasePath: commitDatabasePath
        ) else {
            return false
        }
        guard hasGeneralSettingsChange(nextPreferences) else {
            return true
        }
        onApply(nextPreferences, customModels)
        return true
    }

    func applyBrandColor(_ preset: BrandColorPreset) {
        guard let nextPreferences = currentPreferences(
            brandColor: preset,
            commitDatabasePath: false
        ) else {
            NSSound.beep()
            return
        }
        brandColor = preset
        guard hasGeneralSettingsChange(nextPreferences) else {
            return
        }
        onApply(nextPreferences, customModels)
    }

    func providerNetworkMode(for provider: ImportedProvider) -> NetworkPolicyMode {
        providerNetworkOverrides[provider.ref.description]?.effectiveMode
            ?? effectiveNetworkPolicy(for: provider)
    }

    func setProviderNetworkMode(_ mode: NetworkPolicyMode, for providerRef: ProviderRef) {
        providerNetworkOverrides[providerRef.description] = providerOverride(for: mode)
        _ = applyGeneralSettings(commitDatabasePath: false)
    }

    func setNetworkGlobalModeForAll(_ mode: NetworkPolicyMode) {
        networkGlobalMode = mode
        providerNetworkOverrides = Dictionary(
            uniqueKeysWithValues: providers.map {
                ($0.ref.description, providerOverride(for: mode))
            }
        )
        _ = applyGeneralSettings(commitDatabasePath: false)
    }

    func effectiveNetworkPolicy(for provider: ImportedProvider) -> NetworkPolicyMode {
        NetworkPolicyResolver.effectiveMode(
            preferences: currentNetworkPolicyPreferences(),
            providerRef: provider.ref,
            host: provider.baseURL.flatMap { URL(string: $0)?.host }
        )
    }

    var sortedProviders: [ImportedProvider] {
        providers.sorted { lhs, rhs in
            let appCompare = ProviderDisplay.appTypeLabel(lhs.appType)
                .localizedStandardCompare(ProviderDisplay.appTypeLabel(rhs.appType))
            if appCompare != .orderedSame {
                return appCompare == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func copyBaseURL(path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseURL(path: path), forType: .string)
        showToast("已复制")
    }

    func importToCcSwitch(path: String) {
        guard let app = ccSwitchApp(for: path) else {
            NSSound.beep()
            showToast("不支持导入")
            return
        }
        guard let url = CcSwitchDeepLink.providerImportURL(
            app: app,
            endpoint: baseURL(path: path),
            model: defaultModel(forAppType: app),
            homepage: baseURL(path: "")
        ) else {
            NSSound.beep()
            return
        }
        if NSWorkspace.shared.open(url) {
            showToast("已打开 cc-switch")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            showToast("已复制导入链接")
        }
    }

    func baseURL(path: String) -> String {
        let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 17888
        return "http://127.0.0.1:\(port)\(path)"
    }

    private func currentPreferences(
        brandColor: BrandColorPreset,
        commitDatabasePath: Bool
    ) -> AppPreferences? {
        guard generalSettingsValidationText == nil,
              let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0
        else {
            return nil
        }
        return AppPreferences(
            visibleModels: preferences.visibleModels,
            protocolOverrides: preferences.protocolOverrides,
            port: port,
            ccSwitchDBPath: commitDatabasePath
                ? ccSwitchDBPathPreferenceValue()
                : preferences.ccSwitchDBPath,
            brandColor: brandColor,
            bubbleNotificationsEnabled: bubbleNotificationsEnabled,
            launchAtLoginEnabled: launchAtLoginEnabled,
            networkPolicy: currentNetworkPolicyPreferences()
        )
    }

    private func currentNetworkPolicyPreferences() -> NetworkPolicyPreferences {
        NetworkPolicyPreferences(
            globalMode: networkGlobalMode,
            providerOverrides: providerNetworkOverrides,
            directDomainRules: NetworkPolicyPreferences.parseDomainRulesText(directDomainRulesText)
        )
    }

    private func providerOverride(for mode: NetworkPolicyMode) -> ProviderNetworkPolicyOverride {
        switch mode {
        case .system:
            return .system
        case .direct:
            return .direct
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.12)) {
            toast = message
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
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

    private func hasGeneralSettingsChange(_ nextPreferences: AppPreferences) -> Bool {
        preferences.normalizedPort != nextPreferences.normalizedPort
            || normalizedPath(preferences.ccSwitchDBPath) != normalizedPath(nextPreferences.ccSwitchDBPath)
            || preferences.brandColor != nextPreferences.brandColor
            || preferences.bubbleNotificationsEnabled != nextPreferences.bubbleNotificationsEnabled
            || preferences.launchAtLoginEnabled != nextPreferences.launchAtLoginEnabled
            || preferences.networkPolicy != nextPreferences.networkPolicy
    }

    private func normalizedPath(_ path: String?) -> String {
        (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ccSwitchDBPathPreferenceValue() -> String? {
        let path = ccSwitchDBPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != AppPreferences.defaultCcSwitchDBPath() else {
            return nil
        }
        return path
    }

    private func defaultModel(forAppType appType: String) -> String? {
        let appKeys = modelRouteKeys().filter { $0.appType == appType }
        let visibleKeys = visibleRouteKeys().filter { $0.appType == appType }
        return preferredDefaultModel(from: visibleKeys) ?? preferredDefaultModel(from: appKeys)
    }

    private func preferredDefaultModel(from keys: [ModelRouteKey]) -> String? {
        if let exact = keys.first(where: { $0.logicalModel == "gpt-5.5" || $0.logicalModel == "auto" }) {
            return exact.logicalModel
        }
        return keys.first?.logicalModel
    }

    private func ccSwitchApp(for path: String) -> String? {
        switch path {
        case "/codex":
            return "codex"
        case "/claude-code":
            return "claude"
        default:
            return nil
        }
    }

    private func baseModelCandidates() -> [ModelCandidate] {
        candidates.filter { candidate in
            candidate.providerRef == candidate.upstreamProviderRef
                &&
            !customModels.models.contains {
                $0.appType == candidate.appType && $0.name == candidate.logicalModel
            }
        }
    }

    private func modelRouteKeys() -> [ModelRouteKey] {
        let candidates = scopedBaseModelCandidates()
        let baseRouteKeys = candidates
            .filter { $0.appType != "claude-desktop" }
            .map(\.routeKey)
        let desktopRouteKeys = ModelRouteVisibility.claudeDesktopVisibleModelKeys(
            candidates: candidates,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope
        )
        return Self.modelRouteKeys(routeKeys: baseRouteKeys, customModels: customModels)
            + desktopRouteKeys
    }

    private func visibleRouteKeys() -> [ModelRouteKey] {
        let keys = modelRouteKeys()
        let selectableKeys = keys.filter {
            ModelRouteVisibility.isModelSelectable($0, customModels: customModels, uniGateModelScope: uniGateModelScope)
        }
        guard preferences.visibleModels != nil else {
            return selectableKeys
        }
        let visibleSet = Set(preferences.visibleRouteKeyList(allRouteKeys: keys))
        return selectableKeys.filter { visibleSet.contains($0) }
    }

    private func scopedBaseModelCandidates() -> [ModelCandidate] {
        baseModelCandidates().filter {
            ModelRouteVisibility.isCandidateSelectable($0, uniGateModelScope: uniGateModelScope)
        }
    }

    private static func modelRouteKeys(
        routeKeys: [ModelRouteKey],
        customModels: CustomModelState
    ) -> [ModelRouteKey] {
        Array(Set(routeKeys).union(customModels.models.map {
            ModelRouteKey(appType: $0.appType, logicalModel: $0.name)
        })).sorted { lhs, rhs in
            let appCompare = ProviderDisplay.appTypeLabel(lhs.appType)
                .localizedStandardCompare(ProviderDisplay.appTypeLabel(rhs.appType))
            if appCompare != .orderedSame {
                return appCompare == .orderedAscending
            }
            return lhs.logicalModel.localizedStandardCompare(rhs.logicalModel) == .orderedAscending
        }
    }

}
