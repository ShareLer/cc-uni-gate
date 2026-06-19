import AppKit
import SwiftUI
import UniGateCore

@MainActor
final class SettingsViewModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case general
        case models
        case providers

        var id: String { rawValue }

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

        var subtitle: String {
            switch self {
            case .general:
                return "代理状态与客户端 Base URL"
            case .models:
                return "按应用管理菜单栏显示"
            case .providers:
                return "按应用管理协议覆盖"
            }
        }

        var symbolName: String {
            switch self {
            case .general:
                return "slider.horizontal.3"
            case .models:
                return "list.bullet.rectangle"
            case .providers:
                return "network"
            }
        }
    }

    @Published var page: Page = .general
    @Published var providers: [ImportedProvider]
    @Published var candidates: [ModelCandidate]
    @Published var routeKeys: [ModelRouteKey]
    @Published var customModels: CustomModelState
    @Published var uniGateModelScope: UniGateModelScope
    @Published var preferences: AppPreferences
    @Published var proxyStatus: ProxyStatus
    @Published var selectedRouteKeys: Set<ModelRouteKey>
    @Published var protocolOverrides: [String: ApiFormat]
    @Published var portText: String
    @Published var ccSwitchDBPathText: String
    @Published var selectedModelAppType: String?
    @Published var selectedProviderAppType: String?
    @Published var modelSearch = ""
    @Published var providerSearch = ""
    @Published var toast: String?
    @Published var customModelEditorContext: CustomModelEditorContext?

    var onClose: (() -> Void)?

    private let onSave: (AppPreferences, CustomModelState) -> Void
    private var toastToken = UUID()

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
        self.providers = providers
        self.candidates = candidates
        self.routeKeys = routeKeys
        self.customModels = customModels
        self.uniGateModelScope = uniGateModelScope
        self.preferences = preferences
        self.proxyStatus = proxyStatus
        self.protocolOverrides = preferences.protocolOverrides
        self.portText = "\(preferences.normalizedPort)"
        self.ccSwitchDBPathText = preferences.resolvedCcSwitchDBPath
        self.selectedRouteKeys = Self.visibleRouteKeys(
            preferences: preferences,
            routeKeys: routeKeys,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope
        )
        self.onSave = onSave
        self.selectedModelAppType = nil
        self.selectedProviderAppType = nil
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
        self.providers = providers
        self.candidates = candidates
        self.routeKeys = routeKeys
        self.customModels = customModels
        self.uniGateModelScope = uniGateModelScope
        self.proxyStatus = proxyStatus
        self.preferences = preferences
        self.protocolOverrides = preferences.protocolOverrides
        self.portText = "\(preferences.normalizedPort)"
        self.ccSwitchDBPathText = preferences.resolvedCcSwitchDBPath
        self.selectedRouteKeys = Self.visibleRouteKeys(
            preferences: preferences,
            routeKeys: routeKeys,
            customModels: customModels,
            uniGateModelScope: uniGateModelScope
        )
        if let selectedModelAppType, !modelAppTypes.contains(selectedModelAppType) {
            self.selectedModelAppType = nil
        }
        if let selectedProviderAppType, !providerAppTypes.contains(selectedProviderAppType) {
            self.selectedProviderAppType = nil
        }
        modelSearch = ""
        providerSearch = ""
    }

    func save() {
        guard let port = UInt16(portText), port > 0 else {
            page = .general
            NSSound.beep()
            showToast("端口无效")
            return
        }
        let saveRouteKeys = Set(modelRouteKeys().filter(isModelSelectable))
        let visible = selectedRouteKeys.intersection(saveRouteKeys)
        let visibleModels = visible == saveRouteKeys ? nil : Set(visible.map(\.description))
        let ccSwitchDBPath = ccSwitchDBPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(AppPreferences(
            visibleModels: visibleModels,
            protocolOverrides: protocolOverrides,
            port: port,
            ccSwitchDBPath: ccSwitchDBPath.isEmpty ? nil : ccSwitchDBPath
        ), customModels)
        onClose?()
    }

    private static func visibleRouteKeys(
        preferences: AppPreferences,
        routeKeys: [ModelRouteKey],
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope
    ) -> Set<ModelRouteKey> {
        let allRouteKeys = modelRouteKeys(routeKeys: routeKeys, customModels: customModels)
        let selectable = Set(allRouteKeys.filter {
            Self.isModelSelectable($0, uniGateModelScope: uniGateModelScope)
        })
        guard preferences.visibleModels != nil else {
            return selectable
        }
        return Set(preferences.visibleRouteKeyList(allRouteKeys: allRouteKeys)).intersection(selectable)
    }

    func cancel() {
        onClose?()
    }

    var currentModelAppType: String? {
        if let selectedModelAppType, modelAppTypes.contains(selectedModelAppType) {
            return selectedModelAppType
        }
        return modelAppTypes.first
    }

    var currentProviderAppType: String? {
        if let selectedProviderAppType, providerAppTypes.contains(selectedProviderAppType) {
            return selectedProviderAppType
        }
        return providerAppTypes.first
    }

    var modelAppTypes: [String] {
        let keys = modelRouteKeys()
        return sortedAppTypes().filter { appType in
            keys.contains { $0.appType == appType }
        }
    }

    var providerAppTypes: [String] {
        sortedAppTypes().filter { appType in
            providers.contains { $0.appType == appType }
        }
    }

    var filteredModelKeys: [ModelRouteKey] {
        let appType = currentModelAppType
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelRouteKeys().filter { key in
            let appMatches = appType == nil || key.appType == appType
            let queryMatches = query.isEmpty || modelSearchText(for: key).localizedCaseInsensitiveContains(query)
            return appMatches && queryMatches
        }
    }

    var filteredProviders: [ImportedProvider] {
        let appType = currentProviderAppType
        let query = providerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return providers.filter { provider in
            let appMatches = appType == nil || provider.appType == appType
            let queryMatches = query.isEmpty
                || provider.name.localizedCaseInsensitiveContains(query)
                || provider.id.localizedCaseInsensitiveContains(query)
                || (provider.baseURL?.localizedCaseInsensitiveContains(query) ?? false)
            return appMatches && queryMatches
        }
    }

    var modelCountText: String {
        let appType = currentModelAppType
        let appKeys = modelRouteKeys().filter { appType == nil || $0.appType == appType }
        let selectableInApp = appKeys.filter(isModelSelectable)
        let visibleInApp = selectableInApp.filter { selectedRouteKeys.contains($0) }.count
        let selectedText = "已显示 \(visibleInApp)/\(selectableInApp.count) 个可用模型"
        if filteredModelKeys.count == appKeys.count {
            return selectedText
        }
        return "\(selectedText) · 匹配 \(filteredModelKeys.count) 个"
    }

    var uniGateScopeWarningText: String? {
        let missing = missingUniGateScopeAppTypes()
        guard !missing.isEmpty else {
            return nil
        }
        let labels = missing.map(ProviderDisplay.appTypeLabel).joined(separator: "、")
        return "未识别到 \(labels) 的 UniGate 自供应商配置，请检查 cc-switch 里的供应商名称或 Base URL。"
    }

    var providerCountText: String {
        let overrides = filteredProviders.filter { protocolOverrides[$0.ref.description] != nil }.count
        return "\(filteredProviders.count) 个供应商 · \(overrides) 个覆盖"
    }

    func routeKeyCountsByApp() -> [String: Int] {
        Dictionary(grouping: modelRouteKeys(), by: \.appType).mapValues(\.count)
    }

    func providerCountsByApp() -> [String: Int] {
        Dictionary(grouping: providers, by: \.appType).mapValues(\.count)
    }

    func selectModelApp(_ appType: String) {
        selectedModelAppType = appType
        modelSearch = ""
    }

    func selectProviderApp(_ appType: String) {
        selectedProviderAppType = appType
        providerSearch = ""
    }

    func isVisible(_ routeKey: ModelRouteKey) -> Bool {
        selectedRouteKeys.contains(routeKey)
    }

    func isModelSelectable(_ routeKey: ModelRouteKey) -> Bool {
        Self.isModelSelectable(routeKey, uniGateModelScope: uniGateModelScope)
    }

    func setVisible(_ routeKey: ModelRouteKey, visible: Bool) {
        guard isModelSelectable(routeKey) else {
            selectedRouteKeys.remove(routeKey)
            return
        }
        if visible {
            selectedRouteKeys.insert(routeKey)
        } else {
            selectedRouteKeys.remove(routeKey)
        }
    }

    func addCustomModel() {
        customModelEditorContext = CustomModelEditorContext(existing: nil, candidates: baseModelCandidates())
    }

    func editCustomModel(_ model: CustomModelDefinition) {
        customModelEditorContext = CustomModelEditorContext(existing: model, candidates: baseModelCandidates())
    }

    func finishEditingCustomModel(_ edited: CustomModelDefinition, replacing model: CustomModelDefinition?) {
        customModelEditorContext = nil
        if let model, let index = customModels.models.firstIndex(where: { $0.id == model.id }) {
            customModels.models[index] = edited
        } else {
            customModels.models.append(edited)
        }
        afterEditingCustomModel(edited, replacing: model)
    }

    func deleteCustomModel(_ model: CustomModelDefinition) {
        customModels.models.removeAll { $0.id == model.id }
        selectedRouteKeys.remove(ModelRouteKey(appType: model.appType, logicalModel: model.name))
        if let selectedModelAppType, !modelAppTypes.contains(selectedModelAppType) {
            self.selectedModelAppType = nil
        }
    }

    func customModel(for routeKey: ModelRouteKey) -> CustomModelDefinition? {
        customModels.models.first {
            $0.appType == routeKey.appType && $0.name == routeKey.logicalModel
        }
    }

    func clearListedOverrides() {
        for provider in filteredProviders {
            protocolOverrides.removeValue(forKey: provider.ref.description)
        }
    }

    func protocolSelection(for provider: ImportedProvider) -> Binding<String> {
        Binding(
            get: { self.protocolOverrides[provider.ref.description]?.rawValue ?? "inherit" },
            set: { value in
                if value == "inherit" {
                    self.protocolOverrides.removeValue(forKey: provider.ref.description)
                } else if let format = ApiFormat(rawValue: value) {
                    self.protocolOverrides[provider.ref.description] = format
                }
            }
        )
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
        let port = UInt16(portText) ?? 17888
        return "http://127.0.0.1:\(port)\(path)"
    }

    func modelDetailText(for routeKey: ModelRouteKey) -> String {
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

    func providerFormatText(_ provider: ImportedProvider) -> String {
        if protocolOverrides[provider.ref.description] == nil {
            return "检测到：\(provider.apiFormat.rawValue)"
        }
        return "已覆盖 · 检测到 \(provider.apiFormat.rawValue)"
    }

    private func afterEditingCustomModel(_ edited: CustomModelDefinition, replacing existing: CustomModelDefinition?) {
        if let existing {
            selectedRouteKeys.remove(ModelRouteKey(appType: existing.appType, logicalModel: existing.name))
        }
        let routeKey = ModelRouteKey(appType: edited.appType, logicalModel: edited.name)
        if isModelSelectable(routeKey) {
            selectedRouteKeys.insert(routeKey)
        }
        selectedModelAppType = edited.appType
        modelSearch = ""
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

    private func sortedAppTypes() -> [String] {
        Array(Set(modelRouteKeys().map(\.appType) + providers.map(\.appType))).sorted {
            ProviderDisplay.appTypeLabel($0).localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
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

    private func missingUniGateScopeAppTypes() -> [String] {
        ["claude", "codex"].filter { appType in
            baseModelCandidates().contains { $0.appType == appType }
                && !uniGateModelScope.hasModels(for: appType)
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
            "\($0.logicalModel) -> \($0.providerName)"
        } ?? "未选择有效目标"
        return "\(ProviderDisplay.appTypeLabel(model.appType)) · \(targetCount) 个目标 · 当前：\(selectedText)"
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
        return Self.modelRouteKeys(routeKeys: baseRouteKeys, customModels: customModels)
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

    private static func isModelSelectable(
        _ routeKey: ModelRouteKey,
        uniGateModelScope: UniGateModelScope
    ) -> Bool {
        guard routeKey.appType == "claude" || routeKey.appType == "codex" else {
            return true
        }
        return uniGateModelScope.contains(routeKey)
    }
}

struct CustomModelEditorContext: Identifiable {
    let id = UUID()
    let existing: CustomModelDefinition?
    let candidates: [ModelCandidate]
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(UGStyle.canvas)
        .overlay {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(UGStyle.toastBackground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(UGStyle.line.opacity(0.7)))
                    .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $model.customModelEditorContext) { context in
            CustomModelEditorView(context: context) { edited in
                model.finishEditingCustomModel(edited, replacing: context.existing)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置")
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 10)

            ForEach(SettingsViewModel.Page.allCases) { page in
                sidebarItem(page)
            }

            Spacer()
        }
        .frame(width: 176)
        .padding(.vertical, 8)
        .background(UGStyle.sidebar)
    }

    private func sidebarItem(_ page: SettingsViewModel.Page) -> some View {
        Button {
            model.page = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbolName)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(page.title)
                    .font(UGStyle.body)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(model.page == page ? .white : .primary)
            .background(model.page == page ? UGStyle.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            pageContent
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UGStyle.canvas)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .general:
            ScrollView {
                pageShell {
                    generalPage
                }
            }
        case .models:
            pageShell {
                modelsPage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .providers:
            pageShell {
                providersPage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func pageShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.page.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(model.page.subtitle)
                    .font(UGStyle.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("取消") { model.cancel() }
            Button("保存更改") { model.save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                statCard(title: "代理", value: model.proxyStatus.shortTitle, detail: "本地监听", color: Color(nsColor: model.proxyStatus.accentColor))
                statCard(title: "供应商", value: "\(model.providers.count)", detail: "\(model.providerAppTypes.count) 个应用", color: .blue)
                statCard(title: "模型", value: "\(model.selectedRouteKeys.count)/\(model.routeKeys.count)", detail: "显示在菜单", color: .green)
                statCard(title: "覆盖", value: "\(model.protocolOverrides.count)", detail: "协议固定", color: .orange)
            }

            card {
                settingsRow(title: "本地代理端口", subtitle: "保存后生效。") {
                    TextField("17888", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 108)
                }
                Divider()
                settingsRow(title: "cc-switch 数据库路径", subtitle: "留空使用默认路径。") {
                    TextField(AppPreferences.defaultCcSwitchDBPath(), text: $model.ccSwitchDBPathText)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 300)
                }
            }

            card(spacing: 0) {
                endpointRow(title: "Codex", subtitle: "OpenAI 兼容客户端", path: "/codex", canImport: true)
                Divider()
                endpointRow(title: "Claude Code", subtitle: "Anthropic Messages API 客户端", path: "/claude-code", canImport: true)
                Divider()
                endpointRow(title: "Claude Desktop", subtitle: "Anthropic Messages API 客户端", path: "/claude-desktop", canImport: false)
            }
        }
    }

    private var modelsPage: some View {
        splitPage(
            appTypes: model.modelAppTypes,
            counts: model.routeKeyCountsByApp(),
            selected: model.currentModelAppType,
            onSelect: model.selectModelApp
        ) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(
                    model.currentModelAppType.map(ProviderDisplay.appTypeLabel) ?? "应用",
                    detail: model.modelCountText
                )
                if let warningText = model.uniGateScopeWarningText {
                    warningBanner(warningText)
                }
                HStack(spacing: 8) {
                    TextField("搜索模型", text: $model.modelSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Spacer()
                    Button {
                        model.addCustomModel()
                    } label: {
                        Label("自定义", systemImage: "plus")
                    }
                    .fixedSize()
                }
                rowList {
                    ForEach(model.filteredModelKeys, id: \.description) { key in
                        modelRow(key)
                    }
                }
            }
        }
    }

    private var providersPage: some View {
        splitPage(
            appTypes: model.providerAppTypes,
            counts: model.providerCountsByApp(),
            selected: model.currentProviderAppType,
            onSelect: model.selectProviderApp
        ) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(
                    model.currentProviderAppType.map(ProviderDisplay.appTypeLabel) ?? "应用",
                    detail: model.providerCountText
                )
                HStack(spacing: 8) {
                    TextField("搜索供应商", text: $model.providerSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Spacer()
                    Button("清除当前列表覆盖") { model.clearListedOverrides() }
                }
                rowList {
                    ForEach(model.filteredProviders) { provider in
                        providerRow(provider)
                    }
                }
            }
        }
    }

    private func splitPage<Content: View>(
        appTypes: [String],
        counts: [String: Int],
        selected: String?,
        onSelect: @escaping (String) -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(appTypes, id: \.self) { appType in
                    Button {
                        onSelect(appType)
                    } label: {
                        HStack {
                            Text(ProviderDisplay.appTypeLabel(appType))
                                .font(UGStyle.body)
                                .fontWeight(selected == appType ? .semibold : .regular)
                            Spacer()
                            Text("\(counts[appType] ?? 0)")
                                .font(UGStyle.caption)
                                .foregroundStyle(selected == appType ? .white.opacity(0.85) : .secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .foregroundStyle(selected == appType ? .white : .primary)
                        .background(selected == appType ? UGStyle.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 172, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(UGStyle.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGStyle.line))

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func modelRow(_ key: ModelRouteKey) -> some View {
        let custom = model.customModel(for: key)
        let isSelectable = model.isModelSelectable(key)
        return HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelectable && model.isVisible(key) },
                set: { model.setVisible(key, visible: $0) }
            ))
            .labelsHidden()
            .disabled(!isSelectable)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(key.logicalModel)
                        .font(UGStyle.body)
                        .lineLimit(1)
                    if custom != nil {
                        Text("自定义")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                    if !isSelectable {
                        Text("未配置")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text(model.modelDetailText(for: key))
                    .font(UGStyle.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let custom {
                Button {
                    model.editCustomModel(custom)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑自定义模型")
                Button(role: .destructive) {
                    model.deleteCustomModel(custom)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除自定义模型")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(isSelectable ? 1 : 0.48)
        .background(isSelectable && model.isVisible(key) ? Color.blue.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func providerRow(_ provider: ImportedProvider) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(UGStyle.body)
                        .lineLimit(1)
                    Text(ProviderDisplay.appTypeLabel(provider.appType))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(appColor(provider.appType))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(appColor(provider.appType).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                Text(model.providerFormatText(provider))
                    .font(UGStyle.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(provider.baseURL ?? "未检测到 Base URL")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Picker("", selection: model.protocolSelection(for: provider)) {
                Text("继承检测结果").tag("inherit")
                Divider()
                Text("OpenAI Responses").tag(ApiFormat.openaiResponses.rawValue)
                Text("OpenAI Chat").tag(ApiFormat.openaiChat.rawValue)
                Text("Anthropic").tag(ApiFormat.anthropic.rawValue)
                Text("Gemini Native").tag(ApiFormat.geminiNative.rawValue)
            }
            .labelsHidden()
            .frame(width: 178)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func endpointRow(title: String, subtitle: String, path: String, canImport: Bool) -> some View {
        settingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Text(model.baseURL(path: path))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 220, alignment: .leading)
                if canImport {
                    Button("导入并切换") { model.importToCcSwitch(path: path) }
                }
                Button("复制") { model.copyBaseURL(path: path) }
            }
        }
        .padding(.vertical, 5)
    }

    private func settingsRow<Control: View>(
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(UGStyle.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 180, alignment: .leading)
            Spacer()
            control()
        }
    }

    private func statCard(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
            Text(detail)
                .font(UGStyle.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.28)))
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(UGStyle.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.28)))
    }

    private func card<Content: View>(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UGStyle.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGStyle.line))
    }

    private func rowList<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                content()
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.45)
                    }
            }
            .padding(5)
        }
        .frame(minHeight: 320, maxHeight: .infinity)
        .background(UGStyle.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGStyle.line))
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(UGStyle.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func appColor(_ appType: String) -> Color {
        switch appType {
        case "codex":
            return .blue
        case "claude":
            return .purple
        case "claude-desktop":
            return .teal
        case "gemini":
            return .orange
        default:
            return .secondary
        }
    }
}

