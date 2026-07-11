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

# Fix Report - Custom Model Target Fallback Under Discovery Loss

## Bug 描述
当某个自定义模型已经绑定到指定目标后，如果 VPN 或探测变化导致该目标从当前 catalog 中消失，路由会静默切到同一自定义模型下仍然可用的其他目标，用户看不到明确失败。

## 根因
问题不是单点，而是三层都带了兜底：
`CustomModelDefinition.selectedTarget` 会在选中目标缺失时退回到第一个目标；`RouteStore.merge` 会把失效路由用默认路由补上；`ProxyResolver` 只把这类情况当成普通 noRoute。结果是“目标失效”被一路包装成“还有别的可用模型”。

## 尝试记录
- 尝试 1：只修路由存储合并逻辑。结果：能阻止已有 route 被默认值覆盖，但还不足以表达“选中目标失效”。
- 尝试 2：把自定义模型的选中目标改成严格匹配，不再自动回退到第一个目标。结果：health 和 UI 都能感知到失效选中项。
- 尝试 3：在代理层显式区分“路由不存在”和“路由目标失效”。结果：请求会返回明确错误，不再被静默兜底。

## 最终方案
保留失效 route，让代理请求直接失败；健康检查把“selected target 不存在”标成 warning；UI 把这类自定义模型视为不可操作。

## 参考资料
- `Tests/UniGateCoreTests/RouteStoreTests.swift`
- `Tests/UniGateCoreTests/ConfigurationHealthTests.swift`
- `Tests/UniGateCoreTests/ProxyResolverTests.swift`

## 经验教训
只要某个状态需要“失败可见”，就不能把缺失信息自动补成默认值。路由、健康检查、请求错误三层必须对同一个失效状态保持一致语义。

# Fix Report - Claude Cross-Role Fallback

## Bug 描述
Claude 路由在请求模型属于 `fable` 但当前没有 `fable` 路由时，会静默回退到 `opus` 路由。这个行为会把“缺少明确配置”伪装成“正常可用”，用户无法及时发现路由已经偏移。

## 根因
`ProxyResolver.resolveRouteKey` 在同角色精确匹配失败后，额外实现了跨角色的 `fable -> opus` 兜底。这个分支和同角色别名匹配混在一起，容易把兼容 alias 和真正 fallback 混为一谈。

## 尝试记录
- 尝试 1：直接移除所有 Claude 角色匹配。结果：会误伤同角色但带版本后缀的合法请求。

# Fix Report - Custom Model Target Availability Compared Against Wrong Layer

## Bug 描述
没开 VPN 时，模型探测页能看到模型已经被探测到，但自定义模型行仍然显示“自定义模型目标失效”。

## 根因
`UniGateAppState.customModelAvailability` 之前拿自定义模型自己的 synthetic candidates 去校验 `selectedTarget`，而 `selectedTarget` 存的是真实上游目标。两者不在同一层，结果是只要进入自定义模型行，就会把真实存在的目标误判成失效。`ConfigurationHealth` 里虽然是按真实候选校验，但 UI 行和健康检查口径不一致，导致探测结果和可用性状态对不上。

## 尝试记录
- 尝试 1：只看模型探测结果。结果：探测页确实能拿到目标模型，说明不是探测失败。
- 尝试 2：检查自定义模型行的可用性判定。结果：发现它比较的是 synthetic candidate，而不是基础 catalog 里的真实目标。
- 尝试 3：抽一个 `hasSelectedTarget(in:)` helper 统一校验。结果：UI 和健康检查口径对齐，问题消失。

## 最终方案
- 新增 `CustomModelDefinition.hasSelectedTarget(in:)`。
- `UniGateAppState` 和 `ConfigurationHealth` 都改为基于真实 catalog 候选判断 selected target 是否存在。
- 保留自定义模型的 synthetic route 逻辑，不改路由行为本身。

## 经验教训
自定义路由通常会同时存在“真实上游目标”和“UI/代理包装层”两套身份。只要判定层混用，就会出现“看得见但被判无效”的错觉。

# Fix Report - Missing Target Should Stay Clickable

## Bug 描述
自定义模型的默认目标失效后，主模型行会直接置灰，导致用户无法点击去切换路由。

## 根因
`missingTarget` 被当成了“不可交互状态”，但它其实只是“当前选中的目标不存在”。只要该自定义模型还有其他可选 candidates，用户就应该还能展开并切换到别的目标。之前的 UI 把可用性和错误展示绑在一起，导致失效状态不仅提示错误，还把切换入口一起关掉了。

## 尝试记录
- 尝试 1：只把错误文案改成红色。结果：视觉更明显，但点击仍然被禁掉。
- 尝试 2：把 `missingTarget` 的 operable 语义改成“有候选就可操作”。结果：可以继续切换路由，错误状态也保留。
- 尝试 3：给错误状态单独上红色填充和边框。结果：既能提示异常，也不会把用户锁死在当前行里。

## 最终方案
- `missingTarget` 在还有候选时保持可交互。
- UI 用红色填充/边框和红色 tag 表示异常。
- 只有真正没有候选时，才退回不可交互。

## 经验教训
错误提示和交互禁用是两回事。只要用户还有修复路径，就不要把入口一起关掉。
- 尝试 2：保留同角色别名匹配，只删跨角色 `fable -> opus` 兜底。结果：版本化别名仍可路由，跨角色静默切换被去掉。

## 最终方案
`resolveRouteKey` 仅保留 exact / normalized / 同角色匹配，不再允许 `fable` 失配时自动退到 `opus`。

## 参考资料
- `Sources/UniGateCore/ProxyResolver.swift`
- `Tests/UniGateCoreTests/ProxyResolverTests.swift`

