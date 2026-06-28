import UniGateCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let proxyHost = "127.0.0.1"
    private let appState = UniGateAppState()
    private let statusItemController = StatusItemController()
    private var catalog: ProviderCatalog = ProviderCatalog(providers: [], candidates: [])
    private var integrationSnapshot: CcSwitchIntegrationSnapshot?
    private var uniGateModelScope = UniGateModelScope()
    private var routes = RouteState()
    private var preferences = AppPreferences()
    private var customModels = CustomModelState()
    private var requestMetrics = RequestMetricsState()
    private var discoveryState = ProviderModelDiscoveryState()
    private var networkDiagnostics: [String: NetworkPolicyDiagnostic] = [:]
    private lazy var routeStore = RouteStore(fileURL: defaultRouteStoreURL())
    private lazy var preferencesStore = PreferencesStore(fileURL: defaultPreferencesStoreURL())
    private lazy var customModelStore = CustomModelStore()
    private lazy var discoveryStore = ProviderModelDiscoveryStore()
    private let backupStore = ConfigurationBackupStore()
    private var proxyServer: LocalProxyServer?
    private var proxyStatus: ProxyStatus = .starting
    private var catalogLoadError: String?
    private var recentEvents: [ProxyEvent] = []
    private var forwardedRequestCounts: [String: Int] = [:]
    private var currentProxyServerID: UUID?
    private var healthCheckTask: Task<Void, Never>?
    private var automaticModelDiscoveryTask: Task<Void, Never>?
    private var userModelDiscoveryTask: Task<Void, Never>?
    private var providerIssueClearTask: Task<Void, Never>?
    private let dbWatcher = CcSwitchDatabaseWatcher()
    private var ccSwitchConfigurationFingerprint: CcSwitchConfigurationFingerprint?
    private let logger = FileLogger()

    private struct ImportedConfigurationSnapshot: Sendable {
        let catalog: ProviderCatalog
        let uniGateModelScope: UniGateModelScope
        let integrationSnapshot: CcSwitchIntegrationSnapshot
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureAppStateActions()
        statusItemController.install(state: appState)
        publishState()
        reloadCatalog()
        startProxyServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthCheckTask?.cancel()
        automaticModelDiscoveryTask?.cancel()
        userModelDiscoveryTask?.cancel()
        providerIssueClearTask?.cancel()
        dbWatcher.stop()
        currentProxyServerID = nil
        proxyServer?.stop()
        NetworkPolicySession.invalidateSharedSessions()
    }

    private func reloadCatalog(recordEventMessage: String? = nil) {
        do {
            preferences = try preferencesStore.load()
            customModels = try customModelStore.load()
            discoveryState = try discoveryStore.load()
            let importedSnapshot = try loadImportedConfigurationSnapshot()
            ccSwitchConfigurationFingerprint = try currentImporter().loadConfigurationFingerprint()
            pruneDiscoveryState(for: importedSnapshot.catalog)
            applyImportedConfigurationSnapshot(importedSnapshot)
            routes = try routeStore.load(catalog: proxyCatalog())
            catalogLoadError = nil
            if let recordEventMessage {
                recordEvent(.info, recordEventMessage)
            }
            syncLaunchAtLoginPreference()
            publishState()
            scheduleAutomaticModelDiscoveryRefresh()
        } catch {
            if let recordEventMessage {
                recordEvent(.error, formattedIssueMessage(
                    appName: "Uni Gate",
                    group: "配置异常",
                    detail: "\(recordEventMessage)失败：\(error.localizedDescription)"
                ))
            }
            publishError(error, notify: recordEventMessage == nil)
        }
        syncCcSwitchDBWatcher()
    }

    private func startProxyServer() {
        do {
            healthCheckTask?.cancel()
            providerIssueClearTask?.cancel()
            currentProxyServerID = nil
            proxyServer?.stop()
            updateProxyStatus(.starting, eventLevel: .info, eventMessage: "代理启动中 \(managerBaseURL())")
            let server = LocalProxyServer(port: currentProxyPort(), runtime: self)
            currentProxyServerID = server.id
            try server.start()
            proxyServer = server
            startHealthMonitoring()
        } catch {
            currentProxyServerID = nil
            updateProxyStatus(
                .failed(error.localizedDescription),
                eventLevel: .error,
                eventMessage: formattedIssueMessage(
                    appName: "Uni Gate",
                    group: "代理异常",
                    detail: "代理启动失败：\(error.localizedDescription)"
                )
            )
        }
    }

    private func switchProvider(routeKeys: [ModelRouteKey], providerRef: ProviderRef) {
        do {
            routes = try routeStore.switchRoutes(
                routes,
                catalog: proxyCatalog(),
                routeKeys: routeKeys,
                providerRef: providerRef
            )
            publishState()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func reloadAction() {
        reloadCatalog()
    }

    private func reloadFromCcSwitchDBChange() {
        do {
            let nextFingerprint = try currentImporter().loadConfigurationFingerprint()
            guard nextFingerprint != ccSwitchConfigurationFingerprint else {
                dbWatcher.refreshBaseline(dbPath: defaultCcSwitchDBPath())
                return
            }
            ccSwitchConfigurationFingerprint = nextFingerprint
            reloadCatalog(recordEventMessage: "检测到 cc-switch 配置变化，已自动重新加载")
        } catch {
            reloadCatalog(recordEventMessage: "检测到 cc-switch DB 变化，已自动重新加载")
        }
    }

    private func saveSettings(_ preferences: AppPreferences, customModels: CustomModelState) {
        persistSettings(preferences, customModels: customModels, closeAfterSave: true)
    }

    private func applySettings(_ preferences: AppPreferences, customModels: CustomModelState) {
        persistSettings(preferences, customModels: customModels, closeAfterSave: false)
    }

    private func persistSettings(
        _ preferences: AppPreferences,
        customModels: CustomModelState,
        closeAfterSave: Bool
    ) {
        do {
            let previousPort = currentProxyPort()
            self.preferences = preferences
            self.customModels = customModels
            pruneNetworkDiagnostics(for: preferences.networkPolicy)
            try preferencesStore.save(preferences)
            try customModelStore.save(customModels)
            syncLaunchAtLoginPreference()
            reloadCatalog()
            if currentProxyPort() != previousPort {
                startProxyServer()
            }
            if closeAfterSave {
                appState.closeSettings()
                appState.showToast("已保存")
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func setProviderNetworkPolicy(
        providerRef: ProviderRef,
        override: ProviderNetworkPolicyOverride
    ) {
        var nextPreferences = preferences
        var overrides = nextPreferences.networkPolicy.providerOverrides
        if override == .inherit {
            overrides.removeValue(forKey: providerRef.description)
        } else {
            overrides[providerRef.description] = override
        }
        nextPreferences.networkPolicy.providerOverrides = overrides
        if let mode = override.effectiveMode,
           networkDiagnostics[providerRef.description]?.fallbackMode == mode {
            clearNetworkDiagnostic(providerRef: providerRef)
        }
        persistSettings(nextPreferences, customModels: customModels, closeAfterSave: false)
        appState.showToast(override == .direct ? "已设为直连" : "网络策略已更新")
    }

    private func pruneNetworkDiagnostics(for networkPolicy: NetworkPolicyPreferences) {
        let providersByRef = Dictionary(uniqueKeysWithValues: catalog.providers.map { ($0.ref, $0) })
        let nextDiagnostics = networkDiagnostics.filter { _, diagnostic in
            let provider = providersByRef[diagnostic.providerRef]
            let host = provider?.baseURL.flatMap { URL(string: $0)?.host }
                ?? URL(string: diagnostic.url)?.host
            return NetworkPolicyResolver.effectiveMode(
                preferences: networkPolicy,
                providerRef: diagnostic.providerRef,
                host: host
            ) == diagnostic.failedMode
        }
        guard nextDiagnostics != networkDiagnostics else {
            return
        }
        networkDiagnostics = nextDiagnostics
        appState.updateNetworkDiagnostics(networkDiagnostics)
    }

    private func openAppFolder() {
        try? FileManager.default.createDirectory(
            at: AppPaths.logsDirectory(),
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(AppPaths.applicationSupportDirectory())
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appState.diagnosticsText, forType: .string)
        appState.showToast("诊断信息已复制")
    }

    private func exportConfiguration() {
        prepareForSystemModal {
            self.performExportConfiguration()
        }
    }

    private func performExportConfiguration() {
        let panel = NSSavePanel()
        panel.title = "导出 Uni Gate 配置"
        panel.nameFieldStringValue = ConfigurationBackupStore.defaultExportURL().lastPathComponent
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let backup = UniGateConfigurationBackup(
                preferences: preferences,
                routes: routes,
                customModels: customModels
            )
            try backupStore.save(backup, to: url)
            appState.showToast("配置已导出")
        } catch {
            showError("配置导出失败：\(error.localizedDescription)")
        }
    }

    private func importConfiguration() {
        prepareForSystemModal {
            self.performImportConfiguration()
        }
    }

    private func performImportConfiguration() {
        let previousPort = currentProxyPort()
        let panel = NSOpenPanel()
        panel.title = "恢复 Uni Gate 配置"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        guard confirmDestructiveAction(
            title: "恢复配置？",
            message: "这会覆盖 Uni Gate 当前的本地设置、模型路由和自定义模型。cc-switch 数据库不会被修改。"
        ) else {
            return
        }

        do {
            let backup = try backupStore.load(from: url)
            preferences = backup.preferences
            routes = backup.routes
            customModels = backup.customModels
            networkDiagnostics.removeAll()
            try preferencesStore.save(preferences)
            try customModelStore.save(customModels)
            try routeStore.save(routes)
            syncLaunchAtLoginPreference()
            reloadCatalog(recordEventMessage: "已恢复 Uni Gate 配置")
            if currentProxyPort() != previousPort {
                startProxyServer()
            }
            appState.showToast("配置已恢复")
        } catch {
            showError("配置恢复失败：\(error.localizedDescription)")
        }
    }

    private func resetConfiguration() {
        prepareForSystemModal {
            self.performResetConfiguration()
        }
    }

    private func performResetConfiguration() {
        guard confirmDestructiveAction(
            title: "重置 Uni Gate 配置？",
            message: "这会清空本地偏好、自定义模型和路由选择，并重新从 cc-switch 生成默认路由。"
        ) else {
            return
        }

        do {
            preferences = AppPreferences()
            customModels = CustomModelState()
            networkDiagnostics.removeAll()
            try preferencesStore.save(preferences)
            try customModelStore.save(customModels)
            catalog = try loadExpandedCatalog()
            uniGateModelScope = try currentImporter().loadUniGateModelScope()
            integrationSnapshot = try currentImporter().loadIntegrationSnapshot()
            routes = RouteStore.defaultState(candidates: proxyCatalog().candidates)
            try routeStore.save(routes)
            syncLaunchAtLoginPreference()
            publishState()
            startProxyServer()
            appState.showToast("配置已重置")
        } catch {
            showError("配置重置失败：\(error.localizedDescription)")
        }
    }

    private func prepareForSystemModal(_ action: @escaping @MainActor () -> Void) {
        statusItemController.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private func confirmDestructiveAction(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func syncLaunchAtLoginPreference() {
        guard let message = LaunchAtLoginController.sync(enabled: preferences.launchAtLoginEnabled) else {
            return
        }
        recordEvent(.error, formattedIssueMessage(
            appName: "Uni Gate",
            group: "启动项异常",
            detail: message
        ))
    }

    private func refreshModelDiscovery(appType: String?) {
        automaticModelDiscoveryTask?.cancel()
        guard userModelDiscoveryTask == nil, !appState.isRefreshingModelDiscovery else {
            return
        }
        do {
            let importedSnapshot = try loadImportedConfigurationSnapshot()
            let providers = importedSnapshot.catalog.providers.filter { provider in
                appType == nil || provider.appType == appType
            }
            guard !providers.isEmpty else {
                appState.showToast("没有可探测的供应商")
                return
            }

            appState.updateModelDiscoveryRefreshing(true)
            userModelDiscoveryTask = Task { [importedSnapshot, providers] in
                defer {
                    appState.updateModelDiscoveryRefreshing(false)
                    userModelDiscoveryTask = nil
                }
                var nextState = discoveryState.pruning(validProviders: importedSnapshot.catalog.providers)
                for provider in providers {
                    let result = await discoverModels(for: provider)
                    guard !Task.isCancelled else {
                        return
                    }
                    nextState.upsert(result)
                    discoveryState = nextState
                    appState.updateDiscoveryState(nextState)
                }
                do {
                    guard !Task.isCancelled else {
                        return
                    }
                    nextState = nextState.pruning(validProviders: importedSnapshot.catalog.providers)
                    discoveryState = nextState
                    appState.updateDiscoveryState(nextState)
                    try discoveryStore.save(nextState)
                    applyImportedConfigurationSnapshot(importedSnapshot)
                    routes = try routeStore.load(catalog: proxyCatalog())
                    catalogLoadError = nil
                    recordEvent(.info, "模型探测已刷新 \(providers.count) 个供应商")
                    publishState()
                    appState.showToast("模型探测已刷新")
                } catch {
                    showError("模型探测结果应用失败：\(error.localizedDescription)")
                }
            }
        } catch {
            showError("模型探测刷新失败：\(error.localizedDescription)")
        }
    }

    private func scheduleAutomaticModelDiscoveryRefresh() {
        guard userModelDiscoveryTask == nil, !appState.isRefreshingModelDiscovery else {
            return
        }
        automaticModelDiscoveryTask?.cancel()
        let providers = catalog.providers
        guard !providers.isEmpty else {
            return
        }
        let validProviders = catalog.providers
        automaticModelDiscoveryTask = Task { [providers, validProviders] in
            await refreshModelDiscoverySilently(providers: providers, validProviders: validProviders)
        }
    }

    private func refreshModelDiscoverySilently(providers: [ImportedProvider], validProviders: [ImportedProvider]) async {
        var nextState = discoveryState.pruning(validProviders: validProviders)
        var didRefreshProvider = nextState != discoveryState
        for provider in providers {
            guard !Task.isCancelled else {
                return
            }
            let fingerprint = ProviderModelDiscoveryFingerprint.value(for: provider)
            if nextState.results[provider.ref.description]?.configurationFingerprint == fingerprint {
                continue
            }
            let result = await discoverModels(for: provider)
            guard !Task.isCancelled else {
                return
            }
            nextState.upsert(result)
            didRefreshProvider = true
        }
        guard !Task.isCancelled, didRefreshProvider, userModelDiscoveryTask == nil, !appState.isRefreshingModelDiscovery else {
            return
        }
        do {
            discoveryState = nextState.pruning(validProviders: catalog.providers)
            try discoveryStore.save(discoveryState)
            catalog = try loadExpandedCatalog()
            routes = try routeStore.load(catalog: proxyCatalog())
            recordEvent(.info, "已自动刷新模型探测缓存")
            publishState()
        } catch {
            recordEvent(.error, formattedIssueMessage(
                appName: "Uni Gate",
                group: "模型探测",
                detail: "自动刷新失败：\(error.localizedDescription)"
            ))
        }
    }

    private func discoverModels(for provider: ImportedProvider) async -> ProviderModelDiscoveryResult {
        let now = Date()
        let fingerprint = ProviderModelDiscoveryFingerprint.value(for: provider)
        guard let plan = ProviderModelDiscovery.fetchPlan(for: provider) else {
            return ProviderModelDiscoveryResult(
                providerRef: provider.ref,
                appType: provider.appType,
                providerName: provider.name,
                modelIDs: [],
                errorMessage: "缺少模型接口地址或鉴权信息",
                sourceURL: provider.baseURL,
                updatedAt: now,
                configurationFingerprint: fingerprint
            )
        }

        var lastFailure: String?
        for url in plan.urls {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            for (key, value) in plan.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let userAgent = plan.userAgent {
                request.setValue(userAgent, forHTTPHeaderField: "user-agent")
            }

            let networkPolicy = NetworkPolicyResolver.effectiveMode(
                preferences: preferences.networkPolicy,
                providerRef: provider.ref,
                host: url.host
            )
            let session = NetworkPolicySession.makeSession(for: networkPolicy)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    clearNetworkDiagnostic(providerRef: provider.ref)
                    let ids = ProviderModelDiscovery.modelIDs(from: data)
                    return ProviderModelDiscoveryResult(
                        providerRef: provider.ref,
                        appType: provider.appType,
                        providerName: provider.name,
                        modelIDs: ids,
                        errorMessage: ids.isEmpty ? "接口返回成功，但未解析到模型" : nil,
                        sourceURL: url.absoluteString,
                        updatedAt: now,
                        configurationFingerprint: fingerprint
                    )
                }
                lastFailure = "networkPolicy=\(networkPolicy.rawValue) HTTP \(status)"
                if status == 404 || status == 405 {
                    continue
                }
                break
            } catch {
                lastFailure = "networkPolicy=\(networkPolicy.rawValue) \(error.localizedDescription)"
                await updateNetworkPolicyDiagnosticIfAlternateResponds(
                    provider: provider,
                    request: request,
                    url: url,
                    failedMode: networkPolicy,
                    failedError: error.localizedDescription
                )
                break
            }
        }

        return ProviderModelDiscoveryResult(
            providerRef: provider.ref,
            appType: provider.appType,
            providerName: provider.name,
            modelIDs: [],
            errorMessage: lastFailure ?? "所有模型接口均不可用",
            sourceURL: plan.urls.first?.absoluteString,
            updatedAt: now,
            configurationFingerprint: fingerprint
        )
    }

    private func updateNetworkPolicyDiagnosticIfAlternateResponds(
        provider: ImportedProvider,
        request: URLRequest,
        url: URL,
        failedMode: NetworkPolicyMode,
        failedError: String
    ) async {
        let fallbackMode = failedMode.alternate
        do {
            let session = NetworkPolicySession.makeSession(for: fallbackMode)
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status > 0 else {
                clearNetworkDiagnostic(providerRef: provider.ref)
                return
            }
            let previous = networkDiagnostics[provider.ref.description]
            networkDiagnostics[provider.ref.description] = NetworkPolicyDiagnostic(
                providerRef: provider.ref,
                appType: provider.appType,
                providerName: provider.name,
                url: url.absoluteString,
                failedMode: failedMode,
                failedError: failedError,
                fallbackMode: fallbackMode,
                fallbackStatusCode: status
            )
            appState.updateNetworkDiagnostics(networkDiagnostics)
            if previous == nil
                || previous?.failedMode != failedMode
                || previous?.failedError != failedError
                || previous?.fallbackMode != fallbackMode
                || previous?.fallbackStatusCode != status {
                recordEvent(.error, formattedIssueMessage(
                    appName: ProviderDisplay.appTypeLabel(provider.appType),
                    group: "网络诊断",
                    detail: "\(provider.name)：networkPolicy=\(failedMode.rawValue) 请求失败，但 networkPolicy=\(fallbackMode.rawValue) 可连通 HTTP \(status)。url=\(url.absoluteString) error=\(failedError)"
                ))
            }
        } catch {
            clearNetworkDiagnostic(providerRef: provider.ref)
        }
    }

    private func clearNetworkDiagnostic(providerRef: ProviderRef) {
        guard networkDiagnostics.removeValue(forKey: providerRef.description) != nil else {
            return
        }
        appState.updateNetworkDiagnostics(networkDiagnostics)
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        if statusItemController.isPopoverShown {
            appState.showToast(message)
        } else if preferences.bubbleNotificationsEnabled {
            statusItemController.showNotice(
                message: formattedIssueMessage(appName: "Uni Gate", group: "异常", detail: message),
                accentColor: .systemRed
            )
        }
    }

    private func showBackgroundError(_ message: String) {
        guard preferences.bubbleNotificationsEnabled, !statusItemController.isPopoverShown else {
            return
        }
        statusItemController.showNotice(
            message: message,
            accentColor: .systemRed
        )
    }

    private func defaultCcSwitchDBPath() -> String {
        if let path = ProcessInfo.processInfo.environment["API_MANAGER_CC_SWITCH_DB"], !path.isEmpty {
            return path
        }
        return preferences.resolvedCcSwitchDBPath
    }

    private func currentImporter() -> CcSwitchImporter {
        CcSwitchImporter(dbPath: defaultCcSwitchDBPath())
    }

    private func syncCcSwitchDBWatcher() {
        let dbPath = defaultCcSwitchDBPath()
        dbWatcher.start(dbPath: dbPath) { [weak self] in
            Task { @MainActor in
                self?.reloadFromCcSwitchDBChange()
            }
        }
    }

    private func defaultRouteStoreURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["API_MANAGER_ROUTE_STATE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return RouteStore.defaultFileURL()
    }

    private func defaultPreferencesStoreURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["API_MANAGER_PREFERENCES"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return PreferencesStore.defaultFileURL()
    }

    private func loadExpandedCatalog() throws -> ProviderCatalog {
        let imported = try currentImporter().loadCatalog().applyingProtocolOverrides(preferences.protocolOverrides)
        return loadExpandedCatalog(imported: imported)
    }

    private func loadExpandedCatalog(imported: ProviderCatalog) -> ProviderCatalog {
        let discoveredCandidates = ProviderModelDiscovery.discoveredCandidates(
            from: discoveryState,
            catalog: imported
        )
        let baseCatalog = ProviderCatalog(
            providers: imported.providers,
            candidates: imported.candidates + discoveredCandidates
        )
        let customCandidates = customModels.expandedCandidates(from: baseCatalog)
        return ProviderCatalog(
            providers: imported.providers,
            candidates: baseCatalog.candidates + customCandidates
        )
    }

    private func loadImportedConfigurationSnapshot() throws -> ImportedConfigurationSnapshot {
        let importedCatalog = try currentImporter().loadCatalog().applyingProtocolOverrides(preferences.protocolOverrides)
        let uniGateModelScope = try currentImporter().loadUniGateModelScope()
        let integrationSnapshot = try currentImporter().loadIntegrationSnapshot()
        return ImportedConfigurationSnapshot(
            catalog: importedCatalog,
            uniGateModelScope: uniGateModelScope,
            integrationSnapshot: integrationSnapshot
        )
    }

    private func applyImportedConfigurationSnapshot(_ snapshot: ImportedConfigurationSnapshot) {
        catalog = loadExpandedCatalog(imported: snapshot.catalog)
        uniGateModelScope = snapshot.uniGateModelScope
        integrationSnapshot = snapshot.integrationSnapshot
    }

    private func pruneDiscoveryState(for catalog: ProviderCatalog) {
        let nextState = discoveryState.pruning(validProviders: catalog.providers)
        guard nextState != discoveryState else {
            pruneNetworkDiagnostics(for: catalog)
            return
        }
        discoveryState = nextState
        try? discoveryStore.save(nextState)
        pruneNetworkDiagnostics(for: catalog)
    }

    private func pruneNetworkDiagnostics(for catalog: ProviderCatalog) {
        let validRefs = Set(catalog.providers.map(\.ref.description))
        let nextDiagnostics = networkDiagnostics.filter { validRefs.contains($0.key) }
        guard nextDiagnostics != networkDiagnostics else {
            return
        }
        networkDiagnostics = nextDiagnostics
        appState.updateNetworkDiagnostics(networkDiagnostics)
    }

    private func defaultProxyPort() -> UInt16 {
        guard
            let value = ProcessInfo.processInfo.environment["API_MANAGER_PORT"],
            let port = UInt16(value)
        else {
            return preferences.normalizedPort
        }
        return port
    }

    private func currentProxyPort() -> UInt16 {
        defaultProxyPort()
    }

    private func managerBaseURL() -> String {
        "http://\(proxyHost):\(currentProxyPort())"
    }

    private func recordEvent(_ level: ProxyEvent.Level, _ message: String) {
        recentEvents.insert(ProxyEvent(date: Date(), level: level, message: message), at: 0)
        if recentEvents.count > 20 {
            recentEvents.removeLast(recentEvents.count - 20)
        }
        logger.log(level, message)
        appState.updateRecentEvents(recentEvents)
        if level == .error {
            showBackgroundError(message)
        }
    }

    private func formattedIssueMessage(appName: String, group: String, detail: String) -> String {
        "\(appName) · \(group)：\(detail)"
    }

    private func configureAppStateActions() {
        appState.onSwitchProvider = { [weak self] routeKeys, providerRef in
            self?.switchProvider(routeKeys: routeKeys, providerRef: providerRef)
        }
        appState.onReload = { [weak self] in
            self?.reloadAction()
        }
        appState.onOpenAppFolder = { [weak self] in
            self?.openAppFolder()
        }
        appState.onQuit = { [weak self] in
            self?.quit()
        }
        appState.onSaveSettings = { [weak self] preferences, customModels in
            self?.saveSettings(preferences, customModels: customModels)
        }
        appState.onApplySettings = { [weak self] preferences, customModels in
            self?.applySettings(preferences, customModels: customModels)
        }
        appState.onRefreshModelDiscovery = { [weak self] appType in
            self?.refreshModelDiscovery(appType: appType)
        }
        appState.onCopyDiagnostics = { [weak self] in
            self?.copyDiagnostics()
        }
        appState.onExportConfiguration = { [weak self] in
            self?.exportConfiguration()
        }
        appState.onImportConfiguration = { [weak self] in
            self?.importConfiguration()
        }
        appState.onResetConfiguration = { [weak self] in
            self?.resetConfiguration()
        }
        appState.onSetProviderNetworkPolicy = { [weak self] providerRef, override in
            self?.setProviderNetworkPolicy(providerRef: providerRef, override: override)
        }
    }

    private func publishState() {
        appState.updateSnapshot(
            catalog: catalog,
            routes: routes,
            preferences: preferences,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            proxyStatus: proxyStatus,
            proxyPort: currentProxyPort(),
            integrationSnapshot: integrationSnapshot,
            loadError: catalogLoadError
        )
        appState.updateRecentEvents(recentEvents)
        appState.updateForwardedRequestCounts(forwardedRequestCounts)
        appState.updateRequestMetrics(requestMetrics)
        appState.updateDiscoveryState(discoveryState)
        appState.updateNetworkDiagnostics(networkDiagnostics)
    }

    private func publishError(_ error: Error, notify: Bool = true) {
        catalogLoadError = "加载 cc-switch DB 失败：\(error.localizedDescription)"
        publishState()
        guard notify else {
            return
        }
        showBackgroundError(formattedIssueMessage(
            appName: "Uni Gate",
            group: "配置异常",
            detail: catalogLoadError ?? error.localizedDescription
        ))
    }

    private func updateProxyStatus(
        _ status: ProxyStatus,
        eventLevel: ProxyEvent.Level? = nil,
        eventMessage: String? = nil
    ) {
        let didChange = proxyStatus != status
        proxyStatus = status
        if let eventLevel, let eventMessage, didChange {
            recordEvent(eventLevel, eventMessage)
        }
        appState.updateProxyStatus(status, port: currentProxyPort())
        appState.updateRecentEvents(recentEvents)
    }

    private func startHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.checkProxyHealth()
            }
        }
    }

    private func checkProxyHealth() async {
        guard let serverID = currentProxyServerID else {
            return
        }
        let url = URL(string: "\(managerBaseURL())/__manager/health")!
        let result = await ProxyHealthProbe.check(url: url, expectedServerID: serverID)
        guard serverID == currentProxyServerID else {
            return
        }

        switch result {
        case .success:
            if !proxyStatus.isRunning {
                updateProxyStatus(
                    .running,
                    eventLevel: .info,
                    eventMessage: "代理健康检查恢复 \(managerBaseURL())"
                )
            }
        case .failure(let message):
            updateProxyStatus(
                .failed("健康检查失败：\(message)"),
                eventLevel: .error,
                eventMessage: formattedIssueMessage(
                    appName: "Uni Gate",
                    group: "代理异常",
                    detail: "代理健康检查失败：\(message)"
                )
            )
        }
    }
}

