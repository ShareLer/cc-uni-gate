# Uni Gate 更新方案

Uni Gate 使用 Sparkle 2 做 macOS 原生更新。设计目标是长期可维护，并且把失败影响限制在更新流程内部。

## 运行时架构

- `Sources/UniGateApp/AppUpdateService.swift` 封装 Sparkle。
- 设置页只读取 `AppUpdatePhase`，不直接依赖 Sparkle 类型。
- `checkForUpdates()` 调用 Sparkle 的 `checkForUpdateInformation()`，只做探测，不下载、不安装。
- `installAvailableUpdate()` 只在状态为 `available` 时调用 Sparkle 的 `checkForUpdates()`，开始下载和安装流程。
- `available` 状态有 15 分钟内存超时；用户长时间不点 `下载并更新` 时回到 `idle`。
- Sparkle 初始化失败时，应用只把更新状态设为 `unavailable`，不会影响代理启动。

## 失败安全边界

必须满足：

- 检查失败：回到可重试状态，不退出应用。
- 没有新版本：回到 `idle`，不下载、不安装。
- 下载失败：显示失败信息，当前应用继续运行。
- 解压或安装准备失败：显示失败信息，当前应用继续运行。
- Sparkle 配置缺失：更新卡片显示不可用，应用和代理继续启动。
- 已安装版本不会由 Uni Gate 自己的脚本覆盖；替换安装只交给 Sparkle。

需要明确的边界：

- 用户点击 `下载并更新` 后，Sparkle 在下载和校验完成后会进入安装/重启阶段。这个阶段的重启是用户已授权的更新动作，不是检查或下载失败导致的退出。
- Uni Gate 不实现自定义“替换当前 app”的安装器，避免半覆盖、半删除导致应用无法启动。
- Sparkle 的 Ed25519 签名和 appcast 校验是发布流程的一部分；发布缺失签名或 appcast 错误时，运行中的旧版本应保持可用。

## 单一版本源

根目录 `VERSION` 是唯一版本号来源。

发布前更新：

```bash
printf '0.1.12\n' > VERSION
```

打包脚本会把该值写入：

- `CFBundleShortVersionString`
- `CFBundleVersion`
- 设置页展示的当前版本

## 本地构建验证

只构建 app bundle，不安装到 `/Applications`：

```bash
BUILD_ONLY=1 ./scripts/build-install-run.sh
```

默认会从 GitHub Releases 的 `latest/download/appcast.xml` 读取更新源，并从 `config/sparkle-public-ed-key.txt` 读取公钥。

验证项：

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  ".build/app/CC Uni Gate.app/Contents/Info.plist"

otool -l ".build/app/CC Uni Gate.app/Contents/MacOS/UniGateApp" \
  | grep "@executable_path/../Frameworks"

test -d ".build/app/CC Uni Gate.app/Contents/Frameworks/Sparkle.framework/Updater.app"
test -d ".build/app/CC Uni Gate.app/Contents/Frameworks/Sparkle.framework/XPCServices"

codesign --verify --deep --strict ".build/app/CC Uni Gate.app"
```

## 发布步骤

1. 生成 Sparkle Ed25519 key：

   ```bash
   xcodebuild -project .build/checkouts/Sparkle/Sparkle.xcodeproj \
     -scheme generate_keys \
     -configuration Release \
     -derivedDataPath .build/sparkle-tools \
     build

   .build/sparkle-tools/Build/Products/Release/generate_keys
   ```

   如果只是想打印已经存在的 public key，可以再执行：

   ```bash
   .build/sparkle-tools/Build/Products/Release/generate_keys -p
   ```

2. 更新 `VERSION` 并运行一键发布脚本：

   ```bash
   ./scripts/publish-github-release.sh
   ```

3. 脚本会自动：

   - 构建 app 并嵌入 Sparkle framework
   - 生成发布 zip
   - 用 Sparkle `generate_appcast` 生成 appcast
   - 把 zip 和 appcast 上传到 GitHub Release

4. app 侧默认读取：

   - `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`
   - `config/sparkle-public-ed-key.txt`

## 签名说明

当前项目沿用 ad-hoc 签名，适合本地或小范围分发。更稳定的公开发布应使用 Apple Developer ID 签名和 notarization，再生成 Sparkle appcast。

不要把“移除 quarantine”作为自动更新的一部分。首次手动安装可能需要用户处理 macOS Gatekeeper，后续更新应走 Sparkle 的签名校验和安装流程。
