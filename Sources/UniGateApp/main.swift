import UniGateCore
import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let proxyHost = "127.0.0.1"
    private let appState = UniGateAppState()
    private let statusItemController = StatusItemController()
    private var catalog: ProviderCatalog = ProviderCatalog(providers: [], candidates: [])
    private var uniGateModelScope = UniGateModelScope()
    private var routes = RouteState()
    private var preferences = AppPreferences()
    private var customModels = CustomModelState()
    private lazy var routeStore = RouteStore(fileURL: defaultRouteStoreURL())
    private lazy var preferencesStore = PreferencesStore(fileURL: defaultPreferencesStoreURL())
    private lazy var customModelStore = CustomModelStore()
    private var proxyServer: LocalProxyServer?
    private var proxyStatus: ProxyStatus = .starting
    private var catalogLoadError: String?
    private var recentEvents: [ProxyEvent] = []
    private var forwardedRequestCounts: [String: Int] = [:]
    private var currentProxyServerID: UUID?
    private var healthCheckTask: Task<Void, Never>?
    private let logger = FileLogger()

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
        currentProxyServerID = nil
        proxyServer?.stop()
    }

    private func reloadCatalog() {
        do {
            preferences = try preferencesStore.load()
            customModels = try customModelStore.load()
            catalog = try loadExpandedCatalog()
            uniGateModelScope = try currentImporter().loadUniGateModelScope()
            routes = try routeStore.load(catalog: catalog)
            catalogLoadError = nil
            publishState()
        } catch {
            publishError(error)
        }
    }

    private func startProxyServer() {
        do {
            healthCheckTask?.cancel()
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
                eventMessage: "代理启动失败：\(error.localizedDescription)"
            )
            showError(error)
        }
    }

    private func switchProvider(routeKeys: [ModelRouteKey], providerRef: ProviderRef) {
        do {
            routes = try routeStore.switchRoutes(
                routes,
                catalog: catalog,
                routeKeys: routeKeys,
                providerRef: providerRef
            )
            publishState()
        } catch {
            showError(error)
        }
    }

    private func reloadAction() {
        reloadCatalog()
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
            try preferencesStore.save(preferences)
            try customModelStore.save(customModels)
            reloadCatalog()
            if currentProxyPort() != previousPort {
                startProxyServer()
            }
            if closeAfterSave {
                appState.closeSettings()
                appState.showToast("已保存")
            }
        } catch {
            showError(error)
        }
    }

    private func openAppFolder() {
        try? FileManager.default.createDirectory(
            at: AppPaths.logsDirectory(),
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(AppPaths.applicationSupportDirectory())
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "CC Uni Gate"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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
        let customCandidates = customModels.expandedCandidates(from: imported)
        return ProviderCatalog(
            providers: imported.providers,
            candidates: imported.candidates + customCandidates
        )
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
            loadError: catalogLoadError
        )
        appState.updateRecentEvents(recentEvents)
        appState.updateForwardedRequestCounts(forwardedRequestCounts)
    }

    private func publishError(_ error: Error) {
        catalogLoadError = "加载 cc-switch DB 失败：\(error.localizedDescription)"
        publishState()
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
                eventMessage: "代理健康检查失败：\(message)"
            )
        }
    }
}

extension AppDelegate: LocalProxyRuntime {
    func proxySnapshot() -> ProxyRuntimeSnapshot {
        ProxyRuntimeSnapshot(catalog: catalog, routes: routes)
    }

    func reloadProxyRuntime() throws -> ProxyRuntimeSnapshot {
        preferences = try preferencesStore.load()
        customModels = try customModelStore.load()
        catalog = try loadExpandedCatalog()
        uniGateModelScope = try currentImporter().loadUniGateModelScope()
        routes = try routeStore.load(catalog: catalog)
        recordEvent(.info, "已重新加载 cc-switch DB")
        publishState()
        return proxySnapshot()
    }

    func switchProxyRoute(routeKey: ModelRouteKey, providerRef: ProviderRef) throws -> ProxyRuntimeSnapshot {
        routes = try routeStore.switchRoute(
            routes,
            catalog: catalog,
            appType: routeKey.appType,
            logicalModel: routeKey.logicalModel,
            providerRef: providerRef
        )
        recordEvent(.info, "Switched \(routeKey.description) to \(providerRef.description)")
        publishState()
        return proxySnapshot()
    }

    func recordProxyEvent(level: ProxyEvent.Level, message: String) {
        recordEvent(level, message)
    }

    func recordForwardedRequest(appType: String) {
        forwardedRequestCounts[appType, default: 0] += 1
        appState.updateForwardedRequestCounts(forwardedRequestCounts)
    }

    func proxyProviderDidSucceed() {
        guard proxyStatus.isProviderIssue else {
            return
        }
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
            eventMessage: "供应商请求异常：\(message)"
        )
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
                eventMessage: "代理监听等待：\(message)"
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
                eventMessage: "代理监听失败：\(message)"
            )
        case .cancelled:
            updateProxyStatus(
                .failed("监听已停止"),
                eventLevel: .error,
                eventMessage: "代理监听已停止"
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
