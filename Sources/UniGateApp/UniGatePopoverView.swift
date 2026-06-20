import AppKit
import SwiftUI
import UniGateCore

private enum BrandColorPalette {
    static func color(for preset: BrandColorPreset) -> Color {
        switch preset {
        case .ember:
            return Color(red: 0xE8 / 255.0, green: 0x6D / 255.0, blue: 0x45 / 255.0)
        case .blue:
            return Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
        case .indigo:
            return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case .violet:
            return Color(red: 0xAF / 255.0, green: 0x52 / 255.0, blue: 0xDE / 255.0)
        case .teal:
            return Color(red: 0x00 / 255.0, green: 0xA7 / 255.0, blue: 0x93 / 255.0)
        case .green:
            return Color(red: 0x34 / 255.0, green: 0xA8 / 255.0, blue: 0x53 / 255.0)
        case .rose:
            return Color(red: 0xE9 / 255.0, green: 0x44 / 255.0, blue: 0x6A / 255.0)
        }
    }

    static func label(for preset: BrandColorPreset) -> String {
        switch preset {
        case .ember:
            return "暖橙"
        case .blue:
            return "蓝"
        case .indigo:
            return "靛蓝"
        case .violet:
            return "紫"
        case .teal:
            return "青绿"
        case .green:
            return "绿"
        case .rose:
            return "玫红"
        }
    }
}

private struct UGBrandColorKey: EnvironmentKey {
    static let defaultValue = BrandColorPalette.color(for: .ember)
}

private extension EnvironmentValues {
    var ugBrandColor: Color {
        get { self[UGBrandColorKey.self] }
        set { self[UGBrandColorKey.self] = newValue }
    }
}

struct UniGatePopoverRootView: View {
    @ObservedObject var state: UniGateAppState
    @State private var expandedScrollRequestID = UUID()
    @State private var expandedTopScrollAllowanceDescription: String?
    @State private var reloadFeedbackActive = false
    @State private var reloadFeedbackID = UUID()
    @State private var isAddingCustomModel = false
    @State private var customModelEditorID = UUID()
    @State private var editingCustomModel: CustomModelDefinition?
    @State private var pendingDeleteCustomModelID: UUID?

    private let expandedRowAnimation = Animation.easeInOut(duration: 0.22)
    private let collapsedRowAnimation = Animation.easeInOut(duration: 0.34)
    private let panelTransitionAnimation = Animation.easeInOut(duration: 0.28)
    private let providerTagWidth: CGFloat = 132