## 经验教训
兼容 alias 和默认兜底必须分开处理。前者是在同一语义域里找同一个目标，后者是在目标不存在时偷偷换目标，产品上应该完全不同。

# Fix Report - Discovery Failure Should Not Delete Provider Models

## Bug 描述
模型探测失败后，之前由探测得到的模型会从供应商候选列表和 Claude Desktop 模型目录中消失。用户看到的结果像是供应商被删了，而不是“供应商还在但当前探测失败”。

## 根因
失败探测会用 `modelIDs = []` 覆盖上一轮成功结果，`discoveredCandidates` 又只从无错误结果生成候选；同时 Claude Desktop `/models` 请求还会现场探测供应商，网络异常时会直接返回变少的模型目录。

## 尝试记录
- 尝试 1：只给当前选中的自定义目标补 missing 占位。结果：只能保住 selected target，其他候选仍会被探测失败删掉。
- 尝试 2：失败探测保留上一轮成功模型，并标记为 stale。结果：候选不再消失，UI 可以显示失效状态。
- 尝试 3：把 RouteStore 切换校验改成拒绝 stale 候选，同时保留已有路由解析。结果：不能切到失效目标，但历史选中目标不会被自动移除或兜底。
- 尝试 4：移除 Claude Desktop `/models` 的现场探测。结果：客户端模型目录改为读取稳定 catalog，不再受单次请求探测失败影响。

## 最终方案
- `ProviderModelDiscoveryState.upsert` 在同一供应商配置指纹下，失败结果保留上一轮成功的 `modelIDs`。
- `ProviderModelDiscovery.discoveredCandidates` 将失败缓存产物标记为 `staleDiscovered`。
- UI 和健康检查显示 stale 为“探测失效/目标失效”。
- `RouteStore` 禁止切换到 stale 候选，但保留已有 route。
- `/models` 统一读取 catalog，不再对 Claude Desktop 做实时供应商探测。

## 参考资料
- `Sources/UniGateCore/ProviderModelDiscoveryStore.swift`
- `Sources/UniGateCore/RouteStore.swift`
- `Sources/UniGateApp/LocalProxyServer.swift`
- `Tests/UniGateCoreTests/ProviderModelDiscoveryTests.swift`
- `Tests/UniGateCoreTests/RouteStoreTests.swift`

## 经验教训
“临时探测失败”和“供应商被删除”是两个不同产品状态。前者应保留上下文并禁用切换，后者才应该清理候选。

# Fix Report - Claude Messages Over OpenAI Chat Bridge

## Bug 描述
`luban-glm` 这个 UniGate 供应商配置的是 `claude` appType，但上游只有 OpenAI Chat 接口。此前 `claude-code` 请求打到这类供应商时，会在解析阶段直接报“需要 protocol transform”，或者即使能发出请求，也不会把返回结果转回 Anthropic Messages，导致 Claude 侧无法正常工作。补齐协议转换后，日志进一步暴露该内部上游使用 `http://`，macOS ATS 会拦截明文 URLSession 请求。

## 根因
路由层只识别了“Claude appType -> Anthropic API”的直连路径，没有把 `apiFormat == .openaiChat` 的 Claude 供应商视为需要桥接的合法路径。即使 resolve 阶段标记了 transform，本地代理也只实现了 Codex Responses 的 OpenAI Chat 转换，没有实现 Anthropic Messages <-> OpenAI Chat 的请求、响应和 SSE 转换。安装包生成的 Info.plist 也没有配置 ATS 例外，导致内部 HTTP 上游在 URLSession 层被系统拒绝。

## 尝试记录
- 尝试 1：只放宽 resolver 的 transform 检查。结果：请求能继续往下走，但上游请求体和下游响应格式仍然不兼容。
- 尝试 2：只补非流式 JSON 转换。结果：非流式能返回，但 Claude Code 的流式路径仍然会断。
- 尝试 3：补齐 Anthropic Chat Bridge，并在 LocalProxyServer 中接管 `count_tokens`、非流式 JSON、OpenAI SSE -> Anthropic SSE。结果：`luban-glm` 这类 OpenAI Chat 上游可以完整服务 Claude Messages 请求。
- 尝试 4：复核转换边界，发现 assistant 的 thinking-only 历史会被静默丢弃、`count_tokens` 基于原始 Anthropic payload 估算不够贴近实际上游请求。结果：改为保留 `reasoning_content`，并基于转换后的 OpenAI Chat 请求体估算 token。
- 尝试 5：复查 UniGate 运行日志，发现协议转换后请求已打到 `http://tokenservice-offline-test.../v1/chat/completions`，但被 ATS 拦截为 `NSURLErrorDomain -1022`。结果：在打包脚本生成的 Info.plist 中允许用户配置的明文上游请求。

## 最终方案
- 在 `ProxyResolver` 中把 `protocolKind == .anthropicMessages && candidate.apiFormat == .openaiChat` 识别为合法桥接路径，生成 `openAIChatToAnthropicMessages`。
- 新增 `AnthropicChatBridge`，统一处理 Anthropic Messages 请求到 OpenAI Chat 请求的转换，以及 OpenAI Chat 响应回 Anthropic Messages 的转换。
- 在 `LocalProxyServer` 中拦截 `count_tokens`，本地返回估算值，避免把这个 Anthropic 专有接口误发给 OpenAI Chat 上游。
- `count_tokens` 的估算输入使用已经转换后的 OpenAI Chat 请求体；这仍不是精确 tokenizer，但和实际发给上游的 payload 保持一致。
- 对流式响应直接转发 Anthropic SSE 事件，保证 Claude Code 可消费。
- 保留 assistant 历史中的 thinking / redacted_thinking 到 OpenAI Chat `reasoning_content`，避免跨轮上下文被静默删掉。
- `ProviderCredentials` 只在真实 Anthropic 上游时使用 `x-api-key`，OpenAI Chat 上游统一走 Bearer。
- `scripts/build-install-run.sh` 生成的 app bundle 增加 `NSAppTransportSecurity.NSAllowsArbitraryLoads`，支持内部 HTTP 供应商地址。

