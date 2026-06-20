# Fix Report - Positioned Model Picker Collapse

## Bug 描述
在底部模型展开后，如果为了完整展示供应商列表而自动定位到顶部，点击收起时 provider 区域会先快速收起，前面的模型列表再下滑复位，视觉上像两个串行阶段。

## 根因
展开和收起的滚动副作用没有统一在一个状态事务里：
- 行按钮和 `onChange(expandedRouteKeyDescription)` 都会调度展开滚动，导致一个交互有两个滚动入口。
- 收起时的滚动目标 id 绑定在整张展开卡片上，而不是稳定的主模型 header。provider 区域消失时目标视图高度变化，ScrollView 会先响应内容高度收缩，再补偿滚动位置。

## 尝试记录
- 尝试 1：加长收起动画时长。结果：只能缓解速度感，不能解决先收起再复位的两阶段问题。
- 尝试 2：延迟移除底部滚动 allowance。结果：可以避免部分 clamp，但仍然是串行阶段，前面模型复位不自然。
- 尝试 3：把展开/收起建模为单一路径。结果：成功，重复滚动调度被移除，定位收起时相关状态在同一个动画事务里更新。

## 最终方案
- 点击模型行只切换展开状态，不再手动调度展开滚动。
- `onChange(expandedRouteKeyDescription)` 作为唯一展开定位副作用入口。
- 把模型行的滚动 id 移到主模型 header button 上，避免使用高度变化的整卡片作为滚动锚点。
- 定位过的收起在一个 `withAnimation(collapsedRowAnimation)` 中同时执行：切换展开状态、移除临时底部 allowance、滚动回主模型 header。

## 经验教训
SwiftUI 中滚动、布局和展开动画混在一起时，优先检查 source of truth、scroll anchor 和 transaction 是否一致。不要用不断调 sleep/时长的方式掩盖状态机不一致。

# Fix Report - Claude Code Top-Align Auto Positioning

## Bug 描述
定位收起修复后，Codex 和 Claude Desktop 的自动定位仍然有效，但 Claude Code 中点击底部多供应商模型时不再自动定位到最佳展示位置。

## 根因
Claude Code 当前数据有 15 个模型行，`claude:union-model` 有 7 个供应商，是唯一会稳定走 top-align 分支的 app。top-align 需要先增加临时底部 scroll allowance，让底部模型的 header 能滚到可视区顶部。上一轮为了统一动画，把 allowance 插入也包进了 `withAnimation(expandedRowAnimation)`，导致 `scrollTo(..., anchor: .top)` 执行时可滚动范围还没同步变大。

Codex 和 Claude Desktop 没暴露问题，是因为它们当前展开项走的是 bottom-anchor 分支，不依赖这段临时底部 allowance。

## 尝试记录
- 尝试 1：检查 appType 和 routeKey。结果：Claude Code 使用 appType `claude`，routeKey 与 UI 状态一致，不是命名问题。
- 尝试 2：检查运行中 catalog。结果：Claude Code 有 15 个 route，最多 7 个供应商，符合 top-align 触发条件。
- 尝试 3：恢复 top-align allowance 同步插入。结果：让滚动前置条件重新成立，同时不影响 bottom-anchor 分支。

## 最终方案
top-align 分支同步设置 `expandedTopScrollAllowanceDescription`，确保 `ScrollView` 在滚动前已经具备足够的底部滚动范围。bottom-anchor 分支仍保留动画清理 allowance。

## 经验教训
不是所有参与布局的状态都应该动画化。用于创造 scroll range 的 spacer/allowance 是滚动前置条件，应该先同步到位；真正可见的内容展开、滚动和收起再交给动画事务处理。

# Fix Report - Custom Model Hidden After Save

## Bug 描述
在 popover 内新增自定义模型并保存后，保存提示正常出现，但回到模型列表后看不到刚创建的模型。

## 根因
新增模型已经写入 `CustomModelState`，并且 reload 时会扩展成 synthetic candidate；真正的问题在可见模型过滤。主 UI 对 Claude/Codex route 会用 `UniGateModelScope` 过滤，只保留 cc-switch 原始 scope 中存在的模型。自定义模型的 route key 是用户新建的名称，不会出现在原始 scope 里，因此被 `visibleRouteKeys` 过滤掉。设置页里的 selectable 判断也有同类逻辑。

