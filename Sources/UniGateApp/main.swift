import UniGateCore
import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let proxyHost = "127.0.0.1"
    private var statusItem: NSStatusItem!
    private var catalog: ProviderCatalog = ProviderCatalog(providers: [], candidates: [])
    private var routes = RouteState()
    private var preferences = AppPreferences()
    private var customModels = CustomModelState()
    private lazy var routeStore = RouteStore(fileURL: defaultRouteStoreURL())
    private lazy var preferencesStore = PreferencesStore(fileURL: defaultPreferencesStoreURL())
    private lazy var customModelStore = CustomModelStore()
    private var settingsWindowController: SettingsWindowController?
    private var proxyServer: LocalProxyServer?
    private lazy var importer = CcSwitchImporter(dbPath: defaultCcSwitchDBPath())
    private var proxyStatus: ProxyStatus = .starting
    private var recentEvents: [ProxyEvent] = []
    private var currentProxyServerID: UUID?
    private var healthCheckTask: Task<Void, Never>?
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
        menu.addItem(.separator())

        let visibleRouteKeys = preferences.visibleRouteKeyList(allRouteKeys: catalog.routeKeys)
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
        if candidate.upstreamModel != candidate.logicalModel {
            parts.append(candidate.upstreamModel)
        } else if let label = candidate.label, label != candidate.providerName {
            parts.append(label)
        }
        if candidate.requiresTransform {
            parts.append("需要转换")
        } else {
            parts.append(candidate.apiFormat.rawValue)
        }
        return parts.joined(separator: " · ")
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
                proxyStatus: proxyStatus,
                preferences: preferences,
                onSave: { [weak self] preferences, customModels in
                    guard let self else {
                        return
                    }
                    do {
                        self.preferences = preferences
                        self.customModels = customModels
                        try self.preferencesStore.save(preferences)
                        try self.customModelStore.save(customModels)
                        self.reloadCatalog()
                        self.startProxyServer()
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cc-switch/cc-switch.db"
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
        let imported = try importer.loadCatalog().applyingProtocolOverrides(preferences.protocolOverrides)
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
            rebuildMenu()
            settingsWindowController?.updateProxyStatus(status)
        } else {
            updateStatusItemAppearance()
        }
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
private final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    fileprivate enum SettingsSection: Int, CaseIterable {
        case general
        case models
        case providers

        var title: String {
            switch self {
            case .general:
                return "通用"
            case .models:
                return "模型"
            case .providers:
                return "供应商"
            }
        }

        var symbolName: String {
            switch self {
            case .general:
                return "gearshape"
            case .models:
                return "list.bullet.rectangle"
            case .providers:
                return "network"
            }
        }
    }

    private let sidebarTableView = NSTableView()
    private let contentView = NSView()
    private let modelTableView = NSTableView()
    private let providerTableView = NSTableView()
    private let searchField = NSSearchField()
    private let providerSearchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let providerCountLabel = NSTextField(labelWithString: "")
    private let portField = NSTextField()
    private let codexBaseURLLabel = NSTextField(labelWithString: "")
    private let claudeCodeBaseURLLabel = NSTextField(labelWithString: "")
    private let claudeDesktopBaseURLLabel = NSTextField(labelWithString: "")
    private var actionPopover: NSPopover?
    private var providers: [ImportedProvider]
    private var filteredProviders: [ImportedProvider]
    private var candidates: [ModelCandidate]
    private var routeKeys: [ModelRouteKey]
    private var filteredRouteKeys: [ModelRouteKey]
    private var filteredCustomModels: [CustomModelDefinition]
    private var selectedRouteKeys: Set<ModelRouteKey>
    private var selectedModelAppType: String?
    private var selectedProviderAppType: String?
    private var protocolOverrides: [String: ApiFormat]
    private var customModels: CustomModelState
    private var selectedSection: SettingsSection = .general
    private var preferences: AppPreferences
    private var proxyStatus: ProxyStatus
    private let onSave: (AppPreferences, CustomModelState) -> Void

    init(
        providers: [ImportedProvider],
        candidates: [ModelCandidate],
        routeKeys: [ModelRouteKey],
        customModels: CustomModelState,
        proxyStatus: ProxyStatus,
        preferences: AppPreferences,
        onSave: @escaping (AppPreferences, CustomModelState) -> Void
    ) {
        self.providers = providers
        self.filteredProviders = providers
        self.candidates = candidates
        self.routeKeys = routeKeys
        self.filteredRouteKeys = routeKeys
        self.customModels = customModels
        self.filteredCustomModels = customModels.models
        self.preferences = preferences
        self.selectedRouteKeys = preferences.visibleModels == nil
            ? Set(routeKeys)
            : Set(preferences.visibleRouteKeyList(allRouteKeys: routeKeys))
        self.protocolOverrides = preferences.protocolOverrides
        self.proxyStatus = proxyStatus
        self.onSave = onSave
        self.selectedModelAppType = nil
        self.selectedProviderAppType = nil

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
        buildContent()
        applyFilter()
        applyProviderFilter()
        updateProviderCount()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        providers: [ImportedProvider],
        candidates: [ModelCandidate],
        routeKeys: [ModelRouteKey],
        customModels: CustomModelState,
        proxyStatus: ProxyStatus,
        preferences: AppPreferences
    ) {
        self.providers = providers
        self.filteredProviders = providers
        self.candidates = candidates
        self.routeKeys = routeKeys
        self.filteredRouteKeys = routeKeys
        self.customModels = customModels
        self.filteredCustomModels = customModels.models
        self.preferences = preferences
        self.selectedRouteKeys = preferences.visibleModels == nil
            ? Set(routeKeys)
            : Set(preferences.visibleRouteKeyList(allRouteKeys: routeKeys))
        self.protocolOverrides = preferences.protocolOverrides
        self.proxyStatus = proxyStatus
        if let selectedModelAppType, !routeKeys.contains(where: { $0.appType == selectedModelAppType }) {
            self.selectedModelAppType = nil
        }
        if let selectedProviderAppType, !providers.contains(where: { $0.appType == selectedProviderAppType }) {
            self.selectedProviderAppType = nil
        }
        updatePortField()
        searchField.stringValue = ""
        providerSearchField.stringValue = ""
        applyFilter()
        applyProviderFilter()
        updateProviderCount()
        renderSelectedSection()
    }

    func updateProxyStatus(_ proxyStatus: ProxyStatus) {
        self.proxyStatus = proxyStatus
        if selectedSection == .general {
            renderSelectedSection()
        }
    }

    override func showWindow(_ sender: Any?) {
        updatePortField()
        super.showWindow(sender)
    }

    private func buildContent() {
        guard let window else {
            return
        }

        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let sidebarEffect = NSVisualEffectView()
        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.state = .active
        sidebarEffect.translatesAutoresizingMaskIntoConstraints = false

        configureSidebar()
        let sidebarScrollView = NSScrollView()
        sidebarScrollView.hasVerticalScroller = false
        sidebarScrollView.drawsBackground = false
        sidebarScrollView.borderType = .noBorder
        sidebarScrollView.documentView = sidebarTableView
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarEffect.addSubview(sidebarScrollView)

        let rightPane = NSStackView()
        rightPane.orientation = .vertical
        rightPane.alignment = .leading
        rightPane.spacing = 18
        rightPane.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addArrangedSubview(contentView)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        let cancelButton = button(title: "取消", action: #selector(cancel))
        let saveButton = button(title: "保存更改", action: #selector(save))
        saveButton.keyEquivalent = "\r"
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(saveButton)
        rightPane.addArrangedSubview(footer)
        window.defaultButtonCell = saveButton.cell as? NSButtonCell

        rootView.addSubview(sidebarEffect)
        rootView.addSubview(rightPane)
        NSLayoutConstraint.activate([
            sidebarEffect.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarEffect.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarEffect.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarEffect.widthAnchor.constraint(equalToConstant: 176),
            sidebarScrollView.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor, constant: 10),
            sidebarScrollView.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor, constant: -10),
            sidebarScrollView.topAnchor.constraint(equalTo: sidebarEffect.topAnchor, constant: 18),
            sidebarScrollView.bottomAnchor.constraint(equalTo: sidebarEffect.bottomAnchor, constant: -18),
            rightPane.leadingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor, constant: 24),
            rightPane.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            rightPane.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
            rightPane.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20),
            contentView.widthAnchor.constraint(equalTo: rightPane.widthAnchor),
            footer.widthAnchor.constraint(equalTo: rightPane.widthAnchor)
        ])

        window.contentView = rootView
        sidebarTableView.selectRowIndexes(IndexSet(integer: selectedSection.rawValue), byExtendingSelection: false)
        renderSelectedSection()
    }

    private func configureSidebar() {
        sidebarTableView.headerView = nil
        sidebarTableView.delegate = self
        sidebarTableView.dataSource = self
        sidebarTableView.rowHeight = 32
        sidebarTableView.intercellSpacing = NSSize(width: 0, height: 4)
        sidebarTableView.backgroundColor = .clear
        sidebarTableView.focusRingType = .none
        sidebarTableView.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        sidebarTableView.addTableColumn(column)
    }

    private func renderSelectedSection() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        let sectionView: NSView
        switch selectedSection {
        case .general:
            sectionView = generalView()
        case .models:
            sectionView = modelsView()
        case .providers:
            sectionView = providersView()
        }
        sectionView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sectionView)
        NSLayoutConstraint.activate([
            sectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            sectionView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func generalView() -> NSView {
        let root = pageStack(title: "通用", subtitle: "代理状态与客户端 Base URL")
        root.spacing = 16
        let overview = overviewGrid()
        let overviewSpacer = NSView()
        overviewSpacer.translatesAutoresizingMaskIntoConstraints = false
        overviewSpacer.heightAnchor.constraint(equalToConstant: 10).isActive = true
        root.addArrangedSubview(overviewSpacer)
        root.addArrangedSubview(overview)

        let proxyGroup = settingsGroup()

        portField.alignment = .right
        portField.placeholderString = "17888"
        portField.formatter = portFormatter()
        portField.target = self
        portField.action = #selector(portChanged(_:))
        portField.translatesAutoresizingMaskIntoConstraints = false
        updateBaseURLLabels()

        proxyGroup.addArrangedSubview(settingRow(
            title: "本地代理端口",
            detail: "保存后生效。",
            control: portField,
            verticalPadding: 12
        ))
        root.addArrangedSubview(proxyGroup)

        let endpointGroup = settingsGroup()
        endpointGroup.addArrangedSubview(endpointRow(
            title: "Codex",
            detail: "OpenAI 兼容客户端",
            label: codexBaseURLLabel,
            path: "/codex",
            ccSwitchApp: "codex"
        ))
        endpointGroup.addArrangedSubview(separator())
        endpointGroup.addArrangedSubview(endpointRow(
            title: "Claude Code",
            detail: "Anthropic Messages API 客户端",
            label: claudeCodeBaseURLLabel,
            path: "/claude-code",
            ccSwitchApp: "claude"
        ))
        endpointGroup.addArrangedSubview(separator())
        endpointGroup.addArrangedSubview(endpointRow(
            title: "Claude Desktop",
            detail: "Anthropic Messages API 客户端",
            label: claudeDesktopBaseURLLabel,
            path: "/claude-desktop",
            ccSwitchApp: nil
        ))
        root.addArrangedSubview(endpointGroup)
        root.addArrangedSubview(NSView())

        NSLayoutConstraint.activate([
            overview.widthAnchor.constraint(equalTo: root.widthAnchor),
            proxyGroup.widthAnchor.constraint(equalTo: root.widthAnchor),
            endpointGroup.widthAnchor.constraint(equalTo: root.widthAnchor),
            portField.widthAnchor.constraint(equalToConstant: 104),
            portField.heightAnchor.constraint(equalToConstant: 24)
        ])
        return root
    }

    private func settingsGroup() -> NSStackView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .width
        group.spacing = 0
        group.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        group.wantsLayer = true
        group.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        group.layer?.cornerRadius = 8
        group.layer?.borderWidth = 1
        group.layer?.borderColor = NSColor.separatorColor.cgColor
        group.translatesAutoresizingMaskIntoConstraints = false
        group.setContentHuggingPriority(.required, for: .vertical)
        return group
    }

    private func settingRow(title: String, detail: String, control: NSView, verticalPadding: CGFloat = 8) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: verticalPadding, left: 0, bottom: verticalPadding, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)

        let spacer = NSView()
        row.addArrangedSubview(labels)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        return row
    }

    private func overviewGrid() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.distribution = .fillEqually
        stack.setContentHuggingPriority(.required, for: .vertical)

        let visibleModels = selectedRouteKeys.count
        stack.addArrangedSubview(statCard(
            title: "代理",
            value: proxyStatus.shortTitle,
            detail: "本地监听",
            color: proxyStatus.accentColor
        ))
        stack.addArrangedSubview(statCard(
            title: "供应商",
            value: "\(providers.count)",
            detail: "\(sortedAppTypes().count) 个应用",
            color: .systemBlue
        ))
        stack.addArrangedSubview(statCard(
            title: "模型",
            value: "\(visibleModels)/\(routeKeys.count)",
            detail: "显示在菜单",
            color: .systemGreen
        ))
        stack.addArrangedSubview(statCard(
            title: "覆盖",
            value: "\(protocolOverrides.count)",
            detail: "协议固定",
            color: .systemOrange
        ))
        return stack
    }

    private func statCard(title: String, value: String, detail: String, color: NSColor) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        card.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = color.withAlphaComponent(0.35).cgColor
        card.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        card.addArrangedSubview(titleLabel)
        card.addArrangedSubview(valueLabel)
        card.addArrangedSubview(detailLabel)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 92)
        ])
        return card
    }

    private func endpointRow(title: String, detail: String, label: NSTextField, path: String, ccSwitchApp: String?) -> NSView {
        label.textColor = .secondaryLabelColor
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let importButton = button(title: "导入并切换", action: #selector(importToCcSwitch(_:)))
        importButton.identifier = NSUserInterfaceItemIdentifier(path)
        importButton.toolTip = ccSwitchApp == nil
            ? "cc-switch 当前不支持通过 deeplink 导入 Claude Desktop 供应商"
            : "导入到 cc-switch 并设为当前供应商"
        importButton.isHidden = ccSwitchApp == nil

        let copyButton = button(title: "复制", action: #selector(copyBaseURL(_:)))
        copyButton.identifier = NSUserInterfaceItemIdentifier(path)
        copyButton.toolTip = "复制 Base URL"

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.addArrangedSubview(label)
        controls.addArrangedSubview(importButton)
        controls.addArrangedSubview(copyButton)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let row = settingRow(title: title, detail: detail, control: controls, verticalPadding: 14)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        return row
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    private func modelsView() -> NSView {
        let root = pageStack(title: "模型", subtitle: "按应用管理菜单栏显示")
        _ = ensureSelectedModelAppType()
        applyFilter()

        let split = settingsSplitView(
            sidebar: appSidebar(
                counts: routeKeyCountsByApp(),
                selectedAppType: selectedModelAppType,
                action: #selector(modelAppButtonClicked(_:))
            ),
            content: modelAppPage()
        )
        root.addArrangedSubview(split)
        NSLayoutConstraint.activate([
            split.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        return root
    }

    private func modelAppPage() -> NSView {
        let appType = ensureSelectedModelAppType()
        let appLabel = appType.map(ProviderDisplay.appTypeLabel) ?? "应用"
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = sectionHeader(
            title: appLabel,
            detail: countLabel
        )
        root.addArrangedSubview(header)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索 \(appLabel) 模型"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        controls.addArrangedSubview(searchField)
        controls.addArrangedSubview(NSView())
        controls.addArrangedSubview(capsuleButton(title: "自定义模型", symbolName: "plus", action: #selector(addCustomModel)))
        controls.addArrangedSubview(button(title: "全选当前列表", action: #selector(selectAllModels)))
        controls.addArrangedSubview(button(title: "取消当前列表", action: #selector(selectNoModels)))
        root.addArrangedSubview(controls)

        let scrollView = roundedScrollView()
        let listFrame = framedList(scrollView)
        configureTable(modelTableView, rowHeight: 52)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.minWidth = 220
        if modelTableView.tableColumns.isEmpty {
            modelTableView.addTableColumn(column)
        }
        modelTableView.target = self
        modelTableView.doubleAction = #selector(editCustomModelFromModelRow(_:))

        scrollView.documentView = modelTableView
        root.addArrangedSubview(listFrame)
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            listFrame.widthAnchor.constraint(equalTo: root.widthAnchor),
            listFrame.heightAnchor.constraint(greaterThanOrEqualToConstant: 390)
        ])
        return root
    }

    private func providersView() -> NSView {
        let root = pageStack(title: "供应商", subtitle: "按应用管理协议覆盖")
        _ = ensureSelectedProviderAppType()
        applyProviderFilter()

        let split = settingsSplitView(
            sidebar: appSidebar(
                counts: providerCountsByApp(),
                selectedAppType: selectedProviderAppType,
                action: #selector(providerAppButtonClicked(_:))
            ),
            content: providerAppPage()
        )
        root.addArrangedSubview(split)
        NSLayoutConstraint.activate([
            split.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        return root
    }

    private func providerAppPage() -> NSView {
        let appType = ensureSelectedProviderAppType()
        let appLabel = appType.map(ProviderDisplay.appTypeLabel) ?? "应用"
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = sectionHeader(
            title: appLabel,
            detail: providerCountLabel
        )
        root.addArrangedSubview(header)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        providerSearchField.placeholderString = "搜索 \(appLabel) 供应商"
        providerSearchField.target = self
        providerSearchField.action = #selector(providerSearchChanged(_:))
        providerSearchField.sendsSearchStringImmediately = true
        controls.addArrangedSubview(providerSearchField)
        controls.addArrangedSubview(NSView())
        controls.addArrangedSubview(button(title: "清除当前列表覆盖", action: #selector(clearListedOverrides)))
        root.addArrangedSubview(controls)

        let providerScrollView = roundedScrollView()
        let providerListFrame = framedList(providerScrollView)
        configureTable(providerTableView, rowHeight: 54)
        let providerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        providerColumn.minWidth = 260
        if providerTableView.tableColumns.isEmpty {
            providerTableView.addTableColumn(providerColumn)
        }
        providerScrollView.documentView = providerTableView
        root.addArrangedSubview(providerListFrame)
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            providerSearchField.widthAnchor.constraint(equalToConstant: 240),
            providerListFrame.widthAnchor.constraint(equalTo: root.widthAnchor),
            providerListFrame.heightAnchor.constraint(greaterThanOrEqualToConstant: 390)
        ])
        return root
    }

    private func settingsSplitView(sidebar: NSView, content: NSView) -> NSStackView {
        let split = NSStackView()
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 14
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(content)
        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(equalToConstant: 166),
            sidebar.heightAnchor.constraint(equalTo: content.heightAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 460)
        ])
        return split
    }

    private func appSidebar(
        counts: [String: Int],
        selectedAppType: String?,
        action: Selector
    ) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .width
        group.spacing = 6
        group.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        group.wantsLayer = true
        group.layer?.cornerRadius = 10
        group.layer?.borderWidth = 1
        group.layer?.borderColor = NSColor.separatorColor.cgColor
        group.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82).cgColor
        group.translatesAutoresizingMaskIntoConstraints = false

        let appTypes = sortedAppTypes().filter { (counts[$0] ?? 0) > 0 }
        for (index, appType) in appTypes.enumerated() {
            let button = NSButton(title: "", target: self, action: action)
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.backgroundColor = appType == selectedAppType
                ? ccSwitchBlue.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
            let label = "  \(ProviderDisplay.appTypeLabel(appType))"
            button.attributedTitle = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: appType == selectedAppType ? .semibold : .regular),
                    .foregroundColor: appType == selectedAppType ? ccSwitchBlue : NSColor.labelColor
                ]
            )
            group.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: group.widthAnchor, constant: -20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        group.addArrangedSubview(NSView())
        return group
    }

    private func sectionHeader(title: String, detail: NSTextField) -> NSStackView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(detail)
        header.addArrangedSubview(NSView())
        return header
    }

    private func sortedAppTypes() -> [String] {
        Array(Set(modelRouteKeys().map(\.appType) + providers.map(\.appType))).sorted {
            ProviderDisplay.appTypeLabel($0).localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
    }

    private func ensureSelectedModelAppType() -> String? {
        let routeKeys = modelRouteKeys()
        let appTypes = sortedAppTypes().filter { appType in
            routeKeys.contains { $0.appType == appType }
        }
        if let selectedModelAppType, appTypes.contains(selectedModelAppType) {
            return selectedModelAppType
        }
        selectedModelAppType = appTypes.first
        return selectedModelAppType
    }

    private func ensureSelectedProviderAppType() -> String? {
        let appTypes = sortedAppTypes().filter { appType in
            providers.contains { $0.appType == appType }
        }
        if let selectedProviderAppType, appTypes.contains(selectedProviderAppType) {
            return selectedProviderAppType
        }
        selectedProviderAppType = appTypes.first
        return selectedProviderAppType
    }

    private func routeKeyCountsByApp() -> [String: Int] {
        Dictionary(grouping: modelRouteKeys(), by: \.appType).mapValues(\.count)
    }

    private func providerCountsByApp() -> [String: Int] {
        Dictionary(grouping: providers, by: \.appType).mapValues(\.count)
    }

    private var ccSwitchBlue: NSColor {
        NSColor(calibratedRed: 0.231, green: 0.510, blue: 0.965, alpha: 1)
    }

    private func pageStack(title: String, subtitle: String) -> NSStackView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(subtitleLabel)
        header.addArrangedSubview(NSView())
        root.addArrangedSubview(header)
        root.addArrangedSubview(pageDivider())
        return root
    }

    private func pageDivider() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    private func framedList(_ scrollView: NSScrollView) -> NSView {
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 8
        frame.layer?.masksToBounds = true
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = NSColor.separatorColor.cgColor
        frame.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -1),
            scrollView.topAnchor.constraint(equalTo: frame.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -1)
        ])
        return frame
    }

    private func roundedScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private func portFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }

    private func configureTable(_ tableView: NSTableView, rowHeight: CGFloat) {
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.focusRingType = .none
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func capsuleButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let button = NSButton(title: title, image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.contentTintColor = .systemBlue
        return button
    }

    private func isVisible(_ routeKey: ModelRouteKey) -> Bool {
        selectedRouteKeys.contains(routeKey)
    }

    private func applyFilter() {
        let appType = ensureSelectedModelAppType()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredRouteKeys = modelRouteKeys().filter { key in
            let appMatches = appType == nil || key.appType == appType
            let queryMatches = query.isEmpty || modelSearchText(for: key).localizedCaseInsensitiveContains(query)
            return appMatches && queryMatches
        }
        modelTableView.reloadData()
        updateCount()
    }

    private func applyProviderFilter() {
        let appType = ensureSelectedProviderAppType()
        let query = providerSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredProviders = providers.filter { provider in
            let appMatches = appType == nil || provider.appType == appType
            let queryMatches = query.isEmpty
                || provider.name.localizedCaseInsensitiveContains(query)
                || provider.id.localizedCaseInsensitiveContains(query)
                || (provider.baseURL?.localizedCaseInsensitiveContains(query) ?? false)
            return appMatches && queryMatches
        }
        providerTableView.reloadData()
        updateProviderCount()
    }

    private func updateCount() {
        let appType = ensureSelectedModelAppType()
        let appKeys = modelRouteKeys().filter { appType == nil || $0.appType == appType }
        let visibleInApp = appKeys.filter { selectedRouteKeys.contains($0) }.count
        let selectedText = "已显示 \(visibleInApp)/\(appKeys.count) 个模型"
        if filteredRouteKeys.count == appKeys.count {
            countLabel.stringValue = "\(selectedText)"
        } else {
            countLabel.stringValue = "\(selectedText) · 匹配 \(filteredRouteKeys.count) 个"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == sidebarTableView {
            return SettingsSection.allCases.count
        }
        if tableView == providerTableView {
            return filteredProviders.count
        }
        return filteredRouteKeys.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView == sidebarTableView {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == sidebarTableView {
            guard let section = SettingsSection(rawValue: row) else {
                return nil
            }
            let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsSidebarCell
                ?? SettingsSidebarCell(identifier: identifier)
            cell.configure(section)
            return cell
        }

        if tableView == providerTableView {
            guard row < filteredProviders.count else {
                return nil
            }
            let identifier = NSUserInterfaceItemIdentifier("ProviderProtocolCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ProviderProtocolCell
                ?? ProviderProtocolCell(identifier: identifier, target: self, action: #selector(protocolChanged(_:)))
            let provider = filteredProviders[row]
            cell.configure(
                provider: provider,
                override: protocolOverrides[provider.ref.description],
                tag: row
            )
            return cell
        }

        guard row < filteredRouteKeys.count else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("ModelToggleCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ModelToggleCell
            ?? ModelToggleCell(
                identifier: identifier,
                toggleTarget: self,
                toggleAction: #selector(toggleModel(_:)),
                deleteTarget: self,
                deleteAction: #selector(deleteCustomModelFromRow(_:))
            )
        let routeKey = filteredRouteKeys[row]
        cell.configure(
            routeKey: routeKey,
            detail: modelDetailText(for: routeKey),
            isSelected: isVisible(routeKey),
            isCustom: customModel(for: routeKey) != nil,
            tag: row
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard
            notification.object as? NSTableView == sidebarTableView,
            let section = SettingsSection(rawValue: sidebarTableView.selectedRow)
        else {
            return
        }
        selectedSection = section
        renderSelectedSection()
    }

    @objc private func selectAllModels() {
        selectedRouteKeys.formUnion(filteredRouteKeys)
        modelTableView.reloadData()
        updateCount()
    }

    @objc private func selectNoModels() {
        selectedRouteKeys.subtract(filteredRouteKeys)
        modelTableView.reloadData()
        updateCount()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter()
    }

    @objc private func addCustomModel() {
        presentCustomModelEditor(nil)
    }

    @objc private func editCustomModel() {
        guard
            !filteredCustomModels.isEmpty,
            let routeKey = filteredRouteKeys.first(where: { customModel(for: $0) != nil }),
            let model = customModel(for: routeKey)
        else {
            NSSound.beep()
            return
        }
        presentCustomModelEditor(model)
    }

    @objc private func deleteCustomModel() {
        guard
            !filteredCustomModels.isEmpty,
            let routeKey = filteredRouteKeys.first(where: { customModel(for: $0) != nil }),
            let model = customModel(for: routeKey)
        else {
            NSSound.beep()
            return
        }
        customModels.models.removeAll { $0.id == model.id }
        filteredCustomModels = customModels.models
        selectedRouteKeys.remove(ModelRouteKey(appType: model.appType, logicalModel: model.name))
        renderSelectedSection()
    }

    @objc private func modelAppButtonClicked(_ sender: NSButton) {
        let routeKeys = modelRouteKeys()
        let appTypes = sortedAppTypes().filter { appType in
            routeKeys.contains { $0.appType == appType }
        }
        guard sender.tag >= 0, sender.tag < appTypes.count else {
            return
        }
        selectedModelAppType = appTypes[sender.tag]
        searchField.stringValue = ""
        applyFilter()
        renderSelectedSection()
    }

    @objc private func providerAppButtonClicked(_ sender: NSButton) {
        let appTypes = sortedAppTypes().filter { appType in
            providers.contains { $0.appType == appType }
        }
        guard sender.tag >= 0, sender.tag < appTypes.count else {
            return
        }
        selectedProviderAppType = appTypes[sender.tag]
        providerSearchField.stringValue = ""
        applyProviderFilter()
        renderSelectedSection()
    }

    @objc private func toggleModel(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < filteredRouteKeys.count else {
            return
        }
        let routeKey = filteredRouteKeys[sender.tag]
        if sender.state == .on {
            selectedRouteKeys.insert(routeKey)
        } else {
            selectedRouteKeys.remove(routeKey)
        }
        modelTableView.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integer: 0))
        updateCount()
    }

    @objc private func deleteCustomModelFromRow(_ sender: NSButton) {
        guard
            sender.tag >= 0,
            sender.tag < filteredRouteKeys.count,
            let model = customModel(for: filteredRouteKeys[sender.tag])
        else {
            NSSound.beep()
            return
        }
        customModels.models.removeAll { $0.id == model.id }
        filteredCustomModels = customModels.models
        selectedRouteKeys.remove(ModelRouteKey(appType: model.appType, logicalModel: model.name))
        applyFilter()
        renderSelectedSection()
    }

    @objc private func editCustomModelFromModelRow(_ sender: NSTableView) {
        guard
            sender.clickedRow >= 0,
            sender.clickedRow < filteredRouteKeys.count,
            let model = customModel(for: filteredRouteKeys[sender.clickedRow])
        else {
            return
        }
        presentCustomModelEditor(model)
    }

    @objc private func providerSearchChanged(_ sender: NSSearchField) {
        applyProviderFilter()
    }

    private func presentCustomModelEditor(_ existing: CustomModelDefinition?) {
        let editor = CustomModelEditorController(
            model: existing,
            candidates: baseModelCandidates()
        )
        guard
            let window = window,
            let edited = editor.runModal(parent: window)
        else {
            return
        }

        if let existing {
            if let index = customModels.models.firstIndex(where: { $0.id == existing.id }) {
                customModels.models[index] = edited
            }
            selectedRouteKeys.remove(ModelRouteKey(appType: existing.appType, logicalModel: existing.name))
        } else {
            customModels.models.append(edited)
        }

        let routeKey = ModelRouteKey(appType: edited.appType, logicalModel: edited.name)
        selectedRouteKeys.insert(routeKey)
        selectedModelAppType = edited.appType
        searchField.stringValue = ""
        filteredCustomModels = customModels.models
        renderSelectedSection()
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

    private func customModelDetail(_ model: CustomModelDefinition) -> String {
        let targetCount = model.targets.count
        let selected = model.selectedTarget.flatMap { target in
            candidates.first {
                $0.appType == target.routeKey.appType
                    && $0.logicalModel == target.routeKey.logicalModel
                    && $0.providerRef == target.providerRef
            }
        }
        let selectedText = selected.map {
            "\($0.logicalModel) → \($0.providerName)"
        } ?? "未选择有效目标"
        return "\(ProviderDisplay.appTypeLabel(model.appType)) · \(targetCount) 个目标 · 当前：\(selectedText)"
    }

    private func customModel(for routeKey: ModelRouteKey) -> CustomModelDefinition? {
        customModels.models.first {
            $0.appType == routeKey.appType && $0.name == routeKey.logicalModel
        }
    }

    @objc private func protocolChanged(_ sender: NSPopUpButton) {
        guard sender.tag >= 0, sender.tag < filteredProviders.count else {
            return
        }
        let provider = filteredProviders[sender.tag]
        guard let selected = sender.selectedItem?.representedObject as? String else {
            return
        }
        if selected == "inherit" {
            protocolOverrides.removeValue(forKey: provider.ref.description)
        } else if let format = ApiFormat(rawValue: selected) {
            protocolOverrides[provider.ref.description] = format
        }
        updateProviderCount()
    }

    @objc private func clearListedOverrides() {
        for provider in filteredProviders {
            protocolOverrides.removeValue(forKey: provider.ref.description)
        }
        providerTableView.reloadData()
        updateProviderCount()
    }

    @objc private func portChanged(_ sender: NSTextField) {
        updateBaseURLLabels()
    }

    @objc private func copyBaseURL(_ sender: NSButton) {
        updateBaseURLLabels()
        let path = sender.identifier?.rawValue ?? "/codex"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseURL(path: path), forType: .string)
        showActionMessage("已复制", from: sender)
    }

    @objc private func importToCcSwitch(_ sender: NSButton) {
        updateBaseURLLabels()
        let path = sender.identifier?.rawValue ?? "/codex"
        guard let app = ccSwitchApp(for: path) else {
            NSSound.beep()
            showActionMessage("不支持导入", from: sender, width: 104)
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
            showActionMessage("已打开 cc-switch", from: sender, width: 132)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            showActionMessage("已复制导入链接", from: sender, width: 132)
        }
    }

    private func showActionMessage(_ message: String, from sender: NSButton, width: CGFloat = 88) {
        actionPopover?.close()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 8
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: width),
            contentView.heightAnchor.constraint(equalToConstant: 36),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        let controller = NSViewController()
        controller.view = contentView

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: width, height: 36)
        popover.contentViewController = controller
        actionPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak popover] in
            popover?.close()
            if self?.actionPopover === popover {
                self?.actionPopover = nil
            }
        }
    }

    private func updateProviderCount() {
        let appOverrides = filteredProviders.filter { protocolOverrides[$0.ref.description] != nil }.count
        providerCountLabel.stringValue = "\(filteredProviders.count) 个供应商 · \(appOverrides) 个覆盖"
    }

    @objc private func cancel() {
        close()
    }

    @objc private func save() {
        let saveRouteKeys = Set(modelRouteKeys())
        let visibleModels = selectedRouteKeys == saveRouteKeys
            ? nil
            : Set(selectedRouteKeys.map(\.description))
        guard let port = UInt16(portField.stringValue), port > 0 else {
            NSSound.beep()
            selectedSection = .general
            sidebarTableView.selectRowIndexes(IndexSet(integer: selectedSection.rawValue), byExtendingSelection: false)
            renderSelectedSection()
            return
        }
        onSave(AppPreferences(
            visibleModels: visibleModels,
            protocolOverrides: protocolOverrides,
            port: port
        ), customModels)
        close()
    }

    private func updatePortField() {
        portField.stringValue = "\(preferences.normalizedPort)"
        updateBaseURLLabels()
    }

    private func updateBaseURLLabels() {
        codexBaseURLLabel.stringValue = baseURL(path: "/codex")
        claudeCodeBaseURLLabel.stringValue = baseURL(path: "/claude-code")
        claudeDesktopBaseURLLabel.stringValue = baseURL(path: "/claude-desktop")
    }

    private func baseURL(path: String) -> String {
        let port = UInt16(portField.stringValue) ?? 17888
        return "http://127.0.0.1:\(port)\(path)"
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

    private func defaultModel(forAppType appType: String) -> String? {
        let appKeys = modelRouteKeys().filter { $0.appType == appType }
        let visibleKeys = appKeys.filter { selectedRouteKeys.contains($0) }
        return preferredDefaultModel(from: visibleKeys) ?? preferredDefaultModel(from: appKeys)
    }

    private func preferredDefaultModel(from keys: [ModelRouteKey]) -> String? {
        if let exact = keys.first(where: { $0.logicalModel == "gpt-5.5" || $0.logicalModel == "auto" }) {
            return exact.logicalModel
        }
        return keys.first?.logicalModel
    }

    private func routeCandidates(for routeKey: ModelRouteKey) -> [ModelCandidate] {
        baseModelCandidates()
            .filter { $0.appType == routeKey.appType && $0.logicalModel == routeKey.logicalModel }
            .sorted { lhs, rhs in
                lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
            }
    }

    private func upstreamNames(for routeKey: ModelRouteKey) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for candidate in routeCandidates(for: routeKey) {
            let display = upstreamDisplayName(candidate)
            guard !seen.contains(display) else {
                continue
            }
            seen.insert(display)
            names.append(display)
        }
        return names
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

    private func modelDetailText(for routeKey: ModelRouteKey) -> String {
        if let model = customModel(for: routeKey) {
            return customModelDetail(model)
        }
        let appLabel = ProviderDisplay.appTypeLabel(routeKey.appType)
        let upstreams = upstreamNames(for: routeKey)
        guard !upstreams.isEmpty, upstreams != [routeKey.logicalModel] else {
            return appLabel
        }
        return "\(appLabel) · 上游模型：\(upstreams.joined(separator: "、"))"
    }

    private func modelSearchText(for routeKey: ModelRouteKey) -> String {
        let customText = customModel(for: routeKey).map(customModelDetail) ?? ""
        let candidateText = routeCandidates(for: routeKey).map { candidate in
            [
                candidate.providerName,
                candidate.upstreamModel,
                candidate.label ?? ""
            ].joined(separator: " ")
        }.joined(separator: " ")
        return [
            routeKey.logicalModel,
            ProviderDisplay.appTypeLabel(routeKey.appType),
            customText,
            candidateText
        ].joined(separator: " ")
    }

    private func modelRouteKeys() -> [ModelRouteKey] {
        let baseRouteKeys = baseModelCandidates().map(\.routeKey)
        return Array(Set(baseRouteKeys).union(customModels.models.map {
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

private final class SettingsSidebarCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(_ section: SettingsWindowController.SettingsSection) {
        iconView.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil)
        titleLabel.stringValue = section.title
    }
}

private final class ModelToggleCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let detailLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "自定义")
    private let deleteButton = NSButton()
    private let backgroundView = NSView()
    private let separatorView = NSBox()

    init(
        identifier: NSUserInterfaceItemIdentifier,
        toggleTarget: AnyObject,
        toggleAction: Selector,
        deleteTarget: AnyObject,
        deleteAction: Selector
    ) {
        super.init(frame: .zero)
        self.identifier = identifier
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        checkbox.target = toggleTarget
        checkbox.action = toggleAction
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.lineBreakMode = .byTruncatingMiddle
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 5
        badgeView.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .systemOrange
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)

        deleteButton.target = deleteTarget
        deleteButton.action = deleteAction
        deleteButton.bezelStyle = .inline
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
        deleteButton.imagePosition = .imageOnly
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.toolTip = "删除自定义模型"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        separatorView.boxType = .separator
        separatorView.alphaValue = 0.35
        separatorView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backgroundView)
        addSubview(separatorView)
        backgroundView.addSubview(checkbox)
        backgroundView.addSubview(detailLabel)
        backgroundView.addSubview(badgeView)
        backgroundView.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            checkbox.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -8),
            checkbox.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: 20),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 1),
            badgeView.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            badgeView.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            badgeView.heightAnchor.constraint(equalToConstant: 18),
            badgeView.widthAnchor.constraint(equalToConstant: 44),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -6),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24),
            separatorView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            separatorView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(routeKey: ModelRouteKey, detail: String, isSelected: Bool, isCustom: Bool, tag: Int) {
        checkbox.title = routeKey.logicalModel
        checkbox.toolTip = "\(routeKey.description)\n\(detail)"
        checkbox.tag = tag
        checkbox.state = isSelected ? .on : .off
        backgroundView.layer?.backgroundColor = isSelected
            ? NSColor.systemBlue.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        badgeView.isHidden = !isCustom
        deleteButton.isHidden = !isCustom
        deleteButton.tag = tag
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
    }
}