## 参考资料
- `Sources/UniGateCore/ProxyResolver.swift`
- `Sources/UniGateCore/AnthropicChatBridge.swift`
- `Sources/UniGateApp/LocalProxyServer.swift`
- `Sources/UniGateCore/ProviderCredentials.swift`
- `Tests/UniGateCoreTests/AnthropicChatBridgeTests.swift`
- `Tests/UniGateCoreTests/ProxyResolverTests.swift`
- `/Users/didi/Library/Application Support/UniGate/logs/unigate.log`

## 经验教训
同一个 appType 不等于同一种上游协议。只要供应商的 `apiFormat` 和客户端协议不同，就必须把“路由合法性”和“协议转换”拆开处理，否则 resolver 和 proxy 会在不同层面各自失败。

# Fix Report - Proxy Transport Error Network Diagnostics

## Bug 描述
用户反馈有时模型探测能成功，但正式请求模型时报 502。以 `luban-glm` 为例，日志显示请求打到 `http://tokenservice-offline-test.../v1/chat/completions`，客户端看到 502，但用户无法判断这是上游 HTTP 502、代理/直连策略问题，还是 URLSession 传输错误。

## 根因
探测和正式请求不是同一条网络语义：
- 探测是 `GET /v1/models`，超时 15 秒，只证明模型列表接口在某个时刻可达。
- 正式请求是 `POST /v1/chat/completions` 或 `/v1/messages`，可能是流式长连接，超时 600 秒，请求体、上游接口和响应形态都不同。
- `ProviderModelDiscoveryState.upsert` 会在探测失败时保留上一轮成功模型，所以 UI 中“仍有模型”不等于本轮探测成功。
- `luban-glm` 日志中的失败没有 `upstream-headers`，`status=- metricStatus=502 errorKind=network`，说明 UniGate 没收到上游 HTTP headers；502 是 UniGate 对 `URLError.networkConnectionLost` 这类传输错误的网关状态映射，不是上游返回的 HTTP 502。

同时原有网络诊断只覆盖“系统代理失败、直连可用”这个方向。当前配置全局是 `direct` 时，如果直连失败但系统代理可用，探测诊断不会提示，容易造成“探测/请求代理策略不一致”的错觉。

## 尝试记录
- 尝试 1：核对 `NetworkPolicyResolver`。结果：探测和正式请求都走同一套规则：provider override 优先，其次直连域名，最后全局策略；正式请求对 synthetic/custom model 使用真实 `upstreamProviderRef`，逻辑正确。
- 尝试 2：核对本地偏好和运行日志。结果：当前全局策略与相关 provider override 都是 `direct`，`luban-glm` 正式请求日志也显示 `networkPolicy=direct`，不存在探测用系统代理、请求用直连的分叉。
- 尝试 3：核对失败日志。结果：`luban-glm` 失败多为 `The network connection was lost` 或 `The request timed out`，且没有上游 headers；502/504 是 UniGate 的传输错误映射。
- 尝试 4：评估自动切换系统代理/直连。结果：不采用。正式请求是 POST/流式大请求，失败后自动用另一网络策略重放会有重复请求和副作用风险。

## 最终方案
- 将 `NetworkPolicyDiagnostic` 从固定的 `systemError/directStatusCode` 改为通用的 `failedMode/failedError/fallbackMode/fallbackStatusCode`，并保留旧字段解码兼容。
- 模型探测失败时自动用另一种网络策略做同一个 `GET /v1/models` 轻量探测；如果另一策略能返回 HTTP 状态，就在 UI、事件和诊断报告中提示“当前策略失败，另一策略可用”。
- 设置页网络诊断按钮改为按实际可用策略设置 provider override，不再写死“设为直连”。
- 正式请求在还没向客户端发送 headers 且上游传输失败时，返回结构化错误体：`type=upstream_transport_error`，包含 `code`、`transport_error_kind`、`network_policy`、`upstream_returned_http_headers=false`、provider 和 upstream URL 等上下文。这样客户端看到 502 时可以区分“上游 HTTP 502”和“UniGate 到上游的传输失败”。
- 保持正式 POST 请求不自动 fallback，避免重复发送模型请求。

## 参考资料
- `Sources/UniGateCore/NetworkPolicy.swift`
- `Sources/UniGateApp/main.swift`
- `Sources/UniGateApp/LocalProxyServer.swift`
- `Sources/UniGateApp/UniGatePopoverView.swift`
- `Sources/UniGateCore/DiagnosticsReport.swift`
- `/Users/didi/Library/Application Support/UniGate/logs/unigate.log`

## 经验教训
“模型可被列出”和“模型请求可完成”不是同一个健康信号。GET 探测只能用于目录可达性和网络策略提示，不能替代真实 POST/SSE 链路诊断。对 POST 链路做自动网络策略 fallback 前必须考虑请求重放副作用；更稳妥的第一步是把传输错误和 HTTP 上游错误明确分层展示。

# Fix Report - Review Follow-up Regression Fixes

## Bug 描述
复审指出三处问题：OpenAI Chat -> Anthropic SSE 的 malformed chunk 仍不会发 Anthropic error 事件；`JSONValueParser` 修正数字类型后，数字 `1/0` 编码的布尔配置被消费者读成 false；`RouteStore.load` 空 catalog 回归测试不能区分“保留用户选择”和“默认重建”。

