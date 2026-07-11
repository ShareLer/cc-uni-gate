import Foundation

public enum ConfigurationHealthSeverity: String, Codable, Sendable, Comparable {
    case ok
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .ok:
            return 0
        case .info:
            return 1
        case .warning:
            return 2
        case .error:
            return 3
        }
    }

    public static func < (lhs: ConfigurationHealthSeverity, rhs: ConfigurationHealthSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct ConfigurationHealthItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var severity: ConfigurationHealthSeverity
    public var appType: String?
    public var title: String
    public var detail: String
    public var actionTitle: String?

    public init(
        id: String,
        severity: ConfigurationHealthSeverity,
        appType: String? = nil,
        title: String,
        detail: String,
        actionTitle: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.appType = appType
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
    }
}

public struct ConfigurationHealthReport: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var items: [ConfigurationHealthItem]

    public init(generatedAt: Date = Date(), items: [ConfigurationHealthItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }

    public var worstSeverity: ConfigurationHealthSeverity {
        items.map(\.severity).max() ?? .ok
    }

    public var blockingItems: [ConfigurationHealthItem] {
        items.filter { $0.severity == .error || $0.severity == .warning }
    }

    public var summaryTitle: String {
        switch worstSeverity {
        case .ok:
            return "运行正常"
        case .info:
            return "有提示"
        case .warning:
            return "需要检查"
        case .error:
            return "存在异常"
        }
    }

    public static func build(
        databasePath: String,
        databaseExists: Bool,
        catalogLoadError: String?,
        proxySeverity: ConfigurationHealthSeverity,
        proxyDetail: String,
        catalog: ProviderCatalog,
        routes: RouteState,
        customModels: CustomModelState,
        uniGateModelScope: UniGateModelScope,
        integration: CcSwitchIntegrationSnapshot?,
        now: Date = Date()
    ) -> ConfigurationHealthReport {
        var items: [ConfigurationHealthItem] = []

        if databaseExists {
            items.append(ConfigurationHealthItem(
                id: "db-readable",
                severity: catalogLoadError == nil ? .ok : .error,
                title: catalogLoadError == nil ? "cc-switch 数据库可读" : "cc-switch 数据库读取失败",
                detail: catalogLoadError ?? databasePath,
                actionTitle: catalogLoadError == nil ? nil : "检查路径"
            ))
        } else {
            items.append(ConfigurationHealthItem(
                id: "db-missing",
                severity: .error,
                title: "cc-switch 数据库不存在",
                detail: databasePath,
                actionTitle: "检查路径"
            ))
        }

        let proxyTitle: String
        let proxyAction: String?
        switch proxySeverity {
        case .ok:
            proxyTitle = "本地代理已运行"
            proxyAction = nil
        case .info:
            proxyTitle = "本地代理状态提示"
            proxyAction = nil
        case .warning:
            proxyTitle = "本地代理运行但有提示"
            proxyAction = "查看详情"
        case .error:
            proxyTitle = "本地代理未就绪"
            proxyAction = "重新加载"
        }
        items.append(ConfigurationHealthItem(
            id: "proxy-status",
            severity: proxySeverity,
            title: proxyTitle,
            detail: proxyDetail,
            actionTitle: proxyAction
        ))

        for appType in UniGateAppRegistry.uniGateScopedAppTypes {
            let appName = ProviderDisplay.appTypeLabel(appType)
            if let provider = integration?.uniGateProvider(appType: appType) {
                let severity: ConfigurationHealthSeverity = provider.configuredModels.isEmpty ? .warning : .ok
                items.append(ConfigurationHealthItem(
                    id: "unigate-provider-\(appType)",
                    severity: severity,
                    appType: appType,
                    title: "\(appName) 已接入 Uni Gate",
                    detail: provider.configuredModels.isEmpty
                        ? "已找到 UniGate 供应商，但模型清单为空"
                        : "已配置 \(provider.configuredModels.count) 个模型",
                    actionTitle: severity == .ok ? nil : "补充模型"
                ))

                if !provider.isCurrent {
                    items.append(ConfigurationHealthItem(
                        id: "unigate-current-\(appType)",
                        severity: .info,
                        appType: appType,
                        title: "\(appName) 当前供应商不是 Uni Gate",
                        detail: "如果客户端仍通过 cc-switch 请求，需要在 cc-switch 中选择 UniGate 供应商。",
                        actionTitle: "打开 cc-switch"
                    ))
                }
            } else {
                items.append(ConfigurationHealthItem(
                    id: "unigate-provider-missing-\(appType)",
                    severity: appType == UniGateAppRegistry.claudeDesktop ? .warning : .error,
                    appType: appType,
                    title: "\(appName) 未导入 Uni Gate",
                    detail: "cc-switch 中没有检测到指向 Uni Gate 本地代理的供应商。",
                    actionTitle: appType == UniGateAppRegistry.claudeDesktop ? "查看说明" : "导入"
                ))
            }
        }

        let desktopProviders = integration?.providers(appType: UniGateAppRegistry.claudeDesktop) ?? []
        if desktopProviders.contains(where: \.hasClaudeDesktopRoutes) {
            items.append(ConfigurationHealthItem(
                id: "desktop-routes",
                severity: .ok,
                appType: UniGateAppRegistry.claudeDesktop,
                title: "Claude Desktop 已开启模型映射",
                detail: "已检测到 claudeDesktopModelRoutes。"
            ))
        } else {
            items.append(ConfigurationHealthItem(
                id: "desktop-routes-missing",
                severity: .warning,
                appType: UniGateAppRegistry.claudeDesktop,
                title: "Claude Desktop 需开启模型映射",
                detail: "未检测到 claudeDesktopModelRoutes，Uni Gate 无法稳定按真实模型路由。",
                actionTitle: "查看说明"
            ))
        }

        if catalog.candidates.isEmpty {
            items.append(ConfigurationHealthItem(
                id: "candidate-empty",
                severity: .error,
                title: "没有可路由模型",
                detail: "当前 cc-switch 配置没有导入任何可用模型候选。",
                actionTitle: "检查 cc-switch"
            ))
        }

        for appType in UniGateAppRegistry.uniGateScopedAppTypes where !uniGateModelScope.hasModels(for: appType) {
            items.append(ConfigurationHealthItem(
                id: "scope-empty-\(appType)",
                severity: .warning,
                appType: appType,
                title: "\(ProviderDisplay.appTypeLabel(appType)) 可见模型清单为空",
                detail: "UniGate 自供应商中没有配置模型清单，客户端可能看不到可切换模型。",
                actionTitle: "补充模型"
            ))
        }

        for definition in customModels.models {
            let routeKey = ModelRouteKey(appType: definition.appType, logicalModel: definition.name)
            if customModels.nameConflict(
                for: definition,
                in: catalog,
                uniGateModelScope: uniGateModelScope
            ) == .baseModel {
                items.append(ConfigurationHealthItem(
                    id: "custom-name-conflict-\(routeKey.description)",
                    severity: .warning,
                    appType: definition.appType,
                    title: "自定义模型名称冲突",
                    detail: "\(definition.name) 与当前 cc-switch 基础模型重名，请重命名自定义模型。",
                    actionTitle: "重命名"
                ))
            }
            if let selectedTarget = definition.selectedTargetCandidate(in: catalog) {
                if selectedTarget.isDiscoveryStale(in: catalog) {
                    items.append(ConfigurationHealthItem(
                        id: "custom-target-stale-\(routeKey.description)",
                        severity: .warning,
                        appType: definition.appType,
                        title: "自定义模型目标失效",
                        detail: "\(definition.name) 的默认转发目标当前探测失效，仍保留为缓存候选。",
                        actionTitle: "刷新"
                    ))
                }
            } else {
                items.append(ConfigurationHealthItem(
                    id: "custom-target-missing-\(routeKey.description)",
                    severity: .warning,
                    appType: definition.appType,
                    title: "自定义模型目标失效",
                    detail: "\(definition.name) 的默认转发目标在当前 cc-switch 配置中不存在。",
                    actionTitle: "编辑"
                ))
            }
            if !uniGateModelScope.contains(routeKey) && !definition.forceEnabled {
                items.append(ConfigurationHealthItem(
                    id: "custom-unconfigured-\(routeKey.description)",
                    severity: .info,
                    appType: definition.appType,
                    title: "自定义模型未加入 cc-switch 模型清单",
                    detail: "\(definition.name) 可以在 Uni Gate 中切换，但客户端可能无法从 cc-switch 模型列表中看到它。",
                    actionTitle: "补充模型"
                ))
            }
        }

        for (key, route) in routes.routes {
            let candidate = catalog.candidates.first {
                $0.appType == route.appType
                    && $0.logicalModel == route.logicalModel
                    && $0.providerRef == route.providerRef
            }
            if let candidate, candidate.isDiscoveryStale(in: catalog) {
                items.append(ConfigurationHealthItem(
                    id: "route-stale-\(key)",
                    severity: .warning,
                    appType: route.appType,
                    title: "路由指向的模型探测失效",
                    detail: "\(key) -> \(route.providerRef.description) 的上次成功结果已失效。",
                    actionTitle: "刷新"
                ))
            } else if candidate == nil {
                items.append(ConfigurationHealthItem(
                    id: "route-invalid-\(key)",
                    severity: .warning,
                    appType: route.appType,
                    title: "路由指向的供应商已失效",
                    detail: "\(key) -> \(route.providerRef.description) 不在当前候选中。",
                    actionTitle: "重置路由"
                ))
            }
        }

        if items.allSatisfy({ $0.severity == .ok }) {
            items.append(ConfigurationHealthItem(
                id: "all-good",
                severity: .ok,
                title: "配置检查通过",
                detail: "未发现需要处理的问题。"
            ))
        }

        return ConfigurationHealthReport(generatedAt: now, items: items)
    }
}