private final class ProviderProtocolCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()
    private let badgeTextLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.identifier = identifier

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        labels.addArrangedSubview(nameLabel)

        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 6
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 5
        badgeView.translatesAutoresizingMaskIntoConstraints = false

        badgeTextLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeTextLabel.alignment = .center
        badgeTextLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeTextLabel)

        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.textColor = .secondaryLabelColor
        formatLabel.lineBreakMode = .byTruncatingTail

        metaRow.addArrangedSubview(badgeView)
        metaRow.addArrangedSubview(formatLabel)
        labels.addArrangedSubview(metaRow)

        urlLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        urlLabel.textColor = .tertiaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        labels.addArrangedSubview(urlLabel)

        popup.target = target
        popup.action = action
        popup.translatesAutoresizingMaskIntoConstraints = false
        addProtocolItems()

        addSubview(labels)
        addSubview(popup)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -12),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 170),
            badgeView.heightAnchor.constraint(equalToConstant: 18),
            badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
            badgeTextLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 6),
            badgeTextLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -6),
            badgeTextLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(provider: ImportedProvider, override: ApiFormat?, tag: Int) {
        nameLabel.stringValue = provider.name
        badgeTextLabel.stringValue = ProviderDisplay.appTypeLabel(provider.appType)
        badgeTextLabel.textColor = appAccentColor(provider.appType)
        badgeView.layer?.backgroundColor = appAccentColor(provider.appType).withAlphaComponent(0.10).cgColor
        formatLabel.stringValue = override == nil
            ? "检测到：\(provider.apiFormat.rawValue)"
            : "已覆盖 · 检测到 \(provider.apiFormat.rawValue)"
        urlLabel.stringValue = provider.baseURL ?? "未检测到 Base URL"
        popup.tag = tag
        let selected = override?.rawValue ?? "inherit"
        selectItem(representedObject: selected)
    }

    private func appAccentColor(_ appType: String) -> NSColor {
        switch appType {
        case "codex":
            return .systemBlue
        case "claude":
            return .systemPurple
        case "claude-desktop":
            return .systemTeal
        case "gemini":
            return .systemOrange
        default:
            return .secondaryLabelColor
        }
    }

    private func addProtocolItems() {
        popup.removeAllItems()
        addItem("继承检测结果", representedObject: "inherit")
        popup.menu?.addItem(.separator())
        addItem("OpenAI Responses", representedObject: ApiFormat.openaiResponses.rawValue)
        addItem("OpenAI Chat", representedObject: ApiFormat.openaiChat.rawValue)
        addItem("Anthropic", representedObject: ApiFormat.anthropic.rawValue)
        addItem("Gemini Native", representedObject: ApiFormat.geminiNative.rawValue)
    }

    private func addItem(_ title: String, representedObject: String) {
        popup.addItem(withTitle: title)
        popup.lastItem?.representedObject = representedObject
    }

    private func selectItem(representedObject: String) {
        for item in popup.itemArray where item.representedObject as? String == representedObject {
            popup.select(item)
            return
        }
        popup.selectItem(at: 0)
    }
}