## 根因
- `AnthropicChatBridgeError` 的 catch 被放在原始 SSE 透传函数里，真正的转换流函数只把错误包装成 upstream transport error。进一步验证发现畸形 JSON 会先抛 `JSONSerialization` 的 `NSError`，没有归一成 `AnthropicChatBridgeError.invalidChatStreamChunk`。
- 三个 bool helper 只接受 `.bool`，而 parser 现在会正确把 JSON 数字解析成 `.number`，导致数字布尔兼容性丢失。
- C1 测试保存和默认候选都使用同一个 provider，旧 bug 清空文件后重新生成默认路由也能满足断言。

## 尝试记录
- 尝试 1：把 catch 从透传函数移动到转换流函数。结果：仍没有 error 事件，端到端测试显示内部抛的是 JSONSerialization NSError。
- 尝试 2：将 `events(forOpenAIChatStreamData:)` 的解析错误归一成 bridge error。结果：LocalProxyServer 能识别并发送 Anthropic `event: error`。
- 尝试 3：把数字布尔支持补到三处消费者，并让 C1 测试使用非默认 provider。结果：新增和加固测试都能覆盖复审指出的真实风险。

## 最终方案
- `streamOpenAIChatAsAnthropicSSE` 捕获 `AnthropicChatBridgeError` 后发送 Anthropic SSE error 事件并记录 SSE failure。
- `AnthropicChatStreamState` 将 malformed JSON / 非对象 chunk 统一抛为 `invalidChatStreamChunk`。
- `ProviderModelDiscovery`、`ProviderModelDiscoveryFingerprint`、`CcSwitchImporter` 的 bool helper 接受 `.number`，非零为 true。
- 加固 `RouteStore` 空 catalog 测试，断言磁盘文件保留非默认用户选择；新增数字布尔和 malformed stream 端到端测试。

## 参考资料
- `Sources/UniGateApp/LocalProxyServer.swift`
- `Sources/UniGateCore/AnthropicChatBridge.swift`
- `Sources/UniGateCore/ProviderModelDiscovery.swift`
- `Sources/UniGateCore/ProviderModelDiscoveryStore.swift`
- `Sources/UniGateCore/CcSwitchImporter.swift`
- `Tests/UniGateAppTests/LocalProxyServerTests.swift`

## 经验教训
修复流式协议错误时，单测不能只覆盖合法 error payload；必须覆盖 malformed payload 到客户端可见字节的完整路径。修 parser 的同时也要检查消费者是否依赖旧的宽松类型语义。

# Fix Report - Custom Model Target Picker Shows Stale Configured Models

## Bug 描述
添加或编辑 Codex 自定义模型时，转发目标列表会出现供应商当前探测结果里不存在的旧模型。例如供应商探测只返回 `gpt-5.4` 和 `gpt-5.4-mini`，但自定义模型编辑器里仍可选择 `gpt-5.5`。

## 根因
自定义模型编辑器的候选来自完整 `ProviderCatalog`。这个 catalog 同时包含：
- cc-switch 原始配置导入的 `.configured` 候选；
- 供应商模型探测产生的 `.discovered` 候选；
- 探测失败时保留的 `.staleDiscovered` 缓存候选。

当某个供应商已经成功探测到当前模型列表时，旧的 cc-switch `model` 配置仍会作为 `.configured` 候选留在 catalog 中。编辑器没有用“成功探测结果”覆盖该供应商的可选目标，所以把已不在供应商模型列表中的旧配置也展示了出来。

## 尝试记录
- 尝试 1：检查 UniGate scope 过滤。结果：scope 能过滤客户端可见基础模型，但自定义模型允许指向未暴露给客户端的上游目标，不能简单套 scope。
- 尝试 2：检查代理运行时。结果：proxy catalog 已按 scope 和自定义模型规则过滤，问题集中在编辑器候选生成。
- 尝试 3：让编辑器在同一供应商存在成功探测候选时过滤旧 `.configured` 候选。结果：能去掉不存在的 `gpt-5.5`，同时保留探测到但未暴露为基础模型的目标。

## 最终方案
`CustomModelState.baseCandidates` 增加可选候选过滤闭包。`UniGateAppState.customModelBaseCandidates` 传入探测一致性规则：同一供应商只要有当前 `.discovered` 结果，`.configured` 候选必须能匹配某个探测目标才进入编辑器列表；正在编辑的已保存目标始终保留显示，避免用户配置被隐式丢失。

## 参考资料
- `Sources/UniGateApp/UniGateAppState.swift`
- `Sources/UniGateCore/CustomModelStore.swift`
- `Tests/UniGateAppTests/UniGateAppStateTests.swift`

## 经验教训
`ProviderCatalog` 是运行时全集，不等于 UI 里每个选择器的真相源。选择器需要明确自己更信任哪一层：原始配置、成功探测结果、缓存探测结果，还是客户端可见 scope。

# Fix Report - Custom Model Target Picker Hides Same-Name Base Targets

## Bug 描述
Codex 中已创建并强制启用自定义模型 `gpt-5.4`。另有手动添加的供应商 `ahoo-gpt-plus`，供应商探测结果里包含 `gpt-5.5`。展开或编辑 `gpt-5.5` 本身时能看到 `ahoo-gpt-plus · gpt-5.5`，但编辑自定义模型 `gpt-5.4` 的转发目标列表时看不到这个目标。

## 根因
本地配置里同时存在自定义模型 `gpt-5.4` 和自定义模型 `gpt-5.5`。`CustomModelState.baseCandidates` 为了避免把自定义模型 synthetic route 当作另一个自定义模型的目标，按所有自定义模型的 `routeKey` 排除了同名候选。