extension AppDelegate: LocalProxyRuntime {
    func proxySnapshot() -> ProxyRuntimeSnapshot {
        ProxyRuntimeSnapshot(catalog: proxyCatalog(), routes: routes, networkPolicy: preferences.networkPolicy)
    }

    func modelListSnapshot() -> ProxyRuntimeSnapshot {
        ProxyRuntimeSnapshot(catalog: catalog, routes: routes, networkPolicy: preferences.networkPolicy)
    }

    func reloadProxyRuntime() throws -> ProxyRuntimeSnapshot {
        preferences = try preferencesStore.load()
        customModels = try customModelStore.load()
        discoveryState = try discoveryStore.load()
        let importedSnapshot = try loadImportedConfigurationSnapshot()
        ccSwitchConfigurationFingerprint = try currentImporter().loadConfigurationFingerprint()
        pruneDiscoveryState(for: importedSnapshot.catalog)
        applyImportedConfigurationSnapshot(importedSnapshot)
        routes = try routeStore.load(catalog: proxyCatalog())
        catalogLoadError = nil
        recordEvent(.info, "已重新加载 cc-switch DB")
        publishState()
        syncCcSwitchDBWatcher()
        return proxySnapshot()
    }

    func switchProxyRoute(routeKey: ModelRouteKey, providerRef: ProviderRef) throws -> ProxyRuntimeSnapshot {
        routes = try routeStore.switchRoute(
            routes,
            catalog: proxyCatalog(),
            appType: routeKey.appType,
            logicalModel: routeKey.logicalModel,
            providerRef: providerRef
        )
        recordEvent(.info, "Switched \(routeKey.description) to \(providerRef.description)")
        publishState()
        return proxySnapshot()
    }