@MainActor
private final class CustomModelEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let nameField = NSTextField()
    private let appPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetTableView = NSTableView()
    private let candidates: [ModelCandidate]
    private var filteredCandidates: [ModelCandidate] = []
    private var selectedTargetIDs = Set<String>()
    private var result: CustomModelDefinition?
    private let editingID: UUID?
    private let existingTargetsByKey: [String: CustomModelTarget]

    init(model: CustomModelDefinition?, candidates: [ModelCandidate]) {
        self.candidates = candidates.sorted {
            [$0.appType, $0.logicalModel, $0.providerName].joined(separator: "\u{0}")
                .localizedStandardCompare([$1.appType, $1.logicalModel, $1.providerName].joined(separator: "\u{0}")) == .orderedAscending
        }
        self.editingID = model?.id
        self.existingTargetsByKey = Dictionary(
            uniqueKeysWithValues: (model?.targets ?? []).map { ("\($0.routeKey.description)|\($0.providerRef.description)", $0) }
        )
        super.init()
        buildContent(model: model)
    }

    func runModal(parent: NSWindow) -> CustomModelDefinition? {
        panel.center()
        parent.beginSheet(panel) { _ in }
        NSApp.runModal(for: panel)
        parent.endSheet(panel)
        return result
    }

    private func buildContent(model: CustomModelDefinition?) {
        panel.title = model == nil ? "新增自定义模型" : "编辑自定义模型"

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = editorHeader(
            title: model == nil ? "新增自定义模型" : "编辑自定义模型",
            subtitle: "为模型名选择应用，并从现有模型里勾选一个或多个转发目标。"
        )
        root.addArrangedSubview(header)

        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)

        nameField.placeholderString = "例如 customer_model"
        nameField.stringValue = model?.name ?? ""

        let appTypes = Array(Set(candidates.map(\.appType))).sorted {
            ProviderDisplay.appTypeLabel($0).localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
        appPopup.removeAllItems()
        for appType in appTypes {
            appPopup.addItem(withTitle: ProviderDisplay.appTypeLabel(appType))
            appPopup.lastItem?.representedObject = appType
        }
        if let appType = model?.appType,
           let index = appPopup.itemArray.firstIndex(where: { $0.representedObject as? String == appType }) {
            appPopup.selectItem(at: index)
        }
        appPopup.target = self
        appPopup.action = #selector(appChanged)

        let modelRow = NSStackView()
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 20
        modelRow.translatesAutoresizingMaskIntoConstraints = false
        modelRow.addArrangedSubview(editorFieldColumn(
            title: "模型名",
            control: nameField,
            minWidth: 280
        ))
        modelRow.addArrangedSubview(editorFieldColumn(
            title: "应用",
            control: appPopup,
            minWidth: 180
        ))
        modelRow.addArrangedSubview(NSView())

        let targetSectionHeader = editorSectionHeader(
            title: "转发目标",
            subtitle: "可勾选多个现有模型，当前目标用于默认转发。"
        )

        targetPopup.removeAllItems()

        configureTargetTable()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = targetTableView

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 14
        body.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 0, right: 16)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(modelRow)
        body.addArrangedSubview(targetSectionHeader)
        body.addArrangedSubview(formRow(title: "当前目标", control: targetPopup))
        body.addArrangedSubview(scrollView)
        root.addArrangedSubview(body)
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 280)
        ])

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.addArrangedSubview(NSView())
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(saveButton)
        root.addArrangedSubview(footer)

        panel.contentView = root

        selectedTargetIDs = Set(model?.targets.map(targetID) ?? [])
        updateFilteredCandidates()
        if let selectedTarget = model?.selectedTarget {
            selectTargetPopupItem(id: targetID(selectedTarget))
        }
    }

    private func configureTargetTable() {
        targetTableView.headerView = nil
        targetTableView.delegate = self
        targetTableView.dataSource = self
        targetTableView.selectionHighlightStyle = .none
        targetTableView.rowHeight = 40
        targetTableView.intercellSpacing = NSSize(width: 0, height: 2)
        targetTableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target")))
    }

    private func formRow(title: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        row.addArrangedSubview(NSView())
        return row
    }

    private func editorFieldColumn(title: String, control: NSView, minWidth: CGFloat) -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor

        column.addArrangedSubview(label)
        column.addArrangedSubview(control)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        return column
    }

    private func editorHeader(title: String, subtitle: String) -> NSStackView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(subtitleLabel)
        header.addArrangedSubview(NSView())
        return header
    }

    private func editorSectionHeader(title: String, subtitle: String) -> NSStackView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(subtitleLabel)
        header.addArrangedSubview(NSView())
        return header
    }

    private func currentAppType() -> String? {
        appPopup.selectedItem?.representedObject as? String
    }

    @objc private func appChanged() {
        selectedTargetIDs.removeAll()
        updateFilteredCandidates()
    }

    private func updateFilteredCandidates() {
        let appType = currentAppType()
        filteredCandidates = candidates.filter { candidate in
            appType == nil || candidate.appType == appType
        }
        targetTableView.reloadData()
        rebuildTargetPopup()
    }

    private func rebuildTargetPopup() {
        let previous = targetPopup.selectedItem?.representedObject as? String
        targetPopup.removeAllItems()
        for candidate in filteredCandidates where selectedTargetIDs.contains(targetID(candidate)) {
            targetPopup.addItem(withTitle: targetTitle(candidate))
            targetPopup.lastItem?.representedObject = targetID(candidate)
        }
        if let previous {
            selectTargetPopupItem(id: previous)
        }
    }

    private func selectTargetPopupItem(id: String) {
        if let index = targetPopup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
            targetPopup.selectItem(at: index)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCandidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredCandidates.count else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("CustomModelTargetCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CustomModelTargetCell
            ?? CustomModelTargetCell(identifier: identifier, target: self, action: #selector(toggleTarget(_:)))
        let candidate = filteredCandidates[row]
        cell.configure(
            title: targetTitle(candidate),
            detail: "\(ProviderDisplay.appTypeLabel(candidate.appType)) · \(candidate.upstreamModel)",
            isSelected: selectedTargetIDs.contains(targetID(candidate)),
            tag: row
        )
        return cell
    }

    @objc private func toggleTarget(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < filteredCandidates.count else {
            return
        }
        let id = targetID(filteredCandidates[sender.tag])
        if sender.state == .on {
            selectedTargetIDs.insert(id)
        } else {
            selectedTargetIDs.remove(id)
        }
        targetTableView.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integer: 0))
        rebuildTargetPopup()
    }

    @objc private func cancel() {
        result = nil
        NSApp.stopModal()
        panel.close()
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let appType = currentAppType(), !selectedTargetIDs.isEmpty else {
            NSSound.beep()
            return
        }
        let selectedCandidates = filteredCandidates.filter { selectedTargetIDs.contains(targetID($0)) }
        let targets = selectedCandidates.map {
            existingTargetsByKey[targetID($0)] ?? CustomModelTarget(routeKey: $0.routeKey, providerRef: $0.providerRef)
        }
        let selectedPopupID = targetPopup.selectedItem?.representedObject as? String
        let selectedTargetID = zip(selectedCandidates, targets).first {
            targetID($0.0) == selectedPopupID
        }?.1.id ?? targets.first?.id
        result = CustomModelDefinition(
            id: editingID ?? UUID(),
            appType: appType,
            name: name,
            targets: targets,
            selectedTargetID: selectedTargetID
        )
        NSApp.stopModal()
        panel.close()
    }

    private func targetID(_ target: CustomModelTarget) -> String {
        "\(target.routeKey.description)|\(target.providerRef.description)"
    }

    private func targetID(_ candidate: ModelCandidate) -> String {
        "\(candidate.routeKey.description)|\(candidate.providerRef.description)"
    }

    private func targetTitle(_ candidate: ModelCandidate) -> String {
        "\(candidate.logicalModel) · \(candidate.providerName)"
    }
}

private final class CustomModelTargetCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let detailLabel = NSTextField(labelWithString: "")
    private let backgroundView = NSView()

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.identifier = identifier
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        checkbox.target = target
        checkbox.action = action
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.lineBreakMode = .byTruncatingMiddle
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)
        backgroundView.addSubview(checkbox)
        backgroundView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            checkbox.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 8),
            checkbox.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -8),
            checkbox.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: 20),
            detailLabel.trailingAnchor.constraint(equalTo: checkbox.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: checkbox.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String, detail: String, isSelected: Bool, tag: Int) {
        checkbox.title = title
        checkbox.state = isSelected ? .on : .off
        checkbox.tag = tag
        detailLabel.stringValue = detail
        toolTip = "\(title)\n\(detail)"
        backgroundView.layer?.backgroundColor = isSelected
            ? NSColor.systemBlue.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