这个判断粒度过粗：`ahoo-gpt-plus · gpt-5.5` 是真实基础候选，它的 `providerRef == upstreamProviderRef`；需要排除的是 synthetic 自定义候选，而不是所有 route key 等于某个自定义模型名的基础候选。结果就是自定义 `gpt-5.5` 的存在误伤了基础目标 `ahoo-gpt-plus · gpt-5.5`。

## 尝试记录
- 尝试 1：检查运行中 `/__manager/catalog`。结果：`ahoo-gpt-plus · gpt-5.5` 以 `.discovered` 基础候选存在，数据没有丢。
- 尝试 2：检查 `custom-models.json`。结果：确认本地有 custom `gpt-5.5` 定义，因此触发了 routeKey 级别排除。
- 尝试 3：去掉目标候选中的 custom routeKey 排除，仅保留 `providerRef == upstreamProviderRef` 的基础候选判断。结果：synthetic 自定义候选仍被排除，真实基础候选恢复显示。

## 最终方案
`CustomModelState.baseCandidates` 不再按其他自定义模型的 `routeKey` 排除候选；自定义模型之间的 synthetic 候选通过 `providerRef != upstreamProviderRef` 自然排除。新增 AppState 回归测试覆盖“已有 custom `gpt-5.5` 时，编辑 custom `gpt-5.4` 仍能看到 `ahoo-gpt-plus · gpt-5.5`”。

## 参考资料
- `Sources/UniGateCore/CustomModelStore.swift`
- `Tests/UniGateAppTests/UniGateAppStateTests.swift`

## 经验教训
自定义模型名可以和真实基础模型名相同。判断“这是自定义模型候选还是基础供应商候选”时不能只看 routeKey，必须看 provider identity；否则会把同名基础模型误判为自定义模型循环引用。

# Fix Report - Invalid Content-Length Crashes Local Proxy Parser

## Bug 描述
向本地代理发送带非法 `Content-Length` 的 HTTP 请求时，UniGate 不是返回 4xx，而是会因为 Swift runtime trap 直接崩溃。最小复现是 `Content-Length: -1`；极大整数也可能在 body 边界计算时触发溢出。

## 根因
`HTTPRequest.parse` 直接把 `content-length` 解析成 `Int`，默认值为 0，然后无校验地执行 `bodyStart + bodyLength` 并构造 `bodyStart..<(bodyStart + bodyLength)`。这有两个问题：
- 负数长度会创建 `lowerBound > upperBound` 的 range，触发 `Range requires lowerBound <= upperBound`。
- 超大整数即使能被 `Int` 解析，也可能在 `bodyStart + bodyLength` 时溢出。

旧实现还把“请求体尚未收完”和“header 非法”都压成 `nil`，调用方无法区分继续收包还是立刻拒绝。

## 尝试记录
- 尝试 1：先加 socket 集成测试，期待收到 400。结果：测试进程直接被 signal 5 打崩，并稳定复现 `Range requires lowerBound <= upperBound`，确认是真崩溃不是普通解析失败。
- 尝试 2：只在现有 `HTTPRequest?` 上补局部 guard。结果：可以拦住一类非法值，但仍无法区分 incomplete 与 malformed，调用方要么误关连接，要么继续等待非法请求。
- 尝试 3：把解析结果改为 `complete / incomplete / malformed` 三态，并对负数与加法溢出统一返回 malformed。结果：非法长度稳定返回 HTTP 400，正常不完整 body 仍继续收包，现有代理测试全部通过。

## 最终方案
- `HTTPRequest.parse` 改为返回 `ParseResult`：`.complete`、`.incomplete`、`.malformed`。
- 显式校验 `Content-Length`：
  - 解析失败或负数 -> `400 Invalid Content-Length`
  - `bodyStart.addingReportingOverflow(bodyLength)` 溢出 -> `400 Invalid Content-Length`
  - 仅在合法但 body 未收全时返回 `.incomplete`
- `LocalProxyServer.receive` 根据三态结果分流：
  - `complete` -> 进入原有处理流程
  - `incomplete` -> 保持原有 `100-continue` / 继续收包逻辑
  - `malformed` -> 立即回 `400`
- 新增两个回归测试：负数长度、超大溢出长度。

## 参考资料
- `Sources/UniGateApp/LocalProxyServer.swift`
- `Tests/UniGateAppTests/LocalProxyServerTests.swift`

## 经验教训
HTTP framing parser 不能把“还没收完”和“输入非法”混成一个空值；一旦后续代码要做整数或 range 运算，就必须先把语义拆清楚，否则 bug 会从“错误响应”升级成整个进程被客户端请求击穿。

# Fix Report - Proxy Request Classification, Full URL Semantics, and Tool Result Ordering

## Bug 描述
代理路由存在三个跨协议边界问题：
- 损坏 JSON 和请求 Bridge 不支持的内容会落入通用异常处理，被返回为上游 502，并错误标记供应商失败。
- 自定义供应商启用“完整 URL”后，实际转发仍会追加 endpoint；普通 Base URL 的配置 query 和入站 query 也无法可靠保留。
- Anthropic 同一条 user message 同时包含 `tool_result` 和 text 时，转换结果先输出 user 文本、后输出 tool result，破坏 OpenAI Chat 工具消息顺序。

## 根因
- `ProxyResolver` 只把部分显式校验转换成 `ProxyResolverError`，`JSONSerialization` 语法错误、`CodexChatBridgeError` 和 `AnthropicChatBridgeError` 会以普通 `Error` 逃逸。
- 上游 URL 通过字符串拼接构造，且没有读取 `provider.meta.isFullUrl`；`normalizeEndpoint` 还会直接删除入站 query。
- `AnthropicChatBridge.chatMessages` 把普通内容和 tool result 分别收集，重组时固定先输出普通消息，再追加 tool 消息。

