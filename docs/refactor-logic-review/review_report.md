---
## 2026-06-20 - Popover Settings Refactor Review

## 重构逻辑一致性报告

### 修改概览
- `Sources/UniGateApp/UniGatePopoverView.swift`: 新增内嵌设置页、主题色设置、自定义模型编辑 UI。
- `Sources/UniGateApp/SettingsView.swift`: `SettingsViewModel` 被内嵌设置页复用；旧独立设置页视图仍保留。
- `Sources/UniGateApp/UniGateAppState.swift`: 新增 settings screen 状态、模型列表交互排序、自定义模型可用性判断。
- `Sources/UniGateApp/main.swift`: 设置保存和实时应用统一走 `persistSettings`。

### 改动对照表

| 修改点 | 重构前逻辑行为 | 重构后逻辑行为 | 逻辑分支等价性 | 测试验证 | 依据 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| 独立设置页迁移到 popover | 用户通过独立 `SettingsRootView` 管理通用/模型/供应商设置 | popover 只调用 `InlineSettingsPanel`，旧 `SettingsRootView`、`CustomModelEditorView`、搜索和供应商设置 UI 无入口 | 不等价 | 静态搜索验证旧 view 无调用点 | 产品方向改为纯状态栏 UI | ⚠️ 有意为之 (INTENTIONAL) |
| 通用设置实时生效 | 独立设置页点击保存后统一保存 | 内嵌设置页端口/DB 路径输入 debounce 调用 `applyGeneralSettings` | 不等价 | `swift test` 通过；缺少 app 层 UI 状态测试 | 用户要求设置实时生效 | ⚠️ 有意为之 (INTENTIONAL) |
| 主题色实时生效 | 无主题色设置 | `applyBrandColor` 立即持久化主题色 | 不等价 | `PreferencesStoreTests` 覆盖持久化 | 用户要求主题色可设置 | ⚠️ 有意为之 (INTENTIONAL) |
| 自定义模型可用性 | 可见模型过滤会隐藏未配置自定义模型 | 自定义模型始终显示，但未配置/目标失效时不可操作 | 不等价 | 现有 custom model tests 覆盖 catalog 扩展；UI 可用性未单测 | bugfix：保存后看不到自定义模型 | ⚠️ 有意为之 (INTENTIONAL) |
| 模型详情显示 | 上游模型等于逻辑模型时显示 app 名 | 有 active candidate 时始终显示当前上游模型 | 不等价 | `swift test` 通过；缺少 app 层显示测试 | bugfix：`gpt-5.5` 被错误显示为 `Codex` | ⚠️ 有意为之 (INTENTIONAL) |
| 主题色切换与未保存通用设置 | 不存在主题色实时切换路径 | `applyBrandColor` 使用 `preferences.normalizedPort` 和 `preferences.ccSwitchDBPath`，可能丢弃当前未 debounce 保存的输入框文本 | 不等价 | 未覆盖 | 依据不足，存在用户输入回滚风险 | ❌ 存疑差异 (FAIL) |

### 整体结论
- **FAIL**：发现 1 处存疑差异。
- 旧独立设置页视图已经不可达，但代码仍保留，属于维护风险而非当前运行时 bug。
- 内嵌设置页和旧设置页共享 `SettingsViewModel`，但只复用了部分能力，导致 ViewModel 同时承载已废弃页面状态、实时设置状态和自定义模型编辑状态，职责过宽。

### 存疑差异详情

1. `applyBrandColor` 可能回滚正在编辑的通用设置
   - 触发条件：用户在内嵌设置页修改端口或数据库路径后，500ms debounce 尚未调用 `applyGeneralSettings`，立即点击主题色。
   - 当前行为：`applyBrandColor` 构造 `AppPreferences` 时使用旧的 `preferences.normalizedPort` 和 `preferences.ccSwitchDBPath`，没有读取当前 `portText` / `ccSwitchDBPathText`。
   - 风险：主题色保存会触发 `persistSettings` -> `reloadCatalog` -> `SettingsViewModel.update`，输入框可能被旧值覆盖，导致用户刚输入的端口/路径丢失。
   - 建议修复：`applyBrandColor` 应复用当前文本构造 preferences，或在应用主题色前先 flush/cancel pending general settings apply。

### 工程优化建议

1. 删除或隔离旧独立设置页
   - `SettingsRootView`、旧 `CustomModelEditorView`、`UGStyle` 当前无入口。
   - 最小清理方案：删除不可达 view，只保留 `SettingsViewModel` 和内嵌 popover 需要的类型。
   - 更稳妥方案：先把旧 view 移到单独文件并标记待删，再下一步删除。

2. 拆分 `SettingsViewModel`
   - 当前同时管理通用设置、模型可见性、供应商协议覆盖、旧搜索、旧 sheet 编辑器、内嵌设置。
   - 建议拆成 `InlineSettingsViewModel` 或把通用设置实时应用逻辑下沉到更小的 model，避免死字段影响当前 UI。