private struct CustomModelEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let context: CustomModelEditorContext
    let onSave: (CustomModelDefinition) -> Void

    private let candidates: [ModelCandidate]
    private let appTypes: [String]
    private let existingTargetsByKey: [String: CustomModelTarget]

    @State private var name: String
    @State private var appType: String
    @State private var selectedTargetIDs: Set<String>
    @State private var currentTargetID: String

    init(context: CustomModelEditorContext, onSave: @escaping (CustomModelDefinition) -> Void) {
        self.context = context
        self.onSave = onSave

        let sortedCandidates = context.candidates.sorted {
            [$0.appType, $0.logicalModel, $0.providerName].joined(separator: "\u{0}")
                .localizedStandardCompare([$1.appType, $1.logicalModel, $1.providerName].joined(separator: "\u{0}")) == .orderedAscending
        }
        self.candidates = sortedCandidates
        let sortedAppTypes = Array(Set(sortedCandidates.map(\.appType) + [context.existing?.appType].compactMap { $0 })).sorted {
            ProviderDisplay.appTypeLabel($0).localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
        self.appTypes = sortedAppTypes
        self.existingTargetsByKey = Dictionary(
            uniqueKeysWithValues: (context.existing?.targets ?? []).map { (Self.targetID($0), $0) }
        )

        let targetIDs = Set(context.existing?.targets.map(Self.targetID) ?? [])
        let initialAppType = context.existing?.appType ?? sortedAppTypes.first ?? ""
        let initialTargetID = context.existing?.selectedTarget.map { Self.targetID($0) } ?? targetIDs.sorted().first ?? ""
        _name = State(initialValue: context.existing?.name ?? "")
        _appType = State(initialValue: initialAppType)
        _selectedTargetIDs = State(initialValue: targetIDs)
        _currentTargetID = State(initialValue: initialTargetID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520, height: 620)
        .background(UGStyle.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(context.existing == nil ? "新增自定义模型" : "编辑自定义模型")
                .font(.system(size: 20, weight: .semibold))
            Text("为模型名选择应用，并勾选一个或多个转发目标。")
                .font(UGStyle.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorField(title: "模型名") {
                TextField("例如 customer_model", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }

            editorField(title: "应用") {
                Picker("", selection: $appType) {
                    ForEach(appTypes, id: \.self) { item in
                        Text(ProviderDisplay.appTypeLabel(item)).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 220, alignment: .leading)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("转发目标")
                    .font(.system(size: 15, weight: .semibold))
                Text("可勾选多个现有模型。")
                    .font(UGStyle.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            editorField(title: "默认转发目标") {
                Picker("", selection: $currentTargetID) {
                    if selectedCandidates.isEmpty {
                        Text("先勾选转发目标").tag("")
                    }
                    ForEach(selectedCandidates) { candidate in
                        Text(targetTitle(candidate)).tag(targetID(candidate))
                    }
                }
                .labelsHidden()
                .disabled(selectedCandidates.isEmpty)
                .frame(width: 320, alignment: .leading)
            }

            targetList
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .onChange(of: appType) { _, _ in
            selectedTargetIDs.removeAll()
            currentTargetID = ""
        }
    }

    private func editorField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredCandidates) { candidate in
                    targetRow(candidate)
                        .overlay(alignment: .bottom) {
                            Divider().opacity(0.45)
                        }
                }
            }
            .padding(5)
        }
        .frame(height: 280)
        .background(UGStyle.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGStyle.line))
    }

    private func targetRow(_ candidate: ModelCandidate) -> some View {
        let id = targetID(candidate)
        let selected = selectedTargetIDs.contains(id)
        return HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selectedTargetIDs.contains(id) },
                set: { setTarget(id, selected: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 3) {
                Text(targetTitle(candidate))
                    .font(UGStyle.body)
                    .lineLimit(1)
                Text("\(ProviderDisplay.appTypeLabel(candidate.appType)) · \(candidate.upstreamModel)")
                    .font(UGStyle.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.blue.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("取消") {
                dismiss()
            }
            Button("保存") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var filteredCandidates: [ModelCandidate] {
        candidates.filter { appType.isEmpty || $0.appType == appType }
    }

    private var selectedCandidates: [ModelCandidate] {
        filteredCandidates.filter { selectedTargetIDs.contains(targetID($0)) }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appType.isEmpty
            && !selectedCandidates.isEmpty
    }

    private func setTarget(_ id: String, selected: Bool) {
        if selected {
            selectedTargetIDs.insert(id)
            if currentTargetID.isEmpty {
                currentTargetID = id
            }
        } else {
            selectedTargetIDs.remove(id)
            if currentTargetID == id {
                currentTargetID = selectedCandidates.first.map(targetID) ?? ""
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !appType.isEmpty, !selectedCandidates.isEmpty else {
            NSSound.beep()
            return
        }

        let targets = selectedCandidates.map {
            existingTargetsByKey[targetID($0)] ?? CustomModelTarget(routeKey: $0.routeKey, providerRef: $0.providerRef)
        }
        let selectedTargetID = zip(selectedCandidates, targets).first {
            targetID($0.0) == currentTargetID
        }?.1.id ?? targets.first?.id

        onSave(CustomModelDefinition(
            id: context.existing?.id ?? UUID(),
            appType: appType,
            name: trimmedName,
            targets: targets,
            selectedTargetID: selectedTargetID
        ))
    }

    private static func targetID(_ target: CustomModelTarget) -> String {
        "\(target.routeKey.description)|\(target.providerRef.description)"
    }

    private func targetID(_ candidate: ModelCandidate) -> String {
        "\(candidate.routeKey.description)|\(candidate.providerRef.description)"
    }

    private func targetTitle(_ candidate: ModelCandidate) -> String {
        "\(candidate.logicalModel) · \(candidate.providerName)"
    }
}

private enum UGStyle {
    static let accent = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let canvas = Color.white
    static let sidebar = Color.white
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let toastBackground = Color(red: 0.98, green: 0.985, blue: 0.995)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
}