## 尝试记录
- 尝试 1：为 JSON、两类 Bridge、完整 URL、query 合并和混合 tool result 分别添加回归测试。结果：Bridge 错误类型缺失导致编译失败，确认没有客户端错误分类；URL 和消息顺序测试也锁定了预期语义。
- 尝试 2：让所有普通 `Error` 都返回 400。结果：放弃，因为这会把真正的 URLSession、上游流和响应转换错误误归类为客户端问题。
- 尝试 3：只在 `ProxyResolver` 的入站解析与请求 Bridge 边界包装错误，并用 `URLComponents` 构造非完整 URL。结果：客户端错误进入既有 4xx 路径，真正的上游异常路径保持不变；完整 URL 和 query 语义得到保留。

## 最终方案
- 新增 `ProxyResolverError.invalidRequest`：
  - JSON 语法错误统一映射为 `invalidJSONBody`。
  - Codex/Anthropic 请求 Bridge 校验错误映射为 `invalidRequest`。
  - `LocalProxyServer` 将两者返回 400，且不调用 `proxyProviderDidFail`。
- URL 路由：
  - `isFullUrl=true` 时直接使用配置 URL，不追加任何 endpoint，也不合并入站 query。
  - 普通 Base URL 使用 `URLComponents` 追加规范化 path，并按“配置 query 在前、入站 query 在后”保留两侧 query items。
- Anthropic Bridge 先输出按原顺序收集的 tool result 消息，再输出同一 Anthropic user message 中的普通文本/图片消息。

## 参考资料
- `Sources/UniGateCore/ProxyResolver.swift`
- `Sources/UniGateCore/AnthropicChatBridge.swift`
- `Sources/UniGateApp/LocalProxyServer.swift`
- `Tests/UniGateCoreTests/ProxyResolverTests.swift`
- `Tests/UniGateCoreTests/AnthropicChatBridgeTests.swift`
- `Tests/UniGateAppTests/LocalProxyServerTests.swift`
- Claude tool use: https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls

## 经验教训
代理转换层必须保留三个不变量：错误责任主体不能跨边界漂移，完整 URL 必须是权威终点，有序协议内容不能先分类再按类别重排。测试也应覆盖跨类别组合，而不只是每种内容单独出现的情况。

# Fix Report - Stale Discovery Commit and Custom Model Name Conflicts

## Bug 描述
存在两个配置一致性问题：
- 手动模型探测启动后会捕获当时的 imported snapshot。探测期间如果 DB、路径、协议覆盖或自定义供应商发生重载，旧任务完成后仍会重新应用旧 snapshot 和 routes。
- 自定义模型可以与当前 cc-switch 基础模型或另一个自定义模型重名。同名对象共用一个 `ModelRouteKey`，可能让持久化旧路由静默选择错误目标。

## 根因
- 模型探测任务只有 cancellation 检查，没有表示配置版本的 revision；配置重载也不会使已经捕获的 snapshot 失去提交资格。
- 自定义模型编辑器只校验名称非空。代理 catalog 会同时生成同 route key 的基础 candidate 和 synthetic candidate，配置健康检查也没有报告名称冲突。

## 尝试记录
- 尝试 1：只在配置重载时取消探测任务。结果：不足以作为正确性保证，异步请求完成与 cancellation 检查之间仍可能出现晚到写入。
- 尝试 2：引入配置 revision，探测任务在每次状态写入和最终持久化前检查 revision。结果：旧任务无法再提交；取消任务仅用于尽快结束网络请求。
- 尝试 3：保留启动时 snapshot，但依赖 revision 判断。结果：虽然能覆盖当前已知重载入口，仍容易因未来新增入口再次遗漏。
- 尝试 4：最终提交时重新读取当前 imported snapshot，并按当前 provider fingerprint 剪枝探测结果。结果：即使任务期间配置发生变化，也不会重新应用启动时旧 snapshot。
- 尝试 5：让自定义模型覆盖同名基础模型。结果：放弃。主页基础模型已经来自 cc-switch，产品语义更适合禁止重名，而不是增加隐式覆盖优先级。

## 最终方案
- 新增 `ConfigurationRevisionTracker`：
  - 配置重载、代理 runtime reload 和配置重置都会推进 revision，并取消手动/自动探测任务。
  - 手动和自动探测捕获启动 revision，在每次异步返回及提交前验证。
  - 被配置重载取消的手动探测退出后，会基于当前配置重新安排自动探测。
  - 手动探测最终重新读取当前 imported snapshot，并只保存仍匹配当前 provider fingerprint 的结果。
- 自定义模型重名：
  - 新建或重命名时拒绝与当前可路由基础模型、其他自定义模型重名，编辑器保持打开并显示提示。
  - 历史冲突在配置健康检查中显示“自定义模型名称冲突”。
  - 主模型列表对同 route key 去重并将冲突项标记为不可操作。
  - 代理 catalog 不生成冲突的 synthetic candidate，历史冲突不会继续静默路由到自定义目标。
  - 自定义模型首选 provider 只在对应 synthetic candidate 仍存在于代理 catalog 时参与默认路由。

## 参考资料
- `Sources/UniGateApp/main.swift`
- `Sources/UniGateApp/ConfigurationRevisionTracker.swift`
- `Sources/UniGateApp/UniGateAppState.swift`
- `Sources/UniGateCore/CustomModelStore.swift`
- `Sources/UniGateCore/Models.swift`
- `Sources/UniGateCore/ConfigurationHealth.swift`
- `Tests/UniGateAppTests/ConfigurationRevisionTrackerTests.swift`
- `Tests/UniGateAppTests/UniGateAppStateTests.swift`
- `Tests/UniGateCoreTests/CustomModelStoreTests.swift`
- `Tests/UniGateCoreTests/ConfigurationHealthTests.swift`