3. 提取重复的自定义模型编辑逻辑
   - 新旧编辑器都有 targetID、targetTitle、targetDetail、selectedTargetIDs/currentTargetID、save 组装逻辑。
   - 如果旧编辑器删除，重复会自然消失；如果保留，需要提取为非 UI helper，减少两个编辑器行为漂移。

4. 增加 App 层测试入口
   - 当前 SwiftPM 测试只覆盖 `UniGateCore`，`UniGateAppState`、`SettingsViewModel` 的交互逻辑没有单测。
   - 由于 `main.swift` 含顶层 `NSApplication.run()`，直接测试 app target 不方便。建议后续把启动入口拆到单独文件或把状态模型迁到可测试 target。

---
## 2026-06-25 - UniGate 三类 App 逻辑统一复核

## 重构逻辑一致性报告

### 修改概览
- `Sources/UniGateCore/Models.swift`: 新增 `UniGateAppRegistry`，统一 `codex` / `claude` / `claude-desktop` 的 appType 常量、UniGate scope 列表、Claude-like 判定、默认 client protocol、transform 判定。
- `Sources/UniGateCore/ModelRoutingUtilities.swift`: 可见性判断改为委托 `UniGateAppRegistry`。
- `Sources/UniGateCore/CcSwitchImporter.swift`: 四处重复 provider SQL 查询统一到 `loadProviderRows()`，查询 app 范围由 registry 驱动；保留 Codex / Claude Code / Claude Desktop 各自配置解析函数。
- `Sources/UniGateCore/ProviderModelDiscovery.swift`、`Sources/UniGateCore/CustomModelStore.swift`、`Sources/UniGateCore/ProviderCredentials.swift`、`Sources/UniGateCore/ProxyResolver.swift`: 共享协议、transform、Claude-like、默认 app 判定改为使用 registry。
- `Sources/UniGateCore/ConfigurationHealth.swift`、`Sources/UniGateCore/DiagnosticsReport.swift`、`Sources/UniGateApp/LocalProxyServer.swift`: 健康检查/诊断 app 循环与 Codex 判断改为使用 registry。
- `Tests/UniGateCoreTests/UniGateAppRegistryTests.swift`: 新增 registry 契约测试，覆盖 scope、protocol、transform、路径默认 app。

### 改动对照表

| 修改点 | 重构前逻辑行为 | 重构后逻辑行为 | 逻辑分支等价性 | 测试验证 | 依据 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| UniGate scoped app 列表 | `["codex", "claude", "claude-desktop"]` 在健康检查、诊断、SQL 过滤、可见性判断中分散硬编码 | `UniGateAppRegistry.uniGateScopedAppTypes` 作为统一来源 | 等价 | `UniGateAppRegistryTests.scopedAppsDriveRouteVisibility`；`swift test` 111 个测试通过 | 纯去重，集合仍为 codex/claude/claude-desktop | ✅ 完全一致 (PASS) |
| Claude-like 判定 | 多处写 `appType == "claude" || appType == "claude-desktop"` | 统一为 `UniGateAppRegistry.isClaudeLike` | 等价 | `claudeLikeAppsShareProtocolAndTransformRules`；既有 Claude Desktop/Claude Code 路由测试通过 | 两个 Claude app 的协议与 transform 规则相同 | ✅ 完全一致 (PASS) |
| 默认 client protocol | `ProviderModelDiscovery`、`CustomModelStore` 各自 switch：Codex -> responses，Claude 系 -> anthropic | registry 提供同一映射；Gemini/default fallback 保留在调用方 | 等价 | `claudeLikeAppsShareProtocolAndTransformRules`、`codexUsesResponsesProtocolAndOpenAITransformRules`；`swift test` 通过 | 共享规则只覆盖 UniGate 三类 app，非 scoped app 不继承 | ✅ 完全一致 (PASS) |
| transform 判定 | `ModelCandidate.withApiFormat`、discovery、custom missing target 各自实现相同规则 | registry 提供统一 transform 判定；未知 app 仍返回原 fallback | 等价 | 新 registry tests + 既有 bridge/route tests 通过 | 纯函数规则一致：Codex 接受 responses/chat，Claude 系仅接受 anthropic | ✅ 完全一致 (PASS) |
| cc-switch provider 查询 | 四个 load 方法重复相同 SQL，过滤 `claude` / `claude-desktop` / `codex` | 抽成 `loadProviderRows()`，SQL 字段、order by、readonly 配置相同，过滤集合来自 registry | 等价 | `CcSwitchImporterTests` 全部通过；`swift test` 通过 | 去重，不改变查询列、排序或过滤集合 | ✅ 完全一致 (PASS) |
| Proxy path 默认 app | 未带 app prefix 的 Anthropic path 默认 `claude`，Responses/OpenAI Chat 默认 `codex` | 默认值改用 registry 常量 | 等价 | `proxyRequestPathsUseSharedAppTypeDefaults`；既有 proxy path tests 通过 | 常量替换，不改变路径分类 | ✅ 完全一致 (PASS) |
| Claude Code role fallback | 角色兜底只在 `appType == "claude"` 时触发 | 条件改为 `appType == UniGateAppRegistry.claudeCode`，Desktop 仍不触发 | 等价 | 既有 `rejectsClaudeDesktopRequestWhenRealModelRouteIsNotConfigured`、`rejectsClaudeRoleFallbackWhenFableRouteIsAbsentForClaudeCode` 通过 | Desktop 依赖真实 upstream model routes，不能套 Claude Code 角色兜底 | ✅ 完全一致 (PASS) |
| Claude Desktop scope 匹配 | Desktop `UniGateModelScope.contains(candidate)` 按 upstream model 判断；其他 app 按 logical model | 保留该差异，仅替换 Desktop 常量 | 等价 | `visibleConfiguredBaseRouteKeysMatchDesktopScopeByUpstreamModel` 通过 | Desktop cc-switch 模型映射里可见模型是真实 upstream model | ✅ 完全一致 (PASS) |
| Codex `/models` 响应 | Codex 返回扩展 model catalog；Claude 系返回字符串数组 | 仍保留输出差异，仅把 Codex 判断改用 registry 常量 | 等价 | 既有 `modelListingUsesFullCatalogWhileProxyUsesScopedCatalogForEveryApp` 通过 | 客户端协议差异，不应统一输出结构 | ✅ 完全一致 (PASS) |
| 三类 app 配置解析 | Codex 从 config/modelCatalog；Claude Code 从 env；Claude Desktop 从 `claudeDesktopModelRoutes` | 保留三套解析函数，只统一 app 常量和共享推导 | 等价 | `CcSwitchImporterTests` 覆盖三类导入行为并通过 | 数据来源不同，合并会是假统一 | ✅ 完全一致 (PASS) |
| Desktop 健康检查 | Desktop 缺 UniGate provider 降级 warning，额外检查 `claudeDesktopModelRoutes` | 仍保留该差异，仅替换常量 | 等价 | `reportsMissingDesktopRoutesAndCustomModelIssues` 通过 | Desktop 需要额外模型映射配置 | ✅ 完全一致 (PASS) |

