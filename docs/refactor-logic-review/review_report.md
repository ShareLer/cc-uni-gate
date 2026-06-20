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