    private func proxyCatalog() -> ProviderCatalog {
        catalog.scopedForProxy(
            uniGateModelScope: uniGateModelScope,
            customModels: customModels
        )
    }

    func recordProxyEvent(level: ProxyEvent.Level, message: String) {
        recordEvent(level, message)
    }

    func recordForwardedRequest(appType: String) {
        forwardedRequestCounts[appType, default: 0] += 1
        appState.updateForwardedRequestCounts(forwardedRequestCounts)
    }

    func recordRequestMetric(
        key: RequestMetricKey,
        statusCode: Int?,
        latencyMilliseconds: Double,
        errorMessage: String?,
        providerFailure: Bool
    ) {
        requestMetrics.record(
            key: key,
            statusCode: statusCode,
            latencyMilliseconds: latencyMilliseconds,
            errorMessage: errorMessage,
            providerFailure: providerFailure
        )
        appState.updateRequestMetrics(requestMetrics)
    }

    func proxyProviderDidSucceed() {
        guard proxyStatus.isProviderIssue else {
            return
        }
        providerIssueClearTask?.cancel()
        providerIssueClearTask = nil
        updateProxyStatus(
            .running,
            eventLevel: .info,
            eventMessage: "供应商请求恢复"
        )
    }

    func proxyProviderDidFail(_ message: String) {
        guard proxyStatus.canShowProviderIssue else {
            return
        }
        updateProxyStatus(
            .providerIssue(message),
            eventLevel: .error,
            eventMessage: formattedIssueMessage(
                appName: "Uni Gate",
                group: "供应商异常",
                detail: message
            )
        )
        scheduleProviderIssueClear(serverID: currentProxyServerID)
    }

