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