## 经验教训
异步任务的 cancellation 只能优化资源释放，不能证明旧结果无权提交；配置状态必须由显式 revision 约束。对于共享同一业务主键的两类对象，如果产品没有明确覆盖语义，应在写入边界禁止冲突，并为历史数据提供可见、失败安全的处理。

# Fix Report - Codex Chat Candidates Misclassified as Native Responses

## Bug 描述
同一 Codex 逻辑模型同时存在 OpenAI Responses 和 OpenAI Chat 上游时，Chat 候选被标记为“不需要转换”。默认路由可能按供应商来源或名称选择 Chat，随后正常的 Codex 流式、工具或图片请求才在运行时被本地简化 Bridge 拒绝，即使 catalog 中已有原生 Responses 候选。

## 根因
- `UniGateAppRegistry.requiresTransform` 和 `CcSwitchImporter.codexCandidate` 都把 Codex + OpenAI Chat 当成原生兼容。
- `RouteStore.defaultState` 只有 `requiresTransform: Bool`，无法区分原生、可桥接和完全不支持三种状态。
- `RouteStore.merge` 无条件保留旧 route key 的 provider，修正默认规则后，历史自动生成的 Chat 路由也不会迁移。
- cc-switch 当前的 Codex 配置中，`wire_api = "responses"` 表示 Codex 客户端到 cc-switch 的协议；真实上游协议由 `meta.apiFormat` / settings `apiFormat` 表示。UniGate 原先优先读取 `wire_api`，会把 cc-switch 的 Chat 上游再次误判为 Responses。

## 尝试记录
- 尝试 1：只把 Codex + Chat 的 `requiresTransform` 改为 `true`。结果：不足；当不存在 Responses 时，Chat 与 Anthropic/Gemini 等不支持格式仍同为 `true`，默认路由可能继续按名称选中完全不支持的候选。
- 尝试 2：仅修改新默认路由排序。结果：不足；已有 `updatedAt == 1970-01-01` 的系统自动路由仍会保留旧 Chat provider。
- 尝试 3：将所有旧 Chat 路由迁移到 Responses。结果：放弃；这会覆盖用户在 UI 中明确选择的 Chat provider。
- 尝试 4：引入三态兼容性，并只在系统自动路由的兼容性确实提升时迁移。结果：原生 Responses 优先，Chat Bridge 次之，不支持格式最后；用户手动选择保持不变。

## 最终方案
- 新增内部 `ProxyProtocolCompatibility`：
  - `native`：Codex Responses -> OpenAI Responses 等协议直连。
  - `limitedBridge`：Codex Responses -> OpenAI Chat、Anthropic Messages -> OpenAI Chat。
  - `unsupported`：当前 `ProxyResolver` 没有实现转换的组合。
- `requiresTransform` 统一由兼容性计算；Codex + Chat 返回 `true`。
- Codex provider 导入按 cc-switch 当前路由语义读取：`meta.apiFormat`、settings `apiFormat` 优先，TOML `wire_api` 只作回退。
- 默认候选先按 `native < bridged < unsupported` 排序，再按 configured/custom/discovered 和供应商名称排序。
- `RouteStore.merge` 只迁移 epoch 时间戳标记的系统自动路由，且只在新默认候选兼容性更高时替换；手动路由和自定义模型显式目标不变。
- 新增回归测试覆盖导入优先级、Chat 转换标记、三态排序、自动路由迁移和手动路由保留。

## 参考资料
- OpenAI Codex 当前只接受 Responses wire API：
  https://github.com/openai/codex/blob/dfefd8aa8bc267ee42e1800b9b94da860a5ec37b/codex-rs/model-provider-info/src/lib.rs
- cc-switch 根据 `apiFormat` 判断真实 Chat 上游，并只对 Responses endpoint 启用转换：
  https://github.com/farion1231/cc-switch/blob/99e11e0851972e0ef7307be9c328a85b8371531e/src-tauri/src/proxy/providers/codex.rs
- cc-switch 的 Responses -> Chat 请求、工具、流式返回转换：
  https://github.com/farion1231/cc-switch/blob/99e11e0851972e0ef7307be9c328a85b8371531e/src-tauri/src/proxy/providers/transform_codex_chat.rs
- LiteLLM 将 Responses -> Chat Bridge 作为显式 flag / model prefix 路径：
  https://github.com/BerriAI/litellm/blob/dacf1cfb268ed151526576f683b02a95a4187b1c/litellm/responses/main.py

## 经验教训
“是否需要转换”不是协议路由的充分模型。路由器至少要区分原生、可桥接和不支持，否则布尔值会把能力差异压平，并把错误推迟到真实请求阶段。导入第三方配置时也必须先区分“客户端到代理的协议”和“代理到真实上游的协议”，不能因为字段都叫 wire/API format 就视为同一层语义。

# Fix Report - Official Codex Route Hides Same-Name Third-Party Providers

## Bug 描述
Codex 官方和多个第三方供应商都成功探测到 `gpt-5.6-luna`，但主路由只能保留官方供应商，无法切到 `ahoo-gpt`、Dasu 等同名候选；`gpt-5.6-sol` 却可以正常切换。

## 根因
cc-switch 当前给 UniGate 的 Codex 配置只显式声明了 `gpt-5.6-sol`。官方发现模型允许绕过 cc-switch model scope，因此 `gpt-5.6-luna` 能创建可见路由；但候选过滤仍按单个 provider candidate 判断，第三方 `gpt-5.6-luna` 不在 scope 中，进入代理 catalog 前被删除。

