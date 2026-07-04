# Uni Gate 更新方案

Uni Gate 使用 Sparkle 2 做 macOS 原生更新。设计目标是长期可维护，并且把失败影响限制在更新流程内部。

## 运行时架构

- `Sources/UniGateApp/AppUpdateService.swift` 封装 Sparkle。
- 设置页只读取 `AppUpdatePhase`，不直接依赖 Sparkle 类型。
- `checkForUpdates()` 调用 Sparkle 的 `checkForUpdateInformation()`，只做探测，不下载、不安装。
- `installAvailableUpdate()` 只在状态为 `available` 时调用 Sparkle 的 `checkForUpdates()`，开始下载和安装流程。
- `available` 状态有 15 分钟内存超时；用户长时间不点 `下载并更新` 时回到 `idle`。
- 没有新版本时，更新卡片会停留在“未发现新版本”结果态，而不是静默回到空白。
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
printf '0.1.14\n' > VERSION
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
   - 用 Apple Developer ID 重新签名 app bundle
   - 对构建产物执行 notarization，并把票据 staple 到 app bundle
   - 生成发布 zip
   - 用 Sparkle `generate_appcast` 生成 appcast
   - 把 zip 和 appcast 上传到 GitHub Release

   如果只是想本地打包，不上传 GitHub，可以这样运行：

   ```bash
   NOTARIZE_RELEASE=0 UPLOAD_TO_GITHUB=0 ./scripts/publish-github-release.sh
   ```

4. app 侧默认读取：

   - `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`
   - `config/sparkle-public-ed-key.txt`
   - 这些值由发布脚本写入产物，不需要用户手工配置

## 签名说明

本地 `BUILD_ONLY=1 ./scripts/build-install-run.sh` 仍然可以生成 ad-hoc 构建包，适合开发验证。

公开发布必须走 Apple Developer ID 签名 + notarization。`scripts/publish-github-release.sh` 会在没有可用证书或 notarytool profile 时直接失败，避免发布一个会被 Gatekeeper 拦截的安装包。

这里把边界写死，原因是之前最容易出问题的就是把“本地可运行”误当成“可公开分发”。两者在 macOS 上不是一回事：

- 本地构建：允许 ad-hoc 签名，只用于开发和排查
- 公开 release：必须 Developer ID + notarization + staple
- 只有公开 release 才应该出现在 GitHub Releases 里供用户下载

推荐的检查顺序是：

1. 先跑 `BUILD_ONLY=1 ./scripts/build-install-run.sh`
2. 再跑 `NOTARIZE_RELEASE=0 UPLOAD_TO_GITHUB=0 ./scripts/publish-github-release.sh`
3. 最后在真正具备 Apple 凭据时再执行正式发布

这样可以把“bundle 内容正确”和“macOS 允许打开”分开验证，避免把 Gatekeeper 问题误判成 Sparkle 或业务逻辑问题。

推荐准备方式：

```bash
xcrun notarytool store-credentials unigate-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "xxxx-xxxx-xxxx-xxxx"

export APPLE_DEVELOPER_ID_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
export NOTARYTOOL_PROFILE="unigate-notary"
```

不要把“移除 quarantine”作为自动更新的一部分。首次手动安装可能需要用户处理 macOS Gatekeeper，后续更新应走 Sparkle 的签名校验和安装流程。
