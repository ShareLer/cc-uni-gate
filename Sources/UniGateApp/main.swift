import UniGateCore
import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let proxyHost = "127.0.0.1"
    private var statusItem: NSStatusItem!
    private var catalog: ProviderCatalog = ProviderCatalog(providers: [], candidates: [])
    private var uniGateModelScope = UniGateModelScope()
    private var routes = RouteState()
    private var preferences = AppPreferences()
    private var customModels = CustomModelState()
    private lazy var routeStore = RouteStore(fileURL: defaultRouteStoreURL())
    private lazy var preferencesStore = PreferencesStore(fileURL: defaultPreferencesStoreURL())
    private lazy var customModelStore = CustomModelStore()
    private var settingsWindowController: SettingsWindowController?
    private var proxyServer: LocalProxyServer?
    private var proxyStatus: ProxyStatus = .starting
    private var recentEvents: [ProxyEvent] = []
    private var forwardedRequestCounts: [String: Int] = [:]
    private var currentProxyServerID: UUID?
    private var healthCheckTask: Task<Void, Never>?
    private weak var proxyStatusMenuItem: NSMenuItem?
    private let logger = FileLogger()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "CC Uni Gate"
        updateStatusItemAppearance()
        do {
            try AppPaths.migrateLegacyApplicationSupportDirectory()
        } catch {
            showError(error)
        }
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
            rebuildMenu()
        } catch {
            rebuildErrorMenu(error)
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

    private func rebuildMenu() {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "CC Uni Gate", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let summaryItem = NSMenuItem(
            title: "\(catalog.providers.count) 个供应商，\(catalog.models.count) 个模型",
            action: nil,
            keyEquivalent: ""
        )
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)

        let proxyItem = NSMenuItem(
            title: proxyStatus.title(port: currentProxyPort()),
            action: nil,
            keyEquivalent: ""
        )
        proxyItem.isEnabled = false
        menu.addItem(proxyItem)
        proxyStatusMenuItem = proxyItem
        for item in forwardedRequestCountItems() {
            menu.addItem(item)
        }
        for item in uniGateScopeWarningItems() {
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let visibleRouteKeys = menuRouteKeys()
        if visibleRouteKeys.isEmpty {
            let emptyItem = NSMenuItem(title: "未选择模型", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        for appType in catalog.appTypes {
            let keys = visibleRouteKeys.filter { $0.appType == appType }
            guard !keys.isEmpty else {
                continue
            }
            let appItem = NSMenuItem(
                title: ProviderDisplay.appTypeLabel(appType),
                action: nil,
                keyEquivalent: ""
            )
            let appSubmenu = NSMenu()
            for key in keys {
                let modelItem = NSMenuItem(title: key.logicalModel, action: nil, keyEquivalent: "")
                let providerSubmenu = NSMenu()
                for candidate in catalog.candidates(for: key) {
                    let providerItem = NSMenuItem(
                        title: providerTitle(candidate),
                        action: #selector(switchProvider(_:)),
                        keyEquivalent: ""
                    )
                    providerItem.target = self
                    providerItem.representedObject = MenuRouteSelection(
                        routeKey: key,
                        providerRef: candidate.providerRef
                    )
                    if routes.routes[key.description]?.providerRef == candidate.providerRef {
                        providerItem.state = .on
                    }
                    providerSubmenu.addItem(providerItem)
                }
                appSubmenu.setSubmenu(providerSubmenu, for: modelItem)
                appSubmenu.addItem(modelItem)
            }
            menu.setSubmenu(appSubmenu, for: appItem)
            menu.addItem(appItem)
        }

        menu.addItem(.separator())
        menu.addItem(appMenuItem(title: "打开应用文件夹", action: #selector(openAppFolder), keyEquivalent: ""))
        menu.addItem(appMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(appMenuItem(title: "重新加载 cc-switch DB", action: #selector(reloadAction), keyEquivalent: "r"))
        menu.addItem(appMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusItemAppearance()
    }

    private func rebuildErrorMenu(_ error: Error) {
        proxyStatusMenuItem = nil
        let menu = NSMenu()
        let errorItem = NSMenuItem(title: "加载 cc-switch DB 失败", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        menu.addItem(errorItem)
        let detailItem = NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        menu.addItem(detailItem)
        menu.addItem(.separator())
        menu.addItem(appMenuItem(title: "重试", action: #selector(reloadAction), keyEquivalent: "r"))
        menu.addItem(appMenuItem(title: "打开应用文件夹", action: #selector(openAppFolder), keyEquivalent: ""))
        menu.addItem(appMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusItemAppearance()
    }

    private func appMenuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func providerTitle(_ candidate: ModelCandidate) -> String {
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

    private func menuRouteKeys() -> [ModelRouteKey] {
        let configuredRouteKeys = catalog.routeKeys.filter { key in
            guard key.appType == "claude" || key.appType == "codex" else {
                return true
            }
            return uniGateModelScope.contains(key)
        }
        return preferences.visibleRouteKeyList(allRouteKeys: configuredRouteKeys)
    }

    private func forwardedRequestCountItems() -> [NSMenuItem] {
        let appTypes = ["claude", "codex", "claude-desktop", "gemini"]
        return appTypes.compactMap { appType in
            guard let count = forwardedRequestCounts[appType], count > 0 else {
                return nil
            }
            let item = NSMenuItem(
                title: "\(ProviderDisplay.appTypeLabel(appType))：\(count) req",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            return item
        }
    }

    private func uniGateScopeWarningItems() -> [NSMenuItem] {
        let missing = missingUniGateScopeAppTypes()
        guard !missing.isEmpty else {
            return []
        }
        let labels = missing.map(ProviderDisplay.appTypeLabel).joined(separator: "、")
        let titleItem = NSMenuItem(
            title: "未识别到 \(labels) 的 UniGate 配置",
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        let detailItem = NSMenuItem(
            title: "请检查 cc-switch 供应商名称或 Base URL",
            action: nil,
            keyEquivalent: ""
        )
        detailItem.isEnabled = false
        return [titleItem, detailItem]
    }

    private func missingUniGateScopeAppTypes() -> [String] {
        ["claude", "codex"].filter { appType in
            catalog.candidates.contains {
                $0.appType == appType && $0.providerRef == $0.upstreamProviderRef
            } && !uniGateModelScope.hasModels(for: appType)
        }
    }

    private func stripOneMSuffix(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"\[\s*1m\s*\]\s*$"#, options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MenuRouteSelection else {
            return
        }

        do {
            routes = try routeStore.switchRoute(
                routes,
                catalog: catalog,
                appType: selection.routeKey.appType,
                logicalModel: selection.routeKey.logicalModel,
                providerRef: selection.providerRef
            )
            rebuildMenu()
        } catch {
            showError(error)
        }
    }

    @objc private func reloadAction() {
        reloadCatalog()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                providers: catalog.providers,
                candidates: catalog.candidates,
                routeKeys: catalog.routeKeys,
                customModels: customModels,
                uniGateModelScope: uniGateModelScope,
                proxyStatus: proxyStatus,
                preferences: preferences,
                onSave: { [weak self] preferences, customModels in
                    guard let self else {
                        return
                    }
                    do {
                        let previousPort = self.currentProxyPort()
                        self.preferences = preferences
                        self.customModels = customModels
                        try self.preferencesStore.save(preferences)
                        try self.customModelStore.save(customModels)
                        self.reloadCatalog()
                        if self.currentProxyPort() != previousPort {
                            self.startProxyServer()
                        }
                    } catch {
                        self.showError(error)
                    }
                }
            )
        } else {
            settingsWindowController?.update(
                providers: catalog.providers,
                candidates: catalog.candidates,
                routeKeys: catalog.routeKeys,
                customModels: customModels,
                uniGateModelScope: uniGateModelScope,
                proxyStatus: proxyStatus,
                preferences: preferences
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAppFolder() {
        try? FileManager.default.createDirectory(
            at: AppPaths.logsDirectory(),
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(AppPaths.applicationSupportDirectory())
    }

    @objc private func quit() {
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
        if didChange {
            updateVisibleProxyStatusMenuItem()
            rebuildMenu()
            settingsWindowController?.updateProxyStatus(status)
        } else {
            updateStatusItemAppearance()
        }
    }

    private func updateVisibleProxyStatusMenuItem() {
        proxyStatusMenuItem?.title = proxyStatus.title(port: currentProxyPort())
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else {
            return
        }
        let title = NSMutableAttributedString(
            string: "UniGate ",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        title.append(NSAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: proxyStatus.accentColor,
                .baselineOffset: 1
            ]
        ))
        button.attributedTitle = title
        button.toolTip = "CC Uni Gate · \(proxyStatus.title(port: currentProxyPort()))"
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
        rebuildMenu()
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
        rebuildMenu()
        return proxySnapshot()
    }

    func recordProxyEvent(level: ProxyEvent.Level, message: String) {
        recordEvent(level, message)
        rebuildMenu()
    }

    func recordForwardedRequest(appType: String) {
        forwardedRequestCounts[appType, default: 0] += 1
        rebuildMenu()
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

private final class MenuRouteSelection: NSObject {
    let routeKey: ModelRouteKey
    let providerRef: ProviderRef

    init(routeKey: ModelRouteKey, providerRef: ProviderRef) {
        self.routeKey = routeKey
        self.providerRef = providerRef
    }
}

@MainActor
private final class SettingsWindowController: NSWindowController {
    private var preferences: AppPreferences
    private let viewModel: SettingsViewModel

    init(
        providers: [ImportedProvider],
        candidates: [ModelCandidate],
        routeKeys: [ModelRouteKey],
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        proxyStatus: ProxyStatus,
        preferences: AppPreferences,
        onSave: @escaping (AppPreferences, CustomModelState) -> Void
    ) {
        self.preferences = preferences
        self.viewModel = SettingsViewModel(
            providers: providers,
            candidates: candidates,
            routeKeys: routeKeys,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            proxyStatus: proxyStatus,
            preferences: preferences,
            onSave: onSave
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CC Uni Gate"
        window.minSize = NSSize(width: 820, height: 560)
        window.center()
        super.init(window: window)
        viewModel.onClose = { [weak self] in
            self?.close()
        }
        buildContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        providers: [ImportedProvider],
        candidates: [ModelCandidate],
        routeKeys: [ModelRouteKey],
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        proxyStatus: ProxyStatus,
        preferences: AppPreferences
    ) {
        self.preferences = preferences
        viewModel.update(
            providers: providers,
            candidates: candidates,
            routeKeys: routeKeys,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope,
            proxyStatus: proxyStatus,
            preferences: preferences
        )
    }

    func updateProxyStatus(_ proxyStatus: ProxyStatus) {
        viewModel.proxyStatus = proxyStatus
    }

    override func showWindow(_ sender: Any?) {
        viewModel.portText = "\(preferences.normalizedPort)"
        super.showWindow(sender)
    }

    private func buildContent() {
        window?.contentView = NSHostingView(rootView: SettingsRootView(model: viewModel))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