    func proxyProviderDidFail(appType: String, message: String) {
        guard proxyStatus.canShowProviderIssue else {
            return
        }
        let appName = ProviderDisplay.appTypeLabel(appType)
        let eventMessage = formattedIssueMessage(appName: appName, group: "供应商异常", detail: message)
        updateProxyStatus(
            .providerIssue(message),
            eventLevel: .error,
            eventMessage: eventMessage
        )
        scheduleProviderIssueClear(serverID: currentProxyServerID)
    }

    private func scheduleProviderIssueClear(serverID: UUID?) {
        providerIssueClearTask?.cancel()
        providerIssueClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard
                !Task.isCancelled,
                let self,
                serverID == self.currentProxyServerID,
                self.proxyStatus.isProviderIssue
            else {
                return
            }
            self.providerIssueClearTask = nil
            self.updateProxyStatus(
                .running,
                eventLevel: .info,
                eventMessage: "供应商异常提示已自动恢复"
            )
        }
    }

    func proxyListenerDidChange(_ state: ProxyListenerState, serverID: UUID) {
        guard serverID == currentProxyServerID else {
            return
        }

        switch state {
        case .setup:
            updateProxyStatus(.starting)
        case .waiting(let message):
            updateProxyStatus(
                .failed("监听等待：\(message)"),
                eventLevel: .error,
                eventMessage: formattedIssueMessage(
                    appName: "Uni Gate",
                    group: "代理异常",
                    detail: "代理监听等待：\(message)"
                )
            )
        case .ready:
            updateProxyStatus(
                .running,
                eventLevel: .info,
                eventMessage: "代理正在监听 \(managerBaseURL())"
            )
        case .failed(let message):
            updateProxyStatus(
                .failed("监听失败：\(message)"),
                eventLevel: .error,
                eventMessage: formattedIssueMessage(
                    appName: "Uni Gate",
                    group: "代理异常",
                    detail: "代理监听失败：\(message)"
                )
            )
        case .cancelled:
            updateProxyStatus(
                .failed("监听已停止"),
                eventLevel: .error,
                eventMessage: formattedIssueMessage(
                    appName: "Uni Gate",
                    group: "代理异常",
                    detail: "代理监听已停止"
                )
            )
        }
    }
}