## 尝试记录
- 尝试 1：检查保存链路。结果：`saveCustomModel` 会写入 custom models，主程序 `saveSettings` 也会保存并 reload。
- 尝试 2：检查 catalog 扩展链路。结果：`loadExpandedCatalog` 会通过 `expandedCandidates` 把自定义模型加入 catalog。
- 尝试 3：检查 UI 可见性过滤。结果：Claude/Codex 的 custom route 不在 `UniGateModelScope`，被过滤，根因确认。

## 最终方案
把“可见”和“可操作”拆开：
- 基础模型仍按 `UniGateModelScope` 和可见模型偏好过滤。
- 自定义模型始终按创建顺序追加到对应 app 的模型列表底部。
- 自定义模型只有在 `UniGateModelScope` 中已配置且目标有效时才可展开/切换；未配置或目标失效时置灰并显示原因。

## 经验教训
新增 synthetic route 时，要同时检查数据生成链路和 UI 可见性链路。保存成功不代表列表一定能显示，尤其是存在 app-specific scope/filter 的地方。

# Fix Report - Proxy Status Detail Visibility

## Bug 描述
Popover 顶部状态只显示 `运行中`、`供应商异常` 等短标题，异常详情被放在 tooltip 中，用户无法直接判断是哪个 app、哪个供应商、什么原因失败。

## 根因
`ProxyStatus` 仍然保存详细消息，但主 UI 只读取 `shortTitle`。同时代理失败回调的 HTTP 状态路径只传供应商名，缺少 app 上下文；上游网络异常路径只传底层错误文本。

## 尝试记录
- 尝试 1：检查 `ProxyStatus.title(port:)`。结果：详情仍存在，但不在主 UI 展示。
- 尝试 2：检查 `LocalProxyServer.proxy` 的失败回调。结果：HTTP 失败和网络异常都能在解析 provider 后补齐 app/provider 上下文。

## 最终方案
- Popover 状态区改为只读 metadata readout，并在异常状态下直接展示 detail 文本。
- 供应商失败消息补齐为 `App · Provider 返回 HTTP xxx` 或 `App · Provider：错误详情`。
- 请求数从聚合值改为按 app 展示，启动时也显示每个 app 的 0 值。

## 经验教训
只读状态信息不应依赖 hover 才可理解。短标题适合状态栏图标或菜单栏摘要，popover 主界面需要把定位问题所需的上下文直接展示出来。

# Fix Report - Settings DB Path Error Visibility

## Bug 描述
在主 UI 的设置页输入错误的 cc-switch 数据库路径后，路径加载错误没有显示在当前设置页面，只能切回模型列表后看到错误 banner。

## 根因
DB 路径应用后，应用层会在 `publishError` 中把错误写入 `UniGateAppState.loadError`。模型列表读取并展示了这个状态，但内嵌设置页只接收 `SettingsViewModel`，没有接收或展示 `loadError`，导致错误反馈跨页面丢失。

## 尝试记录
- 尝试 1：检查保存和重载链路。结果：错误已被捕获并进入 `state.loadError`，不是加载失败未上报。
- 尝试 2：检查设置页参数。结果：`InlineSettingsPanel` 没有 `loadError` 输入，也没有对应错误视图，根因确认。

## 最终方案
把 `state.loadError` 传入 `InlineSettingsPanel`，并在数据库路径输入框下方显示同一条 inline warning，让用户在当前编辑上下文中看到路径加载失败原因。

## 经验教训
设置页的即时生效需要即时反馈。由某个设置项触发的错误应展示在该设置项附近，而不是只在依赖该设置结果的其他页面展示。

# Fix Report - Upstream Model Hidden When Same As Logical Model

## Bug 描述
Codex 中 `gpt-5.5` 这类模型明明有当前上游模型，但主 UI 模型卡片副标题显示成 `Codex`，没有显示 `上游模型：gpt-5.5`。

## 根因
`modelDetailText` 为了减少重复信息，在 `upstream == logicalModel` 时直接退回显示 app 名称。这个规则把“没有上游信息”和“上游模型刚好同名”混在了一起，导致有效的当前上游模型被隐藏。

