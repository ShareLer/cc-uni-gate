import ApiManagerCore
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
        statusItem.button?.toolTip = "API Manager"
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
            recordEvent(.info, "Proxy listening at \(managerBaseURL())")
            rebuildMenu()
        } catch {
            proxyStatus = .failed(error.localizedDescription)
            recordEvent(.error, "Proxy failed: \(error.localizedDescription)")
            rebuildMenu()
            showError(error)
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "API Manager", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let summaryItem = NSMenuItem(
            title: "\(catalog.providers.count) providers, \(catalog.models.count) models",
            action: nil,
            keyEquivalent: ""
        )
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)

        let proxyItem = NSMenuItem(
            title: proxyStatus.title(baseURL: managerBaseURL()),
            action: nil,
            keyEquivalent: ""
        )
        proxyItem.isEnabled = false
        menu.addItem(proxyItem)
        menu.addItem(.separator())

        let visibleRouteKeys = preferences.visibleRouteKeyList(allRouteKeys: catalog.routeKeys)
        if visibleRouteKeys.isEmpty {
            let emptyItem = NSMenuItem(title: "No models selected", action: nil, keyEquivalent: "")
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
        menu.addItem(appMenuItem(title: "Copy OpenAI Base URL", action: #selector(copyOpenAIBaseURL), keyEquivalent: ""))
        menu.addItem(appMenuItem(title: "Open Logs Folder", action: #selector(openLogsFolder), keyEquivalent: ""))
        menu.addItem(appMenuItem(title: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: ""))
        menu.addItem(appMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(appMenuItem(title: "Reload cc-switch DB", action: #selector(reloadAction), keyEquivalent: "r"))
        menu.addItem(appMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func rebuildErrorMenu(_ error: Error) {
        let menu = NSMenu()
        let errorItem = NSMenuItem(title: "Failed to load cc-switch DB", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        menu.addItem(errorItem)
        let detailItem = NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        menu.addItem(detailItem)
        menu.addItem(.separator())
        menu.addItem(appMenuItem(title: "Retry", action: #selector(reloadAction), keyEquivalent: "r"))
        menu.addItem(appMenuItem(title: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: ""))
        menu.addItem(appMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func appMenuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func providerTitle(_ candidate: ModelCandidate) -> String {
        var parts = [candidate.providerName]
        if candidate.requiresTransform {
            parts.append("transform")
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
                routeKeys: catalog.routeKeys,
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
                routeKeys: catalog.routeKeys,
                preferences: preferences
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyOpenAIBaseURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(managerBaseURL())/openai", forType: .string)
    }

    @objc private func openLogsFolder() {
        try? FileManager.default.createDirectory(
            at: AppPaths.logsDirectory(),
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(AppPaths.logsDirectory())
    }

    @objc private func openConfigFolder() {
        try? FileManager.default.createDirectory(
            at: AppPaths.applicationSupportDirectory(),
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(AppPaths.applicationSupportDirectory())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "API Manager"
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
        recordEvent(.info, "Reloaded cc-switch DB")
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

    func title(baseURL: String) -> String {
        switch self {
        case .starting:
            return "Proxy: starting · \(baseURL)"
        case .running:
            return "Proxy: running · \(baseURL)"
        case let .failed(message):
            return "Proxy: failed · \(message)"
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
                return "General"
            case .models:
                return "Models"
            case .providers:
                return "Providers"
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
    private let countLabel = NSTextField(labelWithString: "")
    private let providerCountLabel = NSTextField(labelWithString: "")
    private let portField = NSTextField()
    private let baseURLLabel = NSTextField(labelWithString: "")
    private var providers: [ImportedProvider]
    private var routeKeys: [ModelRouteKey]
    private var filteredRouteKeys: [ModelRouteKey]
    private var selectedRouteKeys: Set<ModelRouteKey>
    private var protocolOverrides: [String: ApiFormat]
    private var selectedSection: SettingsSection = .general
    private var preferences: AppPreferences
    private let onSave: (AppPreferences) -> Void

    init(
        providers: [ImportedProvider],
        routeKeys: [ModelRouteKey],
        preferences: AppPreferences,
        onSave: @escaping (AppPreferences) -> Void
    ) {
        self.providers = providers
        self.routeKeys = routeKeys
        self.filteredRouteKeys = routeKeys
        self.preferences = preferences
        self.selectedRouteKeys = preferences.visibleModels == nil
            ? Set(routeKeys)
            : Set(preferences.visibleRouteKeyList(allRouteKeys: routeKeys))
        self.protocolOverrides = preferences.protocolOverrides
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "API Manager"
        window.minSize = NSSize(width: 700, height: 500)
        window.center()
        super.init(window: window)
        buildContent()
        applyFilter()
        updateProviderCount()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(providers: [ImportedProvider], routeKeys: [ModelRouteKey], preferences: AppPreferences) {
        self.providers = providers
        self.routeKeys = routeKeys
        self.filteredRouteKeys = routeKeys
        self.preferences = preferences
        self.selectedRouteKeys = preferences.visibleModels == nil
            ? Set(routeKeys)
            : Set(preferences.visibleRouteKeyList(allRouteKeys: routeKeys))
        self.protocolOverrides = preferences.protocolOverrides
        updatePortField()
        searchField.stringValue = ""
        applyFilter()
        providerTableView.reloadData()
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
        rightPane.spacing = 16
        rightPane.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addArrangedSubview(contentView)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        let cancelButton = button(title: "Cancel", action: #selector(cancel))
        let saveButton = button(title: "Save", action: #selector(save))
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
        let root = pageStack(title: "General", subtitle: "Proxy")
        let form = NSGridView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 12
        form.columnSpacing = 14

        portField.alignment = .right
        portField.placeholderString = "17888"
        portField.formatter = portFormatter()
        portField.target = self
        portField.action = #selector(portChanged(_:))
        portField.translatesAutoresizingMaskIntoConstraints = false
        updateBaseURLLabel()
        baseURLLabel.textColor = .secondaryLabelColor
        baseURLLabel.lineBreakMode = .byTruncatingMiddle

        form.addRow(with: [fieldLabel("Port"), portField])
        form.addRow(with: [fieldLabel("OpenAI base URL"), baseURLLabel])
        root.addArrangedSubview(form)

        NSLayoutConstraint.activate([
            portField.widthAnchor.constraint(equalToConstant: 96)
        ])
        return root
    }

    private func modelsView() -> NSView {
        let root = pageStack(title: "Models", subtitle: "Status bar menu")
        root.addArrangedSubview(countLabel)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search models"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        controls.addArrangedSubview(searchField)
        let controlSpacer = NSView()
        controls.addArrangedSubview(controlSpacer)
        controls.addArrangedSubview(button(title: "Select All", action: #selector(selectAllModels)))
        controls.addArrangedSubview(button(title: "Select None", action: #selector(selectNoModels)))
        root.addArrangedSubview(controls)

        let scrollView = roundedScrollView()
        configureTable(modelTableView, rowHeight: 34)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.minWidth = 220
        if modelTableView.tableColumns.isEmpty {
            modelTableView.addTableColumn(column)
        }

        scrollView.documentView = modelTableView
        root.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 330)
        ])
        return root
    }

    private func providersView() -> NSView {
        let root = pageStack(title: "Providers", subtitle: "Protocol overrides")
        root.addArrangedSubview(providerCountLabel)
        let providerScrollView = roundedScrollView()
        configureTable(providerTableView, rowHeight: 36)
        let providerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        providerColumn.minWidth = 260
        if providerTableView.tableColumns.isEmpty {
            providerTableView.addTableColumn(providerColumn)
        }
        providerScrollView.documentView = providerTableView
        root.addArrangedSubview(providerScrollView)
        NSLayoutConstraint.activate([
            providerScrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            providerScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 390)
        ])
        return root
    }

    private func pageStack(title: String, subtitle: String) -> NSStackView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
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

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        return label
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
        if query.isEmpty {
            filteredRouteKeys = routeKeys
        } else {
            filteredRouteKeys = routeKeys.filter {
                $0.logicalModel.localizedCaseInsensitiveContains(query)
                    || ProviderDisplay.appTypeLabel($0.appType).localizedCaseInsensitiveContains(query)
            }
        }
        modelTableView.reloadData()
        updateCount()
    }

    private func updateCount() {
        let selectedText = "\(selectedRouteKeys.count) of \(routeKeys.count) visible"
        if filteredRouteKeys.count == routeKeys.count {
            countLabel.stringValue = selectedText
        } else {
            countLabel.stringValue = "\(selectedText) · \(filteredRouteKeys.count) matching"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == sidebarTableView {
            return SettingsSection.allCases.count
        }
        if tableView == providerTableView {
            return providers.count
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
            guard row < providers.count else {
                return nil
            }
            let identifier = NSUserInterfaceItemIdentifier("ProviderProtocolCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ProviderProtocolCell
                ?? ProviderProtocolCell(identifier: identifier, target: self, action: #selector(protocolChanged(_:)))
            let provider = providers[row]
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
        cell.configure(routeKey: routeKey, isSelected: isVisible(routeKey), tag: row)
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
        selectedRouteKeys = Set(routeKeys)
        modelTableView.reloadData()
        updateCount()
    }

    @objc private func selectNoModels() {
        selectedRouteKeys = []
        modelTableView.reloadData()
        updateCount()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter()
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

    @objc private func protocolChanged(_ sender: NSPopUpButton) {
        guard sender.tag >= 0, sender.tag < providers.count else {
            return
        }
        let provider = providers[sender.tag]
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

    @objc private func portChanged(_ sender: NSTextField) {
        updateBaseURLLabel()
    }

    private func updateProviderCount() {
        providerCountLabel.stringValue = "\(protocolOverrides.count) overrides"
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
        updateBaseURLLabel()
    }

    private func updateBaseURLLabel() {
        let port = UInt16(portField.stringValue) ?? 17888
        baseURLLabel.stringValue = "http://127.0.0.1:\(port)/openai"
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

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.target = target
        checkbox.action = action
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.lineBreakMode = .byTruncatingMiddle
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(routeKey: ModelRouteKey, isSelected: Bool, tag: Int) {
        checkbox.title = routeKey.displayName
        checkbox.toolTip = routeKey.description
        checkbox.tag = tag
        checkbox.state = isSelected ? .on : .off
    }
}

private final class ProviderProtocolCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
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

        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.textColor = .secondaryLabelColor
        labels.addArrangedSubview(formatLabel)

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
            popup.widthAnchor.constraint(equalToConstant: 170)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(provider: ImportedProvider, override: ApiFormat?, tag: Int) {
        nameLabel.stringValue = provider.displayName
        formatLabel.stringValue = "Detected: \(provider.apiFormat.rawValue)"
        popup.tag = tag
        let selected = override?.rawValue ?? "inherit"
        selectItem(representedObject: selected)
    }

    private func addProtocolItems() {
        popup.removeAllItems()
        addItem("Inherit", representedObject: "inherit")
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
