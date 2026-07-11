# UniGate 发布与更新

UniGate 通过 GitHub Releases 分发，使用 Sparkle 2 完成应用内更新。项目不使用 Apple Developer ID 或 Apple notarization：app bundle 采用 ad-hoc 签名，更新 zip 采用 Sparkle EdDSA 签名。

这两层签名解决的问题不同：

- ad-hoc 签名保证 app bundle 和嵌套的 Sparkle 组件结构完整。
- Sparkle EdDSA 证明更新包由 UniGate 发布，并在解压前校验文件未被篡改。
- 第一次从浏览器下载时，用户仍需手动移除 macOS quarantine；EdDSA 不替代 Gatekeeper 的 Apple 信任链。

## 用户流程

### 第一次安装

1. 从 GitHub Release 下载 zip。
2. 解压 zip。
3. 将 `CC Uni Gate.app` 移动到“应用程序”。
4. 执行：

   ```bash
   xattr -cr "/Applications/CC Uni Gate.app"
   ```

5. 打开应用。

### 应用内更新

1. 打开 `设置 -> 应用更新`。
2. 点击“检查更新”。
3. 发现新版本后点击“下载并更新”。
4. Sparkle 校验 EdDSA 签名，安装更新并重启应用。

通过 Sparkle 更新不需要再次执行 `xattr`。重新从浏览器手动下载安装包时，需要再次处理 quarantine。

## 运行时架构

- `Sources/UniGateApp/AppUpdateService.swift` 封装 Sparkle。
- `checkForUpdates()` 只检查版本，不立即下载。
- `installAvailableUpdate()` 在用户点击“下载并更新”后启动下载和安装。
- 检查、下载或安装准备失败时，当前代理继续运行。
- `SUVerifyUpdateBeforeExtraction=true`，更新包会在解压前验证 EdDSA 签名。
- 更新源固定为 GitHub 最新 Release 的 `appcast.xml`。

默认更新地址：

```text
https://github.com/ShareLer/cc-uni-gate/releases/latest/download/appcast.xml
```

## Sparkle 密钥

公钥保存在：

```text
config/sparkle-public-ed-key.txt
```

私钥由 Sparkle `generate_keys` 保存在发布机器的 macOS Keychain。发布脚本会读取 Keychain 中的私钥，并确认它与仓库公钥匹配。

这对密钥一旦用于公开版本就不能随意重新生成。丢失私钥后，已安装版本无法验证使用新密钥签名的更新包。应单独备份发布机器的 Sparkle 私钥。

新项目第一次生成密钥时执行：

```bash
swift package resolve

xcodebuild -project .build/checkouts/Sparkle/Sparkle.xcodeproj \
  -scheme generate_keys \
  -configuration Release \
  -derivedDataPath .build/sparkle-tools \
  build

.build/sparkle-tools/Build/Products/Release/generate_keys
```

查看当前 Keychain 私钥对应的公钥：

```bash
.build/sparkle-tools/Build/Products/Release/generate_keys -p
```

UniGate 已经有正在使用的密钥，不应再次运行不带 `-p` 的生成命令。

## 版本号

根目录的 `VERSION` 是唯一版本号来源。它会写入：

- `CFBundleShortVersionString`
- `CFBundleVersion`
- Git tag 和 GitHub Release 名称
- Sparkle appcast

发布新版本前先更新 `VERSION`，运行测试，然后提交并推送所有改动：

```bash
printf '<next-version>\n' > VERSION
swift test
git add -A
git commit -m "build: prepare <next-version> release"
git push origin main
```

`git add -A` 应包含这次版本计划发布的全部代码、文档和版本号改动。提交前先检查 `git diff --cached`；发布脚本只接受已经推送到 `origin/main` 的干净提交。

## 两阶段发布

发布只有一套流程，分为构建验证和上传两个阶段。

### 1. 构建、安装和验证

```bash
./scripts/publish-github-release.sh build
```

脚本会：

1. 构建 Release app 并嵌入 Sparkle framework。
2. 对 app 和所有嵌套组件执行 ad-hoc 签名。
3. 检查 bundle 版本和 Sparkle 公钥。
4. 确认 Keychain 私钥与仓库公钥匹配。
5. 生成 zip、SHA-256 和只包含当前版本的 appcast。
6. 检查 appcast 版本、URL 和 EdDSA 签名。
7. 将同一个 app bundle 安装到 `/Applications` 并启动。
8. 等待本地代理健康检查通过。
9. 保存产物版本、提交和哈希到 release manifest。

构建产物位于：

```text
.build/release-artifacts/CC-Uni-Gate-v*-macos.zip
.build/release-artifacts/CC-Uni-Gate-v*-macos.zip.sha256
.build/release-artifacts/appcast.xml
.build/release-artifacts/release-manifest.txt
```

脚本完成后，应在本地实际打开菜单栏、设置页和核心路由，再进入上传阶段。

### 2. 上传已验证产物

```bash
./scripts/publish-github-release.sh publish
```

上传阶段不会重新构建。它会重新检查：

- 工作区是否干净。
- 当前提交是否已经推送到 `origin/main`。
- 产物是否来自当前提交和当前版本。
- zip 和 appcast 的哈希是否与本地验证时一致。
- appcast 是否只有当前版本并带有 EdDSA 签名。
- Git tag 和 GitHub Release 是否尚未存在。

检查通过后，脚本创建 GitHub Release，并上传：

```text
CC-Uni-Gate-v*-macos.zip
CC-Uni-Gate-v*-macos.zip.sha256
appcast.xml
```

Release Notes 只用于记录版本改动，由 GitHub 根据提交自动生成。第一次安装和应用内更新步骤统一维护在 README。

## 发布后检查

发布完成后确认：

```bash
gh release view "v$(cat VERSION)"
curl -fsSL "https://github.com/ShareLer/cc-uni-gate/releases/latest/download/appcast.xml"
```

还需要至少执行一次真实的旧版本升级：

1. 安装并打开上一个公开版本。
2. 点击“检查更新”。
3. 确认能发现新版本。
4. 点击“下载并更新”。
5. 确认 EdDSA 校验、替换、重启和版本显示均正常。

## 安全边界

- 不要在发布脚本中关闭 Gatekeeper，也不要调用 `spctl --master-disable`。
- `xattr -cr` 只作为用户确认 GitHub 下载来源后的首次安装步骤。
- 不要上传没有 EdDSA 签名的更新包。
- 不要覆盖已经发布的 tag 或 Release；修复发布问题时提升版本号。
- 不要重新生成 Sparkle 密钥，除非已经设计并验证完整的密钥迁移流程。