### 整体结论
- **PASS**：无 ❌ 存疑差异。
- 已统一的部分是共享 app 属性和纯判定逻辑；保留的分叉都有明确依据，来自客户端协议、cc-switch 配置结构或 Claude Desktop 的真实模型映射机制。
- 验证：`swift test` 111 个测试通过；`git diff --check` 通过。

### 复核说明
- 未启动独立 subagent code review：当前工具约束要求只有用户明确要求 subagent/并行代理时才可 spawn，因此本次采用当前线程只读 diff 自审。
- `docs/bug-reflection/fix_reports.md` 是进入本轮前已存在的未提交改动，本次未修改。

---
## 2026-06-20 - Remove Legacy Settings UI

## 重构逻辑一致性报告

### 修改概览
- `Sources/UniGateApp/SettingsView.swift`: 删除不可达的旧独立设置页 UI，只保留当前 popover 设置页需要的 `SettingsViewModel`。
- `Sources/UniGateApp/UniGateAppState.swift`: 收窄 `SettingsViewModel` 构造和 update 参数，移除旧设置页保存/关闭/status 同步入口。

### 改动对照表

| 修改点 | 重构前逻辑行为 | 重构后逻辑行为 | 逻辑分支等价性 | 测试验证 | 依据 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| 旧独立设置页 UI | `SettingsRootView`、旧 `CustomModelEditorView`、模型搜索、供应商协议覆盖 UI 保留在源码中，但当前产品入口不再调用 | 这些不可达 view 和对应状态字段被移除 | 不等价 | `rg` 确认只剩当前 `InlineCustomModelEditorView`；`swift build` 通过 | 产品已切换为纯状态栏 popover UI，旧独立页无入口 | ⚠️ 有意为之 (INTENTIONAL) |
| 内嵌设置页通用设置 | 通过 `SettingsViewModel` 的端口、DB 路径、主题色字段实时应用 | 保留相同行为，`applyGeneralSettings` 和 `applyBrandColor` 共用当前输入构造 preferences | 等价；主题色路径含 bugfix | `swift test` 44 个测试通过；`git diff --check` 通过 | bugfix：主题色不应覆盖未 debounce 的端口/DB 路径输入 | ⚠️ 有意为之 (INTENTIONAL) |
| 协议覆盖配置 | 旧供应商页可编辑 `protocolOverrides`，当前 popover 无入口但保存时需保留历史配置 | 不再暴露编辑状态，应用设置时原样保留 `preferences.protocolOverrides` | 当前入口等价 | 静态检查构造 preferences 时保留该字段 | 当前需求是移除旧设置页，不是清空历史配置 | ✅ 完全一致 (PASS) |
| 导入 cc-switch 默认模型 | 旧逻辑优先使用可见且可配置模型，避免选择未配置自定义模型 | 精简 ViewModel 仍保留 scope 判断，只用于导入默认模型 | 等价 | `swift build` / `swift test` 通过；分支静态对照 | 默认模型选择是导入功能的业务规则，不属于旧 UI 残留 | ✅ 完全一致 (PASS) |

### 整体结论
- **PASS**：无 ❌ 存疑差异。
- 旧独立设置页相关源码已移除；当前保留的设置逻辑都能追溯到 popover 设置页或 cc-switch 导入功能。
