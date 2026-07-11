# UniGate

UniGate 是一个运行在 macOS 菜单栏的本地模型路由器。它可以把同一个模型关联到多个供应商，并在菜单栏中实时切换：例如 `gpt-5.6-sol` 可以随时从官方订阅切到第三方供应商，客户端无需重启，也不用修改模型名。

UniGate 还可以创建自定义聚合模型，把不同供应商的不同模型收在同一个入口下。例如让客户端始终请求 `coding`，再按需把它切换到 OpenAI Official 的 `gpt-5.6-sol`、第三方的 `gpt-5.5` 或 DeepSeek 的 `deepseek-v4`。

UniGate 读取 [cc-switch](https://github.com/farion1231/cc-switch) 中已有的供应商配置，也支持直接添加供应商，为 Codex、Claude Code 和 Claude Desktop 维护独立的模型路由。cc-switch 负责供应商和客户端配置，UniGate 负责每个模型当前实际走向哪个目标。

[下载最新版本](https://github.com/ShareLer/cc-uni-gate/releases/latest) · [查看 Releases](https://github.com/ShareLer/cc-uni-gate/releases) · [反馈问题](https://github.com/ShareLer/cc-uni-gate/issues)

## 示例截图

| | | |
|---|---|---|
| <img src="assets/images/UniGate-1.png" alt="Uni Gate 示例截图 1" width="260"> | <img src="assets/images/UniGate-2.png" alt="Uni Gate 示例截图 2" width="260"> | <img src="assets/images/UniGate-4.png" alt="Uni Gate 示例截图 3" width="260"> |
| <img src="assets/images/UniGate-5.png" alt="Uni Gate 示例截图 4" width="260"> | <img src="assets/images/UniGate-6.png" alt="Uni Gate 示例截图 5" width="260"> | <img src="assets/images/UniGate-7.png" alt="Uni Gate 示例截图 6" width="260"> |

## 能做什么

### 按模型切换供应商

同一个模型可以同时由多个供应商提供：

```text
gpt-5.6-sol
  OpenAI Official
  ahoo-gpt
  gpt-free
```

在菜单栏展开模型，选中新的供应商，后续请求就会走新的上游。每个模型保存自己的选择，互不影响。

### 编辑 Codex 路由

每个 Codex 模型都可以单独编辑转发目标：既能增删同名模型的供应商，也能加入其他模型作为目标。不需要的发现模型可以停用；明确写在 cc-switch 的 UniGate 供应商模型目录中的固定模型始终保留。

### 自定义模型入口

可以创建一个稳定的模型名，例如 `coding`，再把它绑定到不同供应商、不同模型：

```text
coding
  OpenAI Official / gpt-5.6-sol
  ahoo-gpt       / gpt-5.5
  DeepSeek       / deepseek-v4
```

客户端始终请求 `coding`，真实目标在 UniGate 中切换。这适合不想频繁修改 Codex 或 Claude Code 配置的场景。

### 供应商与模型探测

UniGate 会读取 cc-switch 中的 Codex、Claude Code 和 Claude Desktop 供应商，也可以在供应商页直接添加普通供应商。手动添加时可以设置：

- Base URL 或完整请求 URL。
- OpenAI Responses、OpenAI Chat 或 Anthropic 协议。
- API Key。
- 模型列表探测。

模型探测结果会缓存。某次探测失败时，最近一次成功结果仍可保留，不会因为短暂的网络问题清空现有路由。

### Codex 官方订阅

在供应商页新增“Codex 官方”，或者使用从 cc-switch 识别到的官方供应商，然后点击登录。UniGate 会完成 OAuth PKCE 登录、自动刷新凭据，并把请求转发到 Codex 官方服务。

官方供应商除了登录和请求鉴权外，与普通供应商使用同一套路由逻辑：可以参与模型探测、同名聚合、手动切换和跨模型路由。OAuth 凭据保存在 macOS Keychain，不会写入 cc-switch 数据库或 UniGate 的 JSON 配置。

### 网络与诊断

可以全局或按供应商选择跟随系统代理、直接连接，也可以为指定域名设置直连规则。设置页同时提供健康检查、请求统计和脱敏诊断，方便定位配置或网络问题。

## 快速开始

### 环境要求

- macOS 14 或更高版本。
- 已安装 cc-switch，并已经生成 `cc-switch.db`。

UniGate 可以保存自己添加的供应商，但当前仍使用 cc-switch 数据库作为主要配置入口，因此首次使用前需要准备好 `cc-switch.db`。

### 1. 安装

从 [GitHub Releases](https://github.com/ShareLer/cc-uni-gate/releases/latest) 下载 `CC-Uni-Gate-v*-macos.zip`，解压后将 `CC Uni Gate.app` 放入“应用程序”并启动。

UniGate 启动后常驻菜单栏。状态灯为绿色时，本地代理已经可以接收请求；黄色表示最近一次上游请求失败，红色表示本地代理没有正常运行。

### 2. 连接 cc-switch

打开 UniGate 的 `设置`，确认数据库路径。默认位置是：

```text
~/.cc-switch/cc-switch.db
```

UniGate 以只读方式加载这个数据库。数据库发生变化时，供应商和模型会自动刷新，也可以在菜单中手动点击 `reload`。

### 3. 导入本地入口

在 `设置` 中点击 Codex 或 Claude Code 旁边的“导入”，cc-switch 会打开供应商导入页面。确认导入后，将 UniGate 设为该应用的当前供应商。

| 客户端 | UniGate 地址 | 额外要求 |
|---|---|---|
| Codex | `http://127.0.0.1:17888/codex` | 可选：在 cc-switch 中维护固定模型目录 |
| Claude Code | `http://127.0.0.1:17888/claude-code` | 无 |
| Claude Desktop | `http://127.0.0.1:17888/claude-desktop` | 需要在 cc-switch 中开启模型映射 |

Claude Desktop 的 `labelOverride` 是客户端菜单里的名称，`model` 才是真正发往上游的模型。UniGate 按 `model` 建立路由；没有模型映射时，不会从其他环境变量猜测模型。

### 4. 探测模型

进入 `供应商`，点击模型探测。UniGate 会汇总各供应商返回的模型，并按客户端和模型名生成路由。

对于 Codex：

- cc-switch 的 UniGate 供应商中明确配置的模型会显示为固定模型。
- 其他供应商探测到的模型会去重显示，可以编辑路由或停用。
- 同一模型由多个供应商提供时，展开模型即可切换。

### 5. 开始切换

回到模型列表，展开一个有多个目标的模型并选择供应商。路由立即生效，Codex、Claude Code 和 Claude Desktop 不需要重启。

## 路由规则

### 默认：聚合同名模型

当多个供应商都提供 `gpt-5.6-sol` 时，UniGate 会自动把它们放到同一个 `gpt-5.6-sol` 下面，不需要手动配置。你只需在菜单栏选择当前使用的供应商。

### 编辑已有模型

编辑一个已有 Codex 模型后，只有你选中的目标会保留。目标可以是同名模型，也可以是其他模型；点击“恢复自动”后，会重新聚合所有供应商的同名模型。

### 新增自定义模型名

自定义模型会增加一个新的客户端模型名，例如 `coding`，其目标可以来自任意供应商和模型。它不会修改已有模型，只是增加一个统一入口。

如果客户端通过 cc-switch 获取模型列表，自定义模型名也需要加入 cc-switch 中 UniGate 供应商的模型目录，客户端才能发现它。UniGate 中的“强制启用”可以让路由本身脱离这份目录工作，但无法改变客户端自己的模型列表行为。

## Codex 官方登录

1. 切换到 `供应商 -> Codex`。
2. 新增供应商，类型选择 `Codex 官方`，填写展示名称并保存。
3. 在供应商卡片上点击登录，按浏览器提示完成授权。
4. 登录成功后执行模型探测，再像普通供应商一样加入或切换路由。

UniGate 不复用 cc-switch 或 Codex CLI 已有的 OAuth token。每个官方供应商的登录状态由 UniGate 单独管理，access token、refresh token 和账号信息只保存在 Keychain。

## 工作方式

```text
                      只读供应商、模型与协议配置
cc-switch.db  --------------------------------------+
                                                     |
Codex / Claude Code / Claude Desktop                 v
                -> UniGate 本地代理 -> 实际供应商 / Codex 官方订阅
                         |
                         +-> 本地模型路由与网络策略
```

UniGate 默认只监听 `127.0.0.1:17888`。它不会直接修改 cc-switch 的供应商、密钥或当前供应商状态；界面中的“导入”通过 cc-switch 自己的导入链接完成。

第三方供应商继续使用各自的 API Key。只有路由目标是 Codex 官方供应商时，UniGate 才会读取对应的 OAuth 凭据并替换上游鉴权信息。

## 本地数据

UniGate 的配置位于：

```text
~/Library/Application Support/UniGate
```

| 文件 | 内容 |
|---|---|
| `routes.json` | 当前模型路由 |
| `preferences.json` | 端口、可见模型、网络策略等设置 |
| `custom-models.json` | 自定义模型和显式 Codex 路由 |
| `custom-providers.json` | 手动添加的供应商，不包含 API Key 明文 |
| `model-discovery.json` | 最近一次模型探测结果 |
| `logs/unigate.log` | 运行日志 |

手动添加供应商的 API Key、Codex 官方 OAuth 凭据和本地代理凭据保存在 macOS Keychain。诊断信息会对密钥和敏感字段做脱敏处理。

## 管理接口

UniGate 提供几个用于检查和自动化的本地接口：

```text
GET  /__manager/health
GET  /__manager/catalog
POST /__manager/reload
POST /__manager/routes
```

写接口需要设置环境变量 `UNIGATE_MANAGER_TOKEN`，并携带 `Authorization: Bearer <token>`。没有配置 token 时，写操作默认关闭。

客户端常用入口：

```text
GET  /codex/v1/models
POST /codex/v1/responses
POST /codex/v1/responses/compact
GET  /claude-code/v1/models
POST /claude-code/v1/messages
GET  /claude-desktop/v1/models
POST /claude-desktop/v1/messages
```

## 从源码构建

项目使用 Swift 6 和 Swift Package Manager，最低运行版本为 macOS 14。

```bash
# 运行测试
swift test

# 直接运行可执行程序
swift run UniGateApp

# 构建、安装到 /Applications 并启动
./scripts/build-install-run.sh

# 只生成 app bundle，不安装
BUILD_ONLY=1 ./scripts/build-install-run.sh
```

发布版本、签名、公证和 Sparkle appcast 的维护流程见 [docs/updater.md](docs/updater.md)。