## 尝试记录
- 尝试 1：检查 `modelDetailText`。结果：发现相同名称保护分支会返回 `ProviderDisplay.appTypeLabel`。
- 尝试 2：检查 `upstreamDisplayName`。结果：当前 active candidate 能返回 `gpt-5.5`，数据本身没有丢失。

## 最终方案
只要存在 active candidate，就始终显示当前上游模型；只有没有 active candidate 时才退回 app 名称。设置页的模型详情也同步取消同名隐藏规则。

## 经验教训
UI 省略重复信息要谨慎。对路由工具来说，当前上游模型是状态信息，即使文本等于逻辑模型，也比 app 名称更有诊断价值。

# Fix Report - Theme Color Apply Discards Pending Settings Input

## Bug 描述
在内嵌设置页修改端口或 cc-switch 数据库路径后，如果 500ms 自动应用尚未触发就立刻切换主题色，刚输入的端口或路径可能被旧配置覆盖。

## 根因
`applyBrandColor` 单独构造 `AppPreferences`，使用的是已经持久化的 `preferences.normalizedPort` 和 `preferences.ccSwitchDBPath`，没有读取当前输入框里的 `portText` / `ccSwitchDBPathText`。主题色保存会触发设置持久化和 catalog reload，随后 ViewModel update 会把输入框重置回旧值。

## 尝试记录
- 尝试 1：检查内嵌设置页输入链路。结果：端口和路径通过 debounce 调用 `applyGeneralSettings`，存在用户在 debounce 前点击主题色的窗口。
- 尝试 2：检查 `applyBrandColor` 构造 preferences 的字段。结果：确认它绕过了当前输入文本，是覆盖风险的根因。
- 尝试 3：将主题色和通用设置共用 preferences 构造逻辑。结果：主题色保存会携带当前输入的端口和路径，避免 reload 回滚。

## 最终方案
新增 `currentPreferences(brandColor:)`，由 `applyGeneralSettings` 和 `applyBrandColor` 共同使用；构造时读取当前输入框文本，并保留 `visibleModels` / `protocolOverrides`。端口无效时主题色不会本地假选中，并用系统提示音反馈。

## 经验教训
实时设置页里，同一个持久化对象的多个字段不能各自从不同 source of truth 构造。只要一次保存会触发 reload，就必须先从当前编辑状态生成完整配置。

# Fix Report - Duplicate Claude Desktop Custom Model Targets

## Bug 描述
在 Claude Desktop 下添加自定义模型并选择转发目标时，`deepseek-v4-flash` 和 `deepseek-v4-pro` 各出现两次。用户在 cc-switch 的 Claude Desktop 配置中有四个 `claude-*` route，其中两个 route 指向 `deepseek-v4-flash`，两个 route 指向 `deepseek-v4-pro`。

## 根因
自定义模型编辑器复用的是基础 `ModelCandidate` 列表。对 Claude Desktop 来说，每个候选代表一个 Desktop 可识别的 `claude-*` route，而不是唯一的上游请求模型。因此当多个 route 映射到同一个上游模型时，主路由列表保留四档是正确的，但自定义模型目标列表会把等价的上游请求目标重复展示。

## 尝试记录
- 尝试 1：检查 cc-switch 导入逻辑。结果：导入时正确保留了 `logicalModel = claude-*`、`labelOverride` 和 `upstreamModel`，不是字段读错。
- 尝试 2：检查自定义模型编辑器候选来源。结果：候选来自 `customModelBaseCandidates()`，按 route candidate 展开，没有按最终请求目标去重。
- 尝试 3：只在自定义模型目标列表去重。结果：保留主路由列表的 Claude Desktop 四档语义，同时消除自定义目标重复项。

## 最终方案
将自定义模型基础候选生成下沉到 `CustomModelState.baseCandidates(from:preserving:)`，按 app、provider、协议、API 格式、base URL、真实上游模型等请求相关字段去重。重复项中优先保留已有编辑目标，其次保留支持长上下文的 route，再按 Sonnet、Opus、Fable、Haiku 的常规顺序选择代表 route。

## 经验教训
Claude Desktop 的 route id 和真实上游模型不是同一层概念。主路由选择应保留 `claude-*` route 维度，自定义模型目标选择则更接近“最终请求目标”，需要按上游请求身份去重。