    var body: some View {
        routeSwitcher
            .frame(width: 420, height: 620)
            .environment(\.ugBrandColor, brand)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(UGPopoverStyle.cardFillStrong, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGPopoverStyle.cardBorder))
                    .shadow(color: UGPopoverStyle.cardShadowColor, radius: 12, x: 0, y: 7)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .allowsHitTesting(false)
            }
        }
    }

    private var brand: Color {
        BrandColorPalette.color(for: state.preferences.brandColor)
    }

    private var routeSwitcher: some View {
        VStack(spacing: 0) {
            header
            statusDetailBubble
            selectorRow
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(brand.opacity(0.12))
                Image(systemName: "switch.2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(brand)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("CC Uni Gate")
                    .font(.headline)
                    .lineLimit(1)
                Text("模型路由控制台")
                    .font(.caption)
                    .foregroundStyle(UGPopoverStyle.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            headerStatusReadout
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var headerStatusReadout: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: state.proxyStatus.accentColor))
                .frame(width: 8, height: 8)
            Text(state.proxyStatus.shortTitle)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(headerStatusFill, in: RoundedRectangle(cornerRadius: 6))
        .help(state.proxyStatus.title(port: state.proxyPort))
    }

    private var headerStatusFill: Color {
        Color(nsColor: state.proxyStatus.accentColor).opacity(0.12)
    }

    @ViewBuilder
    private var statusDetailBubble: some View {
        if let statusDetailText {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: state.proxyStatus.accentColor))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.proxyStatus.shortTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(statusDetailText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UGPopoverStyle.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(UGPopoverStyle.issueBubbleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(UGPopoverStyle.issueBubbleBorder)
            )
            .overlay(alignment: .topLeading) {
                BubbleTail()
                    .fill(UGPopoverStyle.issueBubbleFill)
                    .frame(width: 13, height: 7)
                    .offset(x: 34, y: -6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 1)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .help(state.proxyStatus.title(port: state.proxyPort))
        }
    }

    private var statusDetailText: String? {
        switch state.proxyStatus {
        case .starting, .running:
            return nil
        case let .providerIssue(message), let .failed(message):
            return message
        }
    }

    private var totalForwardedRequestCount: Int {
        state.forwardedRequestCounts.values.reduce(0, +)
    }

    private var currentAppRequestCountText: String {
        guard let appType = state.currentAppType else {
            return "请求 \(totalForwardedRequestCount)"
        }
        return "请求 \(state.forwardedRequestCounts[appType, default: 0])"
    }

    private var currentAppSummaryText: String {
        "\(state.modelCountText) · \(state.providerCountText) · \(currentAppRequestCountText)"
    }

    @ViewBuilder
    private var reloadIndicator: some View {
        if reloadFeedbackActive {
            DottedSpinner()
                .transition(.opacity)
        } else {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .transition(.opacity)
        }
    }

    private func triggerReload() {
        let feedbackID = UUID()
        reloadFeedbackID = feedbackID
        withAnimation(.easeInOut(duration: 0.22)) {
            reloadFeedbackActive = true
        }
        state.reload()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard reloadFeedbackID == feedbackID else {
                return
            }
            withAnimation(.easeInOut(duration: 0.22)) {
                reloadFeedbackActive = false
            }
        }
    }

    private var selectorRow: some View {
        HStack(spacing: 10) {
            appSelector
                .frame(maxWidth: .infinity)
            settingsSelectorButton
                .frame(width: 86, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .padding(.bottom, 8)
    }

    private var appSelector: some View {
        let isActive = state.screen == .routes
        return ZStack {
            Capsule()
                .fill(UGPopoverStyle.tabFill)
                .overlay(Capsule().stroke(UGPopoverStyle.tabBorder, lineWidth: 1))

            GeometryReader { geo in
                let appTypes = state.appTypes
                let count = max(CGFloat(appTypes.count), 1)
                let tabWidth = geo.size.width / count
                let selected = state.currentAppType.flatMap { appTypes.firstIndex(of: $0) } ?? 0
                if isActive {
                    Capsule()
                        .fill(brand)
                        .padding(2)
                        .frame(width: tabWidth)
                        .offset(x: tabWidth * CGFloat(selected))
                        .animation(.easeInOut(duration: 0.15), value: state.currentAppType)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 0) {
                ForEach(state.appTypes, id: \.self) { appType in
                    VStack(spacing: 2) {
                        Image(systemName: iconName(for: appType))
                            .font(.system(size: 12))
                        Text(ProviderDisplay.appTypeLabel(appType))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(isActive && state.currentAppType == appType ? .white : UGPopoverStyle.textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            state.closeSettings()
                            state.selectApp(appType)
                        }
                    }
                }
            }
        }
        .frame(height: 44)
    }

    private var settingsSelectorButton: some View {
        let selected = state.screen == .settings
        return Button {
            pendingDeleteCustomModelID = nil
            editingCustomModel = nil
            withAnimation(.easeInOut(duration: 0.15)) {
                isAddingCustomModel = false
                state.openSettings()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                Text("设置")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? .white : UGPopoverStyle.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? brand : UGPopoverStyle.tabFill, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.clear : UGPopoverStyle.tabBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("设置")
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            switch state.screen {
            case .routes:
                routeContent
                    .transition(.opacity)
            case .settings:
                inlineSettingsPanel
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(.easeInOut(duration: 0.15), value: state.screen)
    }

    private var routeContent: some View {
        ZStack(alignment: .topLeading) {
            if isAddingCustomModel {
                customModelPanel
                    .id(customModelEditorID)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                modelListPanel
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(panelTransitionAnimation, value: isAddingCustomModel)
    }

    private var inlineSettingsPanel: some View {
        InlineSettingsPanel(model: state.settingsModel(), loadError: state.loadError)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modelListPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.currentAppType.map(ProviderDisplay.appTypeLabel) ?? "模型")
                    .font(.system(size: 16, weight: .semibold))
                Text(currentAppSummaryText)
                    .font(.caption)
                    .foregroundStyle(UGPopoverStyle.textSecondary)
                Spacer()
            }

            if let loadError = state.loadError {
                errorBanner(loadError)
            }

            modelList
                .opacity(reloadFeedbackActive ? 0.70 : 1)
                .scaleEffect(reloadFeedbackActive ? 0.996 : 1)
                .animation(.easeInOut(duration: 0.22), value: reloadFeedbackActive)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var customModelPanel: some View {
        InlineCustomModelEditorView(
            candidates: state.customModelBaseCandidates(),
            existing: editingCustomModel,
            initialAppType: state.currentAppType,
            onSave: { definition in
                state.saveCustomModel(definition, replacing: editingCustomModel)
                closeCustomModelEditor()
            },
            onCancel: closeCustomModelEditor
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openCustomModelEditor() {
        state.expandedRouteKeyDescription = nil
        editingCustomModel = nil
        customModelEditorID = UUID()
        withAnimation(panelTransitionAnimation) {
            isAddingCustomModel = true
        }
    }

    private func editCustomModel(_ definition: CustomModelDefinition) {
        state.expandedRouteKeyDescription = nil
        pendingDeleteCustomModelID = nil
        editingCustomModel = definition
        customModelEditorID = UUID()
        withAnimation(panelTransitionAnimation) {
            isAddingCustomModel = true
        }
    }

    private func closeCustomModelEditor() {
        withAnimation(panelTransitionAnimation) {
            isAddingCustomModel = false
        }
    }

    private var modelList: some View {
        let keys = state.routeKeysForCurrentApp()
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if keys.isEmpty {
                            emptyState
                        } else {
                            ForEach(keys, id: \.description) { key in
                                modelRow(
                                    key,
                                    proxy: proxy
                                )
                            }
                        }
                        addCustomModelEntry
                    }
                    .padding(2)
                    .padding(.bottom, bottomPaddingForExpandedRow(viewportHeight: geometry.size.height))
                }
                .onChange(of: state.expandedRouteKeyDescription) { _, description in
                    guard let description else {
                        expandedScrollRequestID = UUID()
                        if let allowanceDescription = expandedTopScrollAllowanceDescription,
                           keys.contains(where: { $0.description == allowanceDescription }) {
                            withAnimation(collapsedRowAnimation) {
                                expandedTopScrollAllowanceDescription = nil
                                proxy.scrollTo(allowanceDescription, anchor: .bottom)
                            }
                        } else {
                            expandedTopScrollAllowanceDescription = nil
                        }
                        return
                    }
                    scheduleExpandedRowScroll(
                        proxy: proxy,
                        description: description,
                        keys: keys,
                        viewportHeight: geometry.size.height
                    )
                }
                .onChange(of: geometry.size.height) { _, height in
                    guard let description = state.expandedRouteKeyDescription else {
                        return
                    }
                    scheduleExpandedRowScroll(
                        proxy: proxy,
                        description: description,
                        keys: keys,
                        viewportHeight: height
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.12), value: state.currentAppType)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleExpandedRowScroll(
        proxy: ScrollViewProxy,
        description: String,
        keys: [ModelRouteKey],
        viewportHeight: CGFloat
    ) {
        guard let target = scrollTarget(
            for: description,
            in: keys,
            viewportHeight: viewportHeight
        ) else {
            return
        }

        let requestID = UUID()
        expandedScrollRequestID = requestID
        let scrollsToModelTop = target.id == description
        if scrollsToModelTop {
            expandedTopScrollAllowanceDescription = description
        } else {
            withAnimation(expandedRowAnimation) {
                expandedTopScrollAllowanceDescription = nil
            }
        }

        Task { @MainActor in
            if !scrollsToModelTop {
                try? await Task.sleep(nanoseconds: 120_000_000)
            } else {
                await Task.yield()
            }
            guard
                expandedScrollRequestID == requestID,
                state.expandedRouteKeyDescription == description
            else {
                return
            }

            scrollExpandedRow(proxy: proxy, target: target)

            guard !scrollsToModelTop else {
                return
            }
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard
                expandedScrollRequestID == requestID,
                state.expandedRouteKeyDescription == description
            else {
                return
            }
            scrollExpandedRow(proxy: proxy, target: target)
        }
    }

    private func scrollExpandedRow(
        proxy: ScrollViewProxy,
        target: (id: String, anchor: UnitPoint)
    ) {
        withAnimation(expandedRowAnimation) {
            proxy.scrollTo(target.id, anchor: target.anchor)
        }
    }

    private func scrollTarget(
        for description: String,
        in keys: [ModelRouteKey],
        viewportHeight: CGFloat
    ) -> (id: String, anchor: UnitPoint)? {
        guard let key = keys.first(where: { $0.description == description }) else {
            return nil
        }
        let expandedHeight = estimatedExpandedRowHeight(for: key)
        if expandedHeight < viewportHeight - 12 {
            return (expandedBottomID(for: key), .bottom)
        }
        return (key.description, .top)
    }

    private func estimatedExpandedRowHeight(for key: ModelRouteKey) -> CGFloat {
        let providerCount = CGFloat(state.candidates(for: key).count)
        let modelHeaderHeight: CGFloat = 56
        let providerRowHeight: CGFloat = 45
        let providerRowSpacing: CGFloat = 2
        let providerPanelPadding: CGFloat = 8
        let providerPanelBottomPadding: CGFloat = 8
        let bottomAnchorHeight: CGFloat = 1
        let safetyMargin: CGFloat = 8
        let providerRowsHeight = providerCount * providerRowHeight + max(providerCount - 1, 0) * providerRowSpacing
        return modelHeaderHeight
            + providerRowsHeight
            + providerPanelPadding
            + providerPanelBottomPadding
            + bottomAnchorHeight
            + safetyMargin
    }

    private func expandedBottomID(for key: ModelRouteKey) -> String {
        "\(key.description)::expanded-bottom"
    }

    private func bottomPaddingForExpandedRow(viewportHeight: CGFloat) -> CGFloat {
        guard
            let description = expandedTopScrollAllowanceDescription,
            let key = state.routeKeysForCurrentApp().first(where: { $0.description == description }),
            estimatedExpandedRowHeight(for: key) >= viewportHeight - 12
        else {
            return 10
        }
        return max(viewportHeight - estimatedCollapsedRowHeight, 10)
    }

    private var estimatedCollapsedRowHeight: CGFloat {
        70
    }

    private func toggleExpandedRow(
        _ key: ModelRouteKey,
        isExpanded: Bool,
        proxy: ScrollViewProxy
    ) {
        if isExpanded {
            expandedScrollRequestID = UUID()
            if expandedTopScrollAllowanceDescription == key.description {
                withAnimation(collapsedRowAnimation) {
                    state.toggleExpanded(key)
                    expandedTopScrollAllowanceDescription = nil
                    proxy.scrollTo(key.description, anchor: .bottom)
                }
            } else {
                withAnimation(collapsedRowAnimation) {
                    state.toggleExpanded(key)
                }
            }
            return
        }

        withAnimation(expandedRowAnimation) {
            state.toggleExpanded(key)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(UGPopoverStyle.textSecondary)
            Text("没有可显示的模型")
                .font(.system(size: 13, weight: .medium))
            Text("检查设置里的可见模型，或重新加载 cc-switch DB。")
                .font(.system(size: 11))
                .foregroundStyle(UGPopoverStyle.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var addCustomModelEntry: some View {
        Button {
            openCustomModelEditor()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("自定义模型")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(brand)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(UGPopoverStyle.brandSoftFill(brand))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        brand.opacity(0.44),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 5], dashPhase: 0)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("新增自定义模型")
    }

    private func modelRow(
        _ key: ModelRouteKey,
        proxy: ScrollViewProxy
    ) -> some View {
        let candidates = state.candidates(for: key)
        let active = state.activeCandidate(for: key)
        let isExpanded = state.isExpanded(key)
        let isOperable = state.isRouteOperable(key)
        let canSwitchProvider = isOperable && candidates.count > 1
        let showsExpandedProviders = isExpanded && canSwitchProvider
        let customModel = state.customModel(for: key)
        let isConfirmingDelete = customModel?.id == pendingDeleteCustomModelID
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.logicalModel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isOperable ? .primary : UGPopoverStyle.textDisabled)
                            .lineLimit(1)
                        Text(state.modelDetailText(for: key))
                            .font(.caption)
                            .foregroundStyle(UGPopoverStyle.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isOperable {
                        providerTag(
                            active?.providerName ?? "未选择",
                            isExpanded: showsExpandedProviders,
                            canSwitchProvider: canSwitchProvider
                        )
                    } else {
                        disabledRouteTag(for: key)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canSwitchProvider else {
                        return
                    }
                    toggleExpandedRow(
                        key,
                        isExpanded: isExpanded,
                        proxy: proxy
                    )
                }

                if let customModel {
                    customModelMenu(customModel)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(key.description)

            if showsExpandedProviders {
                providerList(candidates: candidates, routeKey: key)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                Color.clear
                    .frame(height: 1)
                    .id(expandedBottomID(for: key))
            }

            if let customModel, isConfirmingDelete {
                deleteConfirmation(for: customModel)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(showsExpandedProviders ? UGPopoverStyle.cardFillStrong : UGPopoverStyle.cardFill)
                .strokeBorder(showsExpandedProviders ? brand.opacity(0.42) : disabledAwareBorder(isOperable), lineWidth: 1)
                .shadow(color: UGPopoverStyle.cardShadowColor, radius: 5, x: 0, y: 6)
        )
        .opacity(isOperable ? 1 : 0.72)
    }

    private func customModelMenu(_ definition: CustomModelDefinition) -> some View {
        Menu {
            Button("编辑") {
                editCustomModel(definition)
            }
            Button("删除...", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    pendingDeleteCustomModelID = definition.id
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UGPopoverStyle.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("自定义模型操作")
    }

    private func deleteConfirmation(for definition: CustomModelDefinition) -> some View {
        HStack(spacing: 8) {
            Text("删除这个自定义模型？")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UGPopoverStyle.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("取消") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    pendingDeleteCustomModelID = nil
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))

            Button("删除") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    pendingDeleteCustomModelID = nil
                }
                state.deleteCustomModel(definition)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(UGPopoverStyle.destructive)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(UGPopoverStyle.deleteConfirmFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UGPopoverStyle.deleteConfirmBorder))
    }

    private func providerTag(_ title: String, isExpanded: Bool, canSwitchProvider: Bool) -> some View {
        let accent = providerAccentColor(for: title)
        return HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if canSwitchProvider {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent.opacity(0.82))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .padding(.horizontal, 9)
        .frame(width: providerTagWidth, height: 24, alignment: .leading)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .help(canSwitchProvider ? "切换供应商" : "只有一个供应商，无需切换")
    }

    private func disabledRouteTag(for key: ModelRouteKey) -> some View {
        let title: String
        switch state.customModelAvailability(for: key) {
        case .missingTarget:
            title = "目标失效"
        case .unconfigured:
            title = "未配置"
        case .configured, nil:
            title = "不可用"
        }
        return Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(UGPopoverStyle.textSecondary)
            .lineLimit(1)
            .frame(width: providerTagWidth, height: 24)
            .background(UGPopoverStyle.disabledTagFill, in: RoundedRectangle(cornerRadius: 6))
    }

    private func disabledAwareBorder(_ isOperable: Bool) -> Color {
        isOperable ? UGPopoverStyle.cardBorder : UGPopoverStyle.disabledBorder
    }

    private func providerAccentColor(for providerName: String) -> Color {
        let palette = UGPopoverStyle.providerAccentPalette
        guard !palette.isEmpty else {
            return brand
        }
        let index = stableHash(providerName) % palette.count
        return palette[index]
    }

    private func stableHash(_ text: String) -> Int {
        var value = 0
        for scalar in text.unicodeScalars {
            value = ((value &* 31) &+ Int(scalar.value)) & 0x7fffffff
        }
        return value
    }

    private func providerList(candidates: [ModelCandidate], routeKey: ModelRouteKey) -> some View {
        VStack(spacing: 6) {
            VStack(spacing: 2) {
                providerRows(candidates: candidates, routeKey: routeKey)
            }
            .padding(4)
        }
        .background(UGPopoverStyle.expandedPanelFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(UGPopoverStyle.expandedPanelBorder))
    }

    @ViewBuilder
    private func providerRows(candidates: [ModelCandidate], routeKey: ModelRouteKey) -> some View {
        ForEach(candidates) { candidate in
            providerOptionRow(candidate, routeKey: routeKey)
        }
    }

    private func providerOptionRow(_ candidate: ModelCandidate, routeKey: ModelRouteKey) -> some View {
        let selected = state.isActive(candidate, for: routeKey)
        return Button {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.90)) {
                state.switchProvider(routeKey: routeKey, providerRef: candidate.providerRef)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.providerName)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? brand : .primary)
                        .lineLimit(1)
                    Text(providerDetail(candidate))
                        .font(.caption2)
                        .foregroundStyle(UGPopoverStyle.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(brand)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? UGPopoverStyle.brandSelectionFill(brand) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func providerDetail(_ candidate: ModelCandidate) -> String {
        var parts: [String] = []
        if candidate.upstreamModel != candidate.logicalModel {
            parts.append(candidate.upstreamModel)
        }
        parts.append(candidate.requiresTransform ? "需要转换" : candidate.apiFormat.rawValue)
        return parts.joined(separator: " · ")
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.28)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                triggerReload()
            } label: {
                HStack(spacing: 6) {
                    reloadIndicator
                        .frame(width: 14, height: 14)
                    Text("reload")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(UGPopoverStyle.neutralActionText)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("重新加载 cc-switch DB")

            Spacer()

            Button {
                state.openAppFolder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("打开应用文件夹")

            Button {
                state.quit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("退出")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func iconName(for appType: String) -> String {
        switch appType {
        case "codex":
            return "terminal"
        case "claude":
            return "chevron.left.forwardslash.chevron.right"
        case "claude-desktop":
            return "desktopcomputer"
        case "gemini":
            return "sparkles"
        default:
            return "app"
        }
    }
}

private struct DottedSpinner: View {
    @State private var phase = 0.0

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .fill(UGPopoverStyle.neutralActionText.opacity(0.28 + Double(index) * 0.07))
                    .frame(width: 3, height: 3)
                    .offset(y: -5)
                    .rotationEffect(.degrees(Double(index) * 45 + phase))
            }
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                phase = 360
            }
        }
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct InlineSettingsPanel: View {
    @Environment(\.ugBrandColor) private var brand
    @ObservedObject var model: SettingsViewModel
    let loadError: String?
    @State private var applyTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field {
        case port
        case databasePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    themeSettingsCard
                    generalSettingsCard
                    endpointCard
                }
                .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(UGPopoverStyle.cardFillStrong, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGPopoverStyle.cardBorder))
                    .shadow(color: UGPopoverStyle.cardShadowColor, radius: 12, x: 0, y: 7)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.portText) { _, _ in
            scheduleApply()
        }
        .onChange(of: model.ccSwitchDBPathText) { _, _ in
            scheduleApply()
        }
        .onDisappear {
            applyTask?.cancel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置")
                .font(.system(size: 16, weight: .semibold))
            Text("本地代理与 cc-switch 接入")
                .font(.caption)
                .foregroundStyle(UGPopoverStyle.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var themeSettingsCard: some View {
        settingsCard {
            HStack(spacing: 12) {
                Text("主题色")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)
                themeColorPicker
            }
        }
    }

    private var generalSettingsCard: some View {
        settingsCard {
            VStack(spacing: 0) {
                settingRow(title: "代理端口", detail: "127.0.0.1") {
                    TextField("17888", text: $model.portText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 8)
                        .frame(width: 92, height: 28)
                        .focused($focusedField, equals: .port)
                        .background(fieldFill(isFocused: focusedField == .port), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(fieldBorder(isFocused: focusedField == .port, cornerRadius: 6))
                        .onSubmit(applyNow)
                }

                Divider()
                    .padding(.vertical, 10)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("数据库文件路径")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("cc-switch")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(UGPopoverStyle.neutralActionText)
                    }

                    TextField(AppPreferences.defaultCcSwitchDBPath(), text: $model.ccSwitchDBPathText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .focused($focusedField, equals: .databasePath)
                        .background(fieldFill(isFocused: focusedField == .databasePath), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(fieldBorder(isFocused: focusedField == .databasePath, cornerRadius: 6))
                        .onSubmit(applyNow)

                    if let loadError {
                        inlineFieldError(loadError)
                            .padding(.top, 7)
                    }
                }

                if let validationText = model.generalSettingsValidationText {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(validationText)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }
            }
        }
    }

    private var endpointCard: some View {
        settingsCard(spacing: 0) {
            endpointRow(title: "Codex", path: "/codex", canImport: true)
            Divider()
                .padding(.vertical, 8)
            endpointRow(title: "Claude Code", path: "/claude-code", canImport: true)
            Divider()
                .padding(.vertical, 8)
            endpointRow(title: "Claude Desktop", path: "/claude-desktop", canImport: false)
        }
    }

    private func settingRow<Control: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(UGPopoverStyle.textSecondary)
            }

            Spacer(minLength: 8)
            control()
        }
    }

    private func endpointRow(title: String, path: String, canImport: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(model.baseURL(path: path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(UGPopoverStyle.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if canImport {
                    compactAction("导入", systemImage: "square.and.arrow.down") {
                        model.importToCcSwitch(path: path)
                    }
                }
                compactAction("复制", systemImage: "doc.on.doc") {
                    model.copyBaseURL(path: path)
                }
            }
            .disabled(model.generalSettingsValidationText != nil)
            .opacity(model.generalSettingsValidationText == nil ? 1 : 0.45)
        }
    }

    private func compactAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UGPopoverStyle.neutralActionText)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(UGPopoverStyle.neutralActionFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(UGPopoverStyle.neutralActionBorder))
        }
        .buttonStyle(.plain)
    }

    private var themeColorPicker: some View {
        HStack(spacing: 6) {
            ForEach(BrandColorPreset.allCases) { preset in
                let selected = model.brandColor == preset
                let color = BrandColorPalette.color(for: preset)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.applyBrandColor(preset)
                    }
                } label: {
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(color)
                            .frame(width: selected ? 26 : 22, height: 14)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(color)
                                .frame(width: 12)
                        }
                    }
                    .padding(.horizontal, selected ? 6 : 4)
                    .frame(height: 24)
                    .background(selected ? color.opacity(0.13) : UGPopoverStyle.tabFill, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(selected ? color.opacity(0.58) : UGPopoverStyle.inputFieldBorder, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(BrandColorPalette.label(for: preset))
            }
        }
    }

    private func fieldFill(isFocused: Bool) -> Color {
        isFocused ? UGPopoverStyle.inputFieldFocusedFill : UGPopoverStyle.inputFieldFill
    }

    private func fieldBorder(isFocused: Bool, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(isFocused ? brand.opacity(0.54) : UGPopoverStyle.inputFieldBorder, lineWidth: 1)
    }

    private func inlineFieldError(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsCard<Content: View>(
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UGPopoverStyle.cardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGPopoverStyle.cardBorder))
        .shadow(color: UGPopoverStyle.cardShadowColor, radius: 5, x: 0, y: 6)
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else {
                return
            }
            _ = model.applyGeneralSettings()
        }
    }

    private func applyNow() {
        applyTask?.cancel()
        _ = model.applyGeneralSettings()
    }
}

private struct InlineCustomModelEditorView: View {
    @Environment(\.ugBrandColor) private var brand
    let onSave: (CustomModelDefinition) -> Void
    let onCancel: () -> Void

    private let existing: CustomModelDefinition?
    private let candidates: [ModelCandidate]
    private let appTypes: [String]
    private let existingTargetsByKey: [String: CustomModelTarget]

    @State private var name: String
    @State private var appType: String
    @State private var selectedTargetIDs: Set<String>
    @State private var currentTargetID: String

    init(
        candidates: [ModelCandidate],
        existing: CustomModelDefinition?,
        initialAppType: String?,
        onSave: @escaping (CustomModelDefinition) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let sortedCandidates = candidates.sorted {
            [$0.appType, $0.logicalModel, $0.providerName].joined(separator: "\u{0}")
                .localizedStandardCompare([$1.appType, $1.logicalModel, $1.providerName].joined(separator: "\u{0}")) == .orderedAscending
        }
        let sortedAppTypes = Array(Set(sortedCandidates.map(\.appType))).sorted {
            ProviderDisplay.appTypeLabel($0)
                .localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
        let appTypesWithExisting = Array(Set(sortedAppTypes + [existing?.appType].compactMap { $0 })).sorted {
            ProviderDisplay.appTypeLabel($0)
                .localizedStandardCompare(ProviderDisplay.appTypeLabel($1)) == .orderedAscending
        }
        let targetIDs = Set(existing?.targets.map(Self.targetID) ?? [])
        let initial = existing?.appType
            ?? initialAppType.flatMap { appTypesWithExisting.contains($0) ? $0 : nil }
            ?? appTypesWithExisting.first
            ?? ""
        let initialTargetID = existing?.selectedTarget.map(Self.targetID) ?? targetIDs.sorted().first ?? ""

        self.existing = existing
        self.candidates = sortedCandidates
        self.appTypes = appTypesWithExisting
        self.existingTargetsByKey = Dictionary(
            uniqueKeysWithValues: (existing?.targets ?? []).map { (Self.targetID($0), $0) }
        )
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: existing?.name ?? "")
        _appType = State(initialValue: initial)
        _selectedTargetIDs = State(initialValue: targetIDs)
        _currentTargetID = State(initialValue: initialTargetID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                form
                    .padding(.trailing, 4)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: appType) { _, _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTargetIDs.removeAll()
                currentTargetID = ""
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(existing == nil ? "自定义模型" : "编辑自定义模型")
                .font(.system(size: 16, weight: .semibold))
            Text(existing == nil ? "为新模型选择应用和一个或多个转发目标。" : "调整模型名、应用和转发目标。")
                .font(.caption)
                .foregroundStyle(UGPopoverStyle.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorField(title: "模型名") {
                TextField("例如 customer_model", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            editorField(title: "应用") {
                appTypeSelector
            }

            editorField(title: "默认转发目标") {
                Picker("", selection: $currentTargetID) {
                    if selectedCandidates.isEmpty {
                        Text("先选择目标").tag("")
                    }
                    ForEach(selectedCandidates) { candidate in
                        Text(targetTitle(candidate)).tag(targetID(candidate))
                    }
                }
                .labelsHidden()
                .disabled(selectedCandidates.isEmpty)
                .frame(width: 280, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("转发目标")
                        .font(.system(size: 12, weight: .medium))
                    Text("\(selectedCandidates.count) 已选")
                        .font(.caption2)
                        .foregroundStyle(UGPopoverStyle.textSecondary)
                    Spacer()
                }

                targetList
            }
        }
    }

    private func editorField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UGPopoverStyle.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appTypeSelector: some View {
        HStack(spacing: 6) {
            ForEach(appTypes, id: \.self) { item in
                let selected = appType == item
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        appType = item
                    }
                } label: {
                    Text(ProviderDisplay.appTypeLabel(item))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? .white : UGPopoverStyle.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            Capsule()
                                .fill(selected ? brand : UGPopoverStyle.tabFill)
                        )
                        .overlay(
                            Capsule()
                                .stroke(selected ? Color.clear : UGPopoverStyle.tabBorder)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var targetList: some View {
        LazyVStack(spacing: 6) {
            if filteredCandidates.isEmpty {
                emptyTargetState
            } else {
                ForEach(filteredCandidates) { candidate in
                    targetRow(candidate)
                }
            }
        }
        .padding(6)
        .background(UGPopoverStyle.cardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(UGPopoverStyle.cardBorder))
    }

    private var emptyTargetState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(UGPopoverStyle.textSecondary)
            Text("没有可用目标")
                .font(.system(size: 12, weight: .medium))
            Text("当前应用下没有可作为自定义模型目标的基础模型。")
                .font(.caption2)
                .foregroundStyle(UGPopoverStyle.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func targetRow(_ candidate: ModelCandidate) -> some View {
        let id = targetID(candidate)
        let selected = selectedTargetIDs.contains(id)
        let isDefault = currentTargetID == id && selected
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                setTarget(id, selected: !selected)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? brand : UGPopoverStyle.textSecondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(targetTitle(candidate))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(targetDetail(candidate))
                        .font(.caption2)
                        .foregroundStyle(UGPopoverStyle.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isDefault {
                    Text("默认")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(brand)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? UGPopoverStyle.brandSelectionFill(brand) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("取消") {
                onCancel()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 30)

            Spacer()

            Button {
                save()
            } label: {
                Text("保存")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSave ? .white : UGPopoverStyle.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(canSave ? brand : UGPopoverStyle.tabFill, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
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
            id: existing?.id ?? UUID(),
            appType: appType,
            name: trimmedName,
            targets: targets,
            selectedTargetID: selectedTargetID
        ))
    }

    private func targetID(_ candidate: ModelCandidate) -> String {
        "\(candidate.routeKey.description)|\(candidate.providerRef.description)"
    }

    private static func targetID(_ target: CustomModelTarget) -> String {
        "\(target.routeKey.description)|\(target.providerRef.description)"
    }

    private func targetTitle(_ candidate: ModelCandidate) -> String {
        "\(candidate.logicalModel) · \(candidate.providerName)"
    }

    private func targetDetail(_ candidate: ModelCandidate) -> String {
        var parts = [candidate.upstreamModel]
        if candidate.requiresTransform {
            parts.append("需要转换")
        } else {
            parts.append(candidate.apiFormat.rawValue)
        }
        return parts.joined(separator: " · ")
    }
}

private enum UGPopoverStyle {
    static let cardFill = adaptive(light: Color.white.opacity(0.68), dark: Color.black.opacity(0.21))
    static let cardFillStrong = adaptive(light: Color.white.opacity(0.82), dark: Color.black.opacity(0.28))
    static let cardBorder = adaptive(light: Color.black.opacity(0.11), dark: Color.white.opacity(0.20))
    static let disabledBorder = adaptive(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.12))
    static let disabledTagFill = adaptive(light: Color.black.opacity(0.055), dark: Color.white.opacity(0.075))
    static let destructive = adaptive(light: Color.red.opacity(0.82), dark: Color.red.opacity(0.76))
    static let deleteConfirmFill = adaptive(light: Color.red.opacity(0.055), dark: Color.red.opacity(0.11))
    static let deleteConfirmBorder = adaptive(light: Color.red.opacity(0.18), dark: Color.red.opacity(0.24))
    static let expandedPanelFill = adaptive(light: Color.black.opacity(0.045), dark: Color.white.opacity(0.075))
    static let expandedPanelBorder = adaptive(light: Color.black.opacity(0.055), dark: Color.white.opacity(0.10))
    static let inputFieldFill = adaptive(light: Color.black.opacity(0.035), dark: Color.white.opacity(0.065))
    static let inputFieldFocusedFill = adaptive(light: Color.white.opacity(0.42), dark: Color.white.opacity(0.085))
    static let inputFieldBorder = adaptive(light: Color.black.opacity(0.11), dark: Color.white.opacity(0.16))
    static let neutralActionText = adaptive(light: Color.black.opacity(0.72), dark: Color.white.opacity(0.72))
    static let neutralActionFill = adaptive(light: Color.black.opacity(0.045), dark: Color.white.opacity(0.075))
    static let neutralActionBorder = adaptive(light: Color.black.opacity(0.10), dark: Color.white.opacity(0.14))
    static let tabFill = adaptive(light: Color.white.opacity(0.36), dark: Color.black.opacity(0.21))
    static let tabBorder = adaptive(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.20))
    static let issueBubbleFill = adaptive(light: Color.orange.opacity(0.10), dark: Color.orange.opacity(0.16))
    static let issueBubbleBorder = adaptive(light: Color.orange.opacity(0.24), dark: Color.orange.opacity(0.28))
    static let textSecondary = adaptive(light: Color.secondary, dark: Color.white.opacity(0.55))
    static let textDisabled = adaptive(light: Color.black.opacity(0.42), dark: Color.white.opacity(0.34))
    static let cardShadowColor = adaptive(light: Color.black.opacity(0.14), dark: Color.black.opacity(0.10))
    static let providerAccentPalette = [
        Color(red: 0.24, green: 0.48, blue: 0.86),
        Color(red: 0.17, green: 0.55, blue: 0.42),
        Color(red: 0.74, green: 0.38, blue: 0.18),
        Color(red: 0.51, green: 0.40, blue: 0.78),
        Color(red: 0.66, green: 0.30, blue: 0.47),
        Color(red: 0.18, green: 0.55, blue: 0.66)
    ]

    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }

    static func brandSoftFill(_ brand: Color) -> Color {
        brand.opacity(0.08)
    }

    static func brandSelectionFill(_ brand: Color) -> Color {
        brand.opacity(0.14)
    }
}