结果是同一个 route key 已由官方开放，但该路由下的其他同名供应商仍被错误过滤。scope 实际应控制“模型路由是否开放”，而不是在路由开放后继续限制提供该模型的供应商。

## 尝试记录
- 尝试 1：比较模型探测缓存。结果：官方、`ahoo-gpt`、`gpt-free` 和 Dasu 的 Luna 均为完全相同的 `appType/logicalModel/upstreamModel`，排除命名和规范化问题。
- 尝试 2：比较运行中代理 catalog。结果：Luna 仅剩官方候选；Sol 因 cc-switch 显式配置而保留全部供应商，根因锁定在 scope 过滤。
- 尝试 3：先添加 UI、代理 catalog 和 RouteStore 组合回归测试。结果：修复前稳定失败，证明不是界面点击状态问题。

## 最终方案
- 从官方候选计算已经开放的 Codex route key 集合。
- 只要某个 route key 已由 Codex 官方候选开放，同 route key 的当前第三方基础候选也允许进入 UI 和代理 catalog。
- 不同 route key 的第三方发现模型仍继续受 cc-switch scope 限制，避免把所有探测模型无条件暴露给代理。

## 参考资料
- `Sources/UniGateCore/ModelRoutingUtilities.swift`
- `Sources/UniGateCore/Models.swift`
- `Tests/UniGateCoreTests/ModelRouteGroupingTests.swift`
- `Tests/UniGateAppTests/UniGateAppStateTests.swift`

## 经验教训
模型 scope 是 route-level policy，供应商是 route 下的可替换 target。只要某个特殊来源能够创建超出 scope 的 route，就必须同步检查同 route 的 target 过滤，否则会出现“模型可见但同名供应商不可切换”的半开放状态。

# Fix Report - Codex Official Login Succeeds but Local Proxy Rejects Requests

## Bug 描述
用户在 UniGate 中完成 Codex 官方登录并切换到官方路由后，请求仍返回 401，提示需要重新导入 cc-switch 供应商。日志明确显示“Codex 官方登录成功”之后仍持续出现 `codex-auth-error`。

## 根因
OAuth 登录与本地代理客户端鉴权是两层独立机制。UniGate 已成功保存官方 OAuth 凭据，但官方路由在使用 OAuth 前只接受当前安装保存在 Keychain 中的随机本地令牌。已有 cc-switch UniGate Codex 供应商仍携带其配置中的 `auth.OPENAI_API_KEY` / `experimental_bearer_token`，两者不一致，因此请求在进入 OAuth authorizer 前被拒绝。

## 尝试记录
- 尝试 1：根据日志检查 OAuth 登录状态。结果：排除；登录成功事件早于后续 401，失败阶段为本地 `codex-auth-error`。
- 尝试 2：取消官方路由本地鉴权或接受任意本机 Bearer。结果：放弃；这会让无关本地客户端使用用户的官方订阅。
- 尝试 3：仅接受 Keychain 令牌以及当前、已验证为 UniGate 回环 Codex 供应商配置的客户端令牌。结果：回归场景通过，非当前、第三方及无关固定令牌仍被排除。

## 最终方案
- Codex 配置解析器读取活动 provider 的 `experimental_bearer_token`。
- cc-switch 导入器只从 `is_current` 且通过既有 UniGate 回环地址校验的 Codex provider 提取 `auth.OPENAI_API_KEY` 和 `experimental_bearer_token`。
- 运行时随 DB 快照刷新可信客户端令牌集合；官方路由将其与 Keychain 安装令牌合并后逐个做恒定时间比较。
- OAuth 上游授权、浏览器 Origin 拒绝和第三方静态鉴权逻辑保持不变。

## 参考资料
- `Sources/UniGateCore/CodexConfigParser.swift`
- `Sources/UniGateCore/CcSwitchImporter.swift`
- `Sources/UniGateCore/LocalProxyCredential.swift`
- `Sources/UniGateApp/LocalProxyServer.swift`
- `Sources/UniGateApp/main.swift`

## 经验教训
代理的客户端鉴权与上游 OAuth 是两条不同的信任链。配置导入创建客户端凭据后，代理必须能识别该配置实际发送的令牌；同时可信集合必须绑定到当前、自有回环供应商，不能为了兼容旧配置而退化成“本机请求即可信”。

# Fix Report - Release Verification Relaunch Race

## Bug 描述
发布脚本完成构建、签名、压缩包和 appcast 校验后，安装的新应用没有在 20 秒内监听本地端口，健康检查失败。随后手动启动同一个 app bundle 可以正常运行。

## 根因
旧 UniGate 正在处理请求时，脚本发送终止信号后没有等待进程真正退出，便立即覆盖 app bundle 并调用普通 `open`。LaunchServices 仍把正在退出的旧进程视为运行实例，因此没有启动新安装的应用。

## 尝试记录
- 检查产物签名、版本、压缩包和 appcast：全部通过，排除构建产物损坏。
- 检查配置端口和应用日志：端口为预期的 `17888`，失败期间没有新实例监听记录。
- 对同一安装执行 `open -n`：应用立即启动并通过健康检查，确认是重启时序而非应用启动错误。

## 最终方案
本地安装和发布验证都等待旧进程完全退出后再替换 bundle，并使用 `open -n` 明确启动新实例。旧进程在 10 秒内未退出时停止发布，不再继续覆盖运行中的应用。

## 经验教训
桌面应用的“已发送退出信号”和“进程已退出”不是同一状态。发布验证必须等待后者，并避免让 LaunchServices 的旧实例复用行为掩盖重启失败。