# Fix Report - Claude Desktop Cross-Model Provider Switching

## Bug 描述
Claude Desktop 中展示为 `auto`、`claude-opus-4-7` 等真实上游模型的行，展开切换供应商时仍然可能切到其他真实模型上。例如当前行显示 `auto`，候选里却能出现请求 `claude-opus-4-7` 的供应商。

## 根因
历史逻辑把 `claude-*` fake route 当成 UI 模型身份。方案 1 改成展示 cc-switch 路由里的真实上游模型后，展示模型身份已经从 `logicalModel` 变成了 `upstreamModel` / `labelOverride`，但切换候选仍然从同一组 `claude-*` route 下直接展开，导致同一个 fake route 下不同供应商指向的不同上游模型被当成“同一模型的不同供应商”。

## 尝试记录
- 尝试 1：只按 route key 合并 Claude Desktop 别名。结果：可以减少重复行，但仍然会把 `auto` 和 `claude-opus-4-7` 这类不同上游模型混在同一个切换列表里。
- 尝试 2：在 AppState 中按当前 active candidate 的展示身份过滤候选。结果：可以阻止跨模型切换，但规则只存在 App 层，缺少直接单测保护。
- 尝试 3：把候选过滤规则下沉到 `ModelRouteGrouping.displayCandidates` 并补测试。结果：固定为按 app + 规范化上游模型过滤，`[1M]` 只作为能力标识，不参与展示身份区分。

## 最终方案
新增 `ModelDisplayIdentity` 和 `ModelRouteGrouping.displayCandidates`：展示行的候选必须和当前 active candidate 的真实上游模型一致，provider 可以不同，但 `auto`、`claude-opus-4-7` 等不同上游模型不能互切。底层 `claude-*` route id 仍然保留，用于 Claude Desktop 兼容和批量更新同一展示组内的 fake route。

## 参考资料
- `Tests/UniGateCoreTests/ModelRouteGroupingTests.swift`：`displayCandidatesExcludeOtherUpstreamModelsForActiveClaudeDesktopRoute`

## 经验教训
Claude Desktop 适配里至少有三层模型身份：Desktop 请求模型、UI 展示模型、上游请求模型。只要 UI 展示从 fake route 切换到真实上游模型，所有 provider 切换、去重、分组逻辑都必须同步使用同一层身份。

# Fix Report - Custom Model Cross-Target Switching Regression

## Bug 描述
修复 Claude Desktop 基础模型跨真实上游模型切换后，自定义模型也被同一规则限制住了。结果是自定义模型只剩当前真实上游模型对应的候选，无法再路由到多个不同模型/供应商。

## 根因
`UniGateAppState.candidates(for routeGroup:)` 对所有 route group 都调用了按 active display identity 过滤的 `ModelRouteGrouping.displayCandidates`。这个规则适用于基础模型，因为基础模型的 UI 行代表一个真实上游模型；但自定义模型的 UI 行代表用户定义的路由别名，它的核心能力就是在多个不同真实上游目标之间切换。

## 尝试记录
- 尝试 1：复查候选过滤入口。结果：确认基础模型和自定义模型共用了同一个过滤路径。
- 尝试 2：给 `ModelRouteGrouping.displayCandidates` 增加是否限制 active display identity 的开关。结果：基础模型继续限制跨模型切换，自定义模型可以显式关闭限制。
- 尝试 3：补充自定义模型语义测试。结果：active 为 `auto` 时，候选仍保留 `deepseek-v4-pro`、`claude-opus-4-7` 等不同上游目标。

## 最终方案
`ModelRouteGrouping.displayCandidates` 默认仍按 active display identity 收窄候选；`UniGateAppState` 检测到当前 route group 是自定义模型时传入 `restrictToActiveDisplayIdentity: false`，只做目标去重，不按真实上游模型过滤。

## 参考资料
- `Tests/UniGateCoreTests/ModelRouteGroupingTests.swift`：`displayCandidatesCanKeepDifferentUpstreamModelsForCustomRoutes`

## 经验教训
“基础模型行”和“自定义路由行”的产品语义不同：前者代表一个真实模型，后者代表一个用户可切换的路由别名。共享 UI 组件时，候选过滤规则必须显式表达这个差异。