enum ProxyStatus: Equatable {
    case starting
    case running
    case providerIssue(String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        if case .providerIssue = self {
            return true
        }
        return false
    }

    var isProviderIssue: Bool {
        if case .providerIssue = self {
            return true
        }
        return false
    }

    var canShowProviderIssue: Bool {
        switch self {
        case .running, .providerIssue:
            return true
        case .starting, .failed:
            return false
        }
    }

    func title(port: UInt16) -> String {
        switch self {
        case .starting:
            return "代理端口: \(port) | 启动中"
        case .running:
            return "代理端口: \(port) | 运行中"
        case let .providerIssue(message):
            return "代理端口: \(port) | 供应商异常：\(message)"
        case let .failed(message):
            return "代理端口: \(port) | 失败：\(message)"
        }
    }

    var shortTitle: String {
        switch self {
        case .starting:
            return "启动中"
        case .running:
            return "运行中"
        case .providerIssue:
            return "供应商异常"
        case .failed:
            return "失败"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .starting:
            return .systemRed
        case .running:
            return .systemGreen
        case .providerIssue:
            return .systemYellow
        case .failed:
            return .systemRed
        }
    }
}

private enum ProxyHealthResult {
    case success
    case failure(String)
}

private enum ProxyHealthProbe {
    static func check(url: URL, expectedServerID: UUID) async -> ProxyHealthResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("无 HTTP 响应")
            }
            if http.statusCode == 200 {
                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let serverID = json["serverID"] as? String
                else {
                    return .failure("健康检查缺少实例标识")
                }
                if serverID == expectedServerID.uuidString {
                    return .success
                }
                return .failure("端口由其他实例占用")
            }
            return .failure("HTTP \(http.statusCode)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

struct ProxyEvent {
    enum Level: String {
        case info
        case error
    }

    let date: Date
    let level: Level
    let message: String
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
