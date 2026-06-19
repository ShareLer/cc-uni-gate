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
    private lazy var routeStore = RouteStore(fileURL: defaultRouteStoreURL())
    private lazy var preferencesStore = PreferencesStore(fileURL: defaultPreferencesStoreURL())
    private var settingsWindowController: SettingsWindowController?
    private var proxyServer: LocalProxyServer?
    private lazy var importer = CcSwitchImporter(dbPath: defaultCcSwitchDBPath())
    private var proxyStatus: ProxyStatus = .starting
    private var recentEvents: [ProxyEvent] = []
    private let logger = FileLogger()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "API"
        statusItem.button?.toolTip = "CC Uni Gate"
        do {
            try AppPaths.migrateLegacyApplicationSupportDirectory()
        } catch {
            showError(error)
        }
        reloadCatalog()
        startProxyServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        proxyServer?.stop()
    }

    private func reloadCatalog() {
        do {
            preferences = try preferencesStore.load()
            catalog = try importer.loadCatalog().applyingProtocolOverrides(preferences.protocolOverrides)
            routes = try routeStore.load(catalog: catalog)
            rebuildMenu()
        } catch {
            rebuildErrorMenu(error)
        }
    }

    private func startProxyServer() {
        do {
            proxyServer?.stop()
            let server = LocalProxyServer(port: currentProxyPort(), runtime: self)
            try server.start()
            proxyServer = server
            proxyStatus = .running
            recordEvent(.info, "代理正在监听 \(managerBaseURL())")
            rebuildMenu()
        } catch {
            proxyStatus = .failed(error.localizedDescription)
            recordEvent(.error, "代理启动失败：\(error.localizedDescription)")
            rebuildMenu()
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
                proxyStatus: proxyStatus,
                preferences: preferences,
                onSave: { [weak self] preferences in
                    guard let self else {
                        return
                    }
                    do {
                        self.preferences = preferences
                        try self.preferencesStore.save(preferences)
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
}

extension AppDelegate: LocalProxyRuntime {
    func proxySnapshot() -> ProxyRuntimeSnapshot {
        ProxyRuntimeSnapshot(catalog: catalog, routes: routes)
    }

    func reloadProxyRuntime() throws -> ProxyRuntimeSnapshot {
        preferences = try preferencesStore.load()
        catalog = try importer.loadCatalog().applyingProtocolOverrides(preferences.protocolOverrides)
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
}

enum ProxyStatus {
    case starting
    case running
    case failed(String)

    func title(port: UInt16) -> String {
        switch self {
        case .starting:
            return "代理端口: \(port) | 启动中"
        case .running:
            return "代理端口: \(port) | 运行中"
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
        case .failed:
            return "失败"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .starting:
            return .systemOrange
        case .running:
            return .systemGreen
        case .failed:
            return .systemRed
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
    private let modelAppFilter = NSSegmentedControl()
    private let providerAppFilter = NSSegmentedControl()
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
    private var selectedRouteKeys: Set<ModelRouteKey>
    private var selectedModelAppType: String?
    private var selectedProviderAppType: String?
    private var protocolOverrides: [String: ApiFormat]
    private var selectedSection: SettingsSection = .general
    private var preferences: AppPreferences
    private var proxyStatus: ProxyStatus
    private let onSave: (AppPreferences) -> Void

    init(
        providers: [ImportedProvider],
        candidates: [ModelCandidate],
        routeKeys: [ModelRouteKey],
        proxyStatus: ProxyStatus,
        preferences: AppPreferences,
        onSave: @escaping (AppPreferences) -> Void
    ) {
        self.providers = providers
        self.filteredProviders = providers
        self.candidates = candidates
        self.routeKeys = routeKeys
        self.filteredRouteKeys = routeKeys
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
        proxyStatus: ProxyStatus,
        preferences: AppPreferences
    ) {
        self.providers = providers
        self.filteredProviders = providers
        self.candidates = candidates
        self.routeKeys = routeKeys
        self.filteredRouteKeys = routeKeys
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
        let overview = overviewGrid()
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
            control: portField
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

    private func settingRow(title: String, detail: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
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

        let row = settingRow(title: title, detail: detail, control: controls)
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
        let root = pageStack(title: "模型", subtitle: "菜单栏显示控制")
        let countBar = appCountBar(totalTitle: "\(routeKeys.count) 个模型", counts: routeKeyCountsByApp(), unit: "个")
        root.addArrangedSubview(countBar)
        root.addArrangedSubview(countLabel)
        configureAppFilter(modelAppFilter, selectedAppType: selectedModelAppType, action: #selector(modelAppFilterChanged(_:)))
        root.addArrangedSubview(modelAppFilter)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索模型"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        controls.addArrangedSubview(searchField)
        let controlSpacer = NSView()
        controls.addArrangedSubview(controlSpacer)
        controls.addArrangedSubview(button(title: "全选当前列表", action: #selector(selectAllModels)))
        controls.addArrangedSubview(button(title: "取消当前列表", action: #selector(selectNoModels)))
        root.addArrangedSubview(controls)

        let scrollView = roundedScrollView()
        configureTable(modelTableView, rowHeight: 44)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.minWidth = 220
        if modelTableView.tableColumns.isEmpty {
            modelTableView.addTableColumn(column)
        }

        scrollView.documentView = modelTableView
        root.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            countBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            modelAppFilter.widthAnchor.constraint(equalTo: root.widthAnchor),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 330)
        ])
        return root
    }

    private func providersView() -> NSView {
        let root = pageStack(title: "供应商", subtitle: "协议覆盖")
        let countBar = appCountBar(totalTitle: "\(providers.count) 个供应商", counts: providerCountsByApp(), unit: "个")
        root.addArrangedSubview(countBar)
        root.addArrangedSubview(providerCountLabel)
        configureAppFilter(providerAppFilter, selectedAppType: selectedProviderAppType, action: #selector(providerAppFilterChanged(_:)))
        root.addArrangedSubview(providerAppFilter)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        providerSearchField.placeholderString = "搜索供应商"
        providerSearchField.target = self
        providerSearchField.action = #selector(providerSearchChanged(_:))
        providerSearchField.sendsSearchStringImmediately = true
        controls.addArrangedSubview(providerSearchField)
        controls.addArrangedSubview(NSView())
        controls.addArrangedSubview(button(title: "清除当前列表覆盖", action: #selector(clearListedOverrides)))
        root.addArrangedSubview(controls)

        let providerScrollView = roundedScrollView()
        configureTable(providerTableView, rowHeight: 54)
        let providerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        providerColumn.minWidth = 260
        if providerTableView.tableColumns.isEmpty {
            providerTableView.addTableColumn(providerColumn)
        }
        providerScrollView.documentView = providerTableView
        root.addArrangedSubview(providerScrollView)
        NSLayoutConstraint.activate([
            countBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            providerAppFilter.widthAnchor.constraint(equalTo: root.widthAnchor),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            providerSearchField.widthAnchor.constraint(equalToConstant: 240),
            providerScrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            providerScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 330)
        ])
        return root
    }

    private func configureAppFilter(
        _ control: NSSegmentedControl,
        selectedAppType: String?,
        action: Selector
    ) {
        let appTypes = appFilterValues()
        control.segmentCount = appTypes.count
        control.target = self
        control.action = action
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        let segmentWidth = max(96, min(150, 460 / max(appTypes.count, 1)))
        for (index, appType) in appTypes.enumerated() {
            control.setLabel(appType.map(ProviderDisplay.appTypeLabel) ?? "全部应用", forSegment: index)
            control.setWidth(CGFloat(segmentWidth), forSegment: index)
            if appType == selectedAppType {
                control.selectedSegment = index
            }
        }
        if control.selectedSegment < 0, !appTypes.isEmpty {
            control.selectedSegment = 0
        }
    }

    private func appFilterValues() -> [String?] {
        [nil] + sortedAppTypes().map(Optional.some)
    }

    private func sortedAppTypes() -> [String] {
        Array(Set(routeKeys.map(\.appType) + providers.map(\.appType))).sorted {
            ProviderDisplay.appTypeLabel($0).localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
    }

    private func routeKeyCountsByApp() -> [String: Int] {
        Dictionary(grouping: routeKeys, by: \.appType).mapValues(\.count)
    }

    private func providerCountsByApp() -> [String: Int] {
        Dictionary(grouping: providers, by: \.appType).mapValues(\.count)
    }

    private func appCountBar(totalTitle: String, counts: [String: Int], unit: String) -> NSStackView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.borderWidth = 1
        bar.layer?.borderColor = NSColor.separatorColor.cgColor
        bar.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        bar.addArrangedSubview(pillLabel(totalTitle, color: .labelColor))
        bar.addArrangedSubview(NSView())
        for appType in sortedAppTypes() {
            let title = "\(ProviderDisplay.appTypeLabel(appType)): \(counts[appType] ?? 0) \(unit)"
            bar.addArrangedSubview(pillLabel(title, color: appAccentColor(appType)))
        }
        return bar
    }

    private func pillLabel(_ title: String, color: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 24),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
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

    private func pageStack(title: String, subtitle: String) -> NSStackView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitleLabel)
        return root
    }

    private func roundedScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
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

    private func isVisible(_ routeKey: ModelRouteKey) -> Bool {
        selectedRouteKeys.contains(routeKey)
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredRouteKeys = routeKeys.filter { key in
            let appMatches = selectedModelAppType == nil || key.appType == selectedModelAppType
            let queryMatches = query.isEmpty || modelSearchText(for: key).localizedCaseInsensitiveContains(query)
            return appMatches && queryMatches
        }
        modelTableView.reloadData()
        updateCount()
    }

    private func applyProviderFilter() {
        let query = providerSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredProviders = providers.filter { provider in
            let appMatches = selectedProviderAppType == nil || provider.appType == selectedProviderAppType
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
        let appKeys = routeKeys.filter {
            selectedModelAppType == nil || $0.appType == selectedModelAppType
        }
        let visibleInApp = appKeys.filter { selectedRouteKeys.contains($0) }.count
        let appLabel = selectedModelAppType.map(ProviderDisplay.appTypeLabel) ?? "全部应用"
        let selectedText = "\(appLabel) · 已显示 \(visibleInApp)/\(appKeys.count)"
        if filteredRouteKeys.count == appKeys.count {
            countLabel.stringValue = "\(selectedText) · 全局已显示 \(selectedRouteKeys.count)"
        } else {
            countLabel.stringValue = "\(selectedText) · 匹配 \(filteredRouteKeys.count) 个 · 全局已显示 \(selectedRouteKeys.count)"
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
        tableView == sidebarTableView
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
            ?? ModelToggleCell(identifier: identifier, target: self, action: #selector(toggleModel(_:)))
        let routeKey = filteredRouteKeys[row]
        cell.configure(routeKey: routeKey, detail: modelDetailText(for: routeKey), isSelected: isVisible(routeKey), tag: row)
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

    @objc private func modelAppFilterChanged(_ sender: NSSegmentedControl) {
        let appTypes = appFilterValues()
        guard sender.selectedSegment >= 0, sender.selectedSegment < appTypes.count else {
            return
        }
        selectedModelAppType = appTypes[sender.selectedSegment]
        applyFilter()
    }

    @objc private func providerAppFilterChanged(_ sender: NSSegmentedControl) {
        let appTypes = appFilterValues()
        guard sender.selectedSegment >= 0, sender.selectedSegment < appTypes.count else {
            return
        }
        selectedProviderAppType = appTypes[sender.selectedSegment]
        applyProviderFilter()
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
        updateCount()
    }

    @objc private func providerSearchChanged(_ sender: NSSearchField) {
        applyProviderFilter()
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
        let appLabel = selectedProviderAppType.map(ProviderDisplay.appTypeLabel) ?? "全部应用"
        providerCountLabel.stringValue = "\(appLabel) · \(filteredProviders.count) 个供应商 · \(protocolOverrides.count) 个覆盖"
    }

    @objc private func cancel() {
        close()
    }

    @objc private func save() {
        let visibleModels = selectedRouteKeys.count == routeKeys.count
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
        ))
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
        let appKeys = routeKeys.filter { $0.appType == appType }
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
        candidates
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
        let appLabel = ProviderDisplay.appTypeLabel(routeKey.appType)
        let upstreams = upstreamNames(for: routeKey)
        guard !upstreams.isEmpty, upstreams != [routeKey.logicalModel] else {
            return appLabel
        }
        return "\(appLabel) · 上游模型：\(upstreams.joined(separator: "、"))"
    }

    private func modelSearchText(for routeKey: ModelRouteKey) -> String {
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
            candidateText
        ].joined(separator: " ")
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

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.target = target
        checkbox.action = action
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.lineBreakMode = .byTruncatingMiddle
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkbox)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: 20),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 1)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(routeKey: ModelRouteKey, detail: String, isSelected: Bool, tag: Int) {
        checkbox.title = routeKey.logicalModel
        checkbox.toolTip = "\(routeKey.description)\n\(detail)"
        checkbox.tag = tag
        checkbox.state = isSelected ? .on : .off
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
