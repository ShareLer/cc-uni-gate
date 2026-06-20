# Claude Desktop 路由方案调研

## 背景

Claude Desktop 的第三方网关配置不是任意模型列表。它会读取企业/第三方 profile 中的 `inferenceModels`，但模型 ID 仍需要满足 Claude Desktop 自己认可的 Claude 安全模型名形态，例如 `claude-sonnet-*`、`claude-opus-*`、`claude-haiku-*`、`claude-fable-*`。因此，DeepSeek、GPT、`auto` 这类真实上游模型名不能直接作为 Claude Desktop 请求模型 ID 暴露。

cc-switch 的“模型映射/本地路由”功能解决的是三层模型名分离：

1. `route_id`：Claude Desktop 实际请求的模型 ID，必须是 Claude Desktop 可识别的 `claude-*` 路由名。
2. `labelOverride`：Claude Desktop 菜单中展示给用户看的名称，可以展示为 DeepSeek、GPT、`auto` 或自定义名称。
3. `model`：cc-switch 转发到上游供应商时使用的真实模型名，例如 `deepseek-*`、`gpt-*`、`auto`。

这解释了为什么直接读取 Claude Desktop 配置时会看到 `claude-*`：那是 Desktop 认可并请求的路由 ID，不是最终上游请求模型。

## 已完成的方案 1

UniGate 当前采用方案 1：继续依赖 cc-switch 的 Claude Desktop 本地路由能力，UniGate 只做识别、展示和转发。

实现原则：

1. 保留 `logicalModel` / `route_id` 作为协议层请求模型，用于匹配 Claude Desktop 发来的 `claude-*` 请求。
2. 从 cc-switch 配置中读取 `labelOverride` 和 `model`，优先展示用户配置的菜单展示名，其次展示真实上游模型名。
3. UI 明确提示用户：如果 Claude Desktop 目标要使用 DeepSeek、GPT、`auto` 等非 Claude 模型，需要在 cc-switch 中启用模型路由/模型映射，并配置“菜单显示名”和“实际请求模型”。

该方案不会改变 Claude Desktop 的请求行为，也不会在 UniGate 内部伪造新的 Desktop profile，因此风险较低。

## cc-switch 方案 2 相关源码结论

cc-switch 的完整路由能力主要由以下逻辑组成：

1. 默认安全路由：`src-tauri/src/claude_desktop_config.rs` 中的 `DEFAULT_PROXY_ROUTES` 固定提供 Sonnet、Opus、Haiku、Fable 四档 `claude-*` 路由。
2. 路由归一化：`proxy_model_routes` 会读取 provider meta 中的 `claude_desktop_model_routes`，修复不安全 route，保留 `labelOverride`、`model`、`supports1m`。
3. `/models` 响应：`model_list_response` 返回给 Claude Desktop 的仍然是 route id，而不是真实上游模型名。
4. 请求映射：`map_proxy_request_model` 接收 Claude Desktop 请求体，把 `model: claude-*` 映射成上游真实 `model`，并处理 1M 后缀、Opus 旧别名、角色关键词回退、Fable 到 Opus 的降级等兼容逻辑。
5. Profile 写入：`apply_provider_to_paths_inner` / `build_gateway_profile` 会写入 Claude Desktop 的第三方 profile，设置 `inferenceGatewayBaseUrl`、token、`inferenceModels` 和 `labelOverride`。
6. 安全回滚：写 Claude Desktop 配置前会 snapshot 多个配置文件，失败后恢复，避免把 Desktop 配置写坏。
7. 前端固定四档：`ClaudeDesktopProviderForm.tsx` 把 proxy 模式 UI 固定为 Sonnet / Opus / Fable / Haiku 四行，空档会继承已填写的主模型，降低子 agent 请求缺档的概率。

## 方案 2 范围

方案 2 是让 UniGate 自己提供与 cc-switch 类似的 Claude Desktop 模型映射和本地路由能力。这样 UniGate 不再只是读取 cc-switch 的配置，而是直接成为 Claude Desktop 的路由配置管理者。

需要实现的核心模块：

1. Claude Desktop profile 管理
   - 定位 macOS / Windows 上 Claude Desktop 的配置文件和 `configLibrary`。
   - 写入第三方 deployment mode。
   - 写入 UniGate 自己的 profile ID、网关 base URL、token 和 `inferenceModels`。
   - 支持恢复官方模式。

2. 配置写入安全机制
   - 写入前 snapshot 相关文件。
   - 写入失败时 rollback。
   - 使用原子写入，避免半写入 JSON。
   - 与 cc-switch 同时存在时，需要检测当前 profile 归属，避免互相覆盖。

3. 模型路由数据结构
   - 保存 `route_id`、`labelOverride`、`upstreamModel`、`provider`、`supports1m`。
   - 固定提供 Sonnet / Opus / Fable / Haiku 四档 route。
   - 对用户输入的非安全 route 进行修复或拒绝。

4. `/models` 接口
   - 向 Claude Desktop 返回安全 route id 列表。
   - 返回 `supports1m`。
   - 只把 `labelOverride` 写进 Desktop profile，不把真实上游模型暴露成模型 ID。

5. 请求映射
   - 将 Claude Desktop 请求体中的 `model: claude-*` 映射成上游真实模型名。
   - 处理 `[1m]` 标记。
   - 兼容 Desktop 可能请求完整官方模型名或角色派生模型名。
   - 处理 Opus route 旧别名。
   - 处理 Fable 缺档时的降级策略。
   - 映射后再进入现有供应商转发链路。

6. 设置 UI
   - 增加 Claude Desktop 路由配置页。
   - 至少提供四档：Sonnet / Opus / Fable / Haiku。
   - 每档配置菜单显示名、实际请求模型、供应商、1M 能力。
   - 显示当前 Desktop 配置是否由 UniGate 管理，以及一键应用/恢复。

7. 测试和兼容矩阵
   - 配置文件读写、rollback、profile 生成单测。
   - route 安全校验、非安全 route 修复、空档继承单测。
   - `/models` 响应单测。
   - 请求映射单测：精确 route、完整官方名、Opus 旧别名、Fable 降级、`[1m]`。
   - 与 cc-switch 共存测试：不覆盖 cc-switch profile，或明确提示用户迁移管理权。

## 难度评估

整体难度：中高。

主要原因不是单纯的请求转发，而是 Claude Desktop 配置写入和兼容策略比较多。尤其是 profile 写入、deployment mode 切换、失败回滚、与 cc-switch 共存，这些都属于高风险用户环境修改。实现不完整时，最坏结果不是某个模型请求失败，而是用户 Claude Desktop 被配置到不可用状态。

兼容性风险：

1. Claude Desktop 对可识别模型名的规则可能继续变化。
2. Desktop 的子 agent 或内部调用不一定总是请求 manifest 中返回的短 route，可能请求带日期后缀的官方模型名。
3. cc-switch 和 UniGate 如果同时管理 Claude Desktop profile，必须有明确的 ownership，否则会互相覆盖。
4. 不同系统路径和 Claude Desktop 版本下配置结构可能不同。

## 建议方案

短期建议继续采用方案 1。它利用 cc-switch 已经成熟的 Desktop 路由写入能力，UniGate 只负责正确展示真实上游模型和转发诊断，风险最低。

只有在 UniGate 需要脱离 cc-switch、独立管理 Claude Desktop，或者希望给用户提供一站式 Desktop 路由配置体验时，才建议进入方案 2。

推荐分阶段实现方案 2：

1. 只读诊断阶段
   - 读取 Claude Desktop 当前 profile。
   - 判断当前由官方、cc-switch 还是 UniGate 管理。
   - 显示 route、label、upstream 映射关系。

2. 内置路由阶段
   - 先不写 Claude Desktop，只在 UniGate 本地实现 route 到 upstream model 的映射。
   - 完成 `/models` 和请求映射测试。

3. Profile 写入阶段
   - 增加 UniGate profile 写入、rollback、恢复官方模式。
   - 默认拒绝覆盖 cc-switch profile，除非用户显式确认迁移。

4. UI 管理阶段
   - 提供四档路由配置和一键应用。
   - 增加状态检查、错误恢复、导入 cc-switch 路由配置。

5. 兼容扩展阶段
   - 跟进 Claude Desktop 新 route 规则。
   - 增加更多 provider 格式和边界请求测试。

结论：方案 2 可行，但不是小改动。最小可用版本也需要覆盖 profile 写入、路由数据、`/models`、请求映射和恢复机制。当前阶段如果目标是修复模型展示和实际请求模型识别，方案 1 是更稳妥的实现路径。
