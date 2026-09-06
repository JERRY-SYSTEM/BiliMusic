# BiliBeat

基于 Flutter 开发的哔哩哔哩音频播放器。

## 功能

- [x] 歌曲搜索和播放
- [x] 账号登录与收藏夹同步
- [x] 自建歌单
- [x] 歌词搜索
- [x] 多主题设置
- [x] 缓存管理
- [ ] etc...

## 下载与安装

- **[最新版本](https://github.com/JERRY-SYSTEM/BiliBeat/releases/latest)**

---

### Android 安装

1. 在 Latest Release 页面下载 `bilibeat-x.x.x-arm64-v8a.apk` 安装包。
2. 在 Android 设备安卓下载的 `.apk` 文件（需 Android 6.0 及以上版本，由于签名使用的是LSPatch默认签名，因此可能会误报为病毒）。

---

### iOS 安装

BiliBeat 未上架 Apple App Store，发布构建以未签名归档包（`bilibeat-x.x.x-unsigned.ipa`）形式提供。iOS 安装前需使用个人开发者证书进行签名（需 iOS 13.0 及以上版本）。

#### 方式一：通过 LiveContainer 安装（推荐）

1. 按照 [视频教程](https://b23.tv/owg4oOo) 或 [文字教程](https://www.luvwan.com/7848.html) 安装LiveContainer。
2. 在首页导入 `.ipa` 文件，启动。

#### 方式二：通过 AltStore 安装

AltStore 支持本地安装，并可通过 Wi-Fi 自动续签后台证书。

1. **安装 AltServer**：在 macOS 或 Windows 上从 [altstore.io](https://altstore.io) 下载并运行 AltServer。
2. **部署 AltStore 至设备**：
   - 通过 USB 连接 iOS 设备至电脑，并确认设备信任。
   - 点击菜单栏或系统托盘中的 AltServer 图标，选择 `Install AltStore`，再选择已连接的 iOS 设备。
   - 使用 Apple ID 登录以签发免费开发证书。
3. **信任描述文件**：在 iOS 设备上进入 `设置` > `通用` > `VPN 与设备管理`，在"开发者 App"下找到您的 Apple ID 并选择`信任`。
4. **安装 BiliBeat**：
   - 使用 iOS 设备上的 Safari 下载 `bilibeat-x.x.x-unsigned.ipa`。
   - 打开 AltStore，进入"我的 App"页面，点击 `+` 图标并选择已下载的 `.ipa` 文件。
   - *自动续签*：只要主机电脑与设备处于同一 Wi-Fi 网络且保持运行，AltServer 会自动续签 7 天有效期的证书。

#### 方式三：通过 Sideloadly 安装

Sideloadly 是一款基于桌面端的直装工具，可通过 USB 直接安装已签名安装包。

1. **安装 Sideloadly**：在 macOS 或 Windows 上从 [sideloadly.io](https://sideloadly.io) 下载并安装 Sideloadly。
2. **部署安装包**：
   - 通过 USB 连接 iOS 设备至电脑。
   - 启动 Sideloadly，将 `bilibeat-x.x.x-unsigned.ipa` 拖入应用窗口。
   - 在 `Apple Account` 一栏输入您的 Apple ID，点击 `Start` 开始签名安装。
3. **信任描述文件**：安装完成后，在 iOS 设备的 `设置` > `通用` > `VPN 与设备管理` 中信任与您 Apple ID 关联的证书。

## 签名（Android）

发布构建使用 `android/key.properties` 中的密钥进行签名。首次构建前请执行以下命令生成：

```bash
tool/make_keystore.sh
```

请务必妥善备份 `android/bilibeat-release.jks` 与 `android/key.properties` 两个文件，且切勿提交至仓库（两者均已被 gitignore 排除）。密钥一旦丢失将无法找回——更换密钥将无法对既有安装进行升级。

如缺少上述文件，构建将回退使用调试密钥并给出警告。可使用以下命令核验实际发布产物所使用的签名：

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

## 构建

#### 方法一：Github Actions （推荐）

运行 Release Build 可以直接构建产物并发布到Releases。

#### 方法二：本地构建

```bash
tool/build_release.sh          # Android（默认）
```

```bash
tool/build_release.sh ios
```

```bash
tool/build_release.sh all
```

**Android** — 单一混淆构建的 **arm64-v8a** APK。项目已永久放弃 32 位架构；ARM 笔记本（Apple Silicon、Windows on ARM）同样使用 arm64-v8a，因此该构建可覆盖上述全部设备。**需要 JDK 21 及以上版本**——AGP 内置 lint 在 JDK 17 下会因 `NoSuchMethodError` 失败，报错信息与 Java 版本无关，难以排查。

**iOS** — 混淆构建的**未签名 .ipa**（位于 `build/ios/ipa/`）。本应用未注册 Apple Developer 账号，因此无法上架 App Store；请通过 AltStore / Sideloadly / 自有描述文件签名安装，即以您自己的身份为其签名。构建需 macOS 及 Xcode，支持 iOS 13 及以上版本。

iOS 工程**不依赖 CocoaPods**。本项目使用的全部插件均自带 `Package.swift`，已通过 Swift Package Manager 完成集成，并有意删除了 `ios/Podfile`——残留的 Podfile 会导致构建在未安装 CocoaPods 时报错。若未来某个插件仅支持 Pods 集成，请使用 `flutter create .` 重新生成 Podfile，并在本文件中说明。

混淆意味着发布构建的崩溃堆栈需配合对应构建的符号文件方可解析。符号文件输出至 `symbols/<版本号>/` 目录，请妥善保留（并随发布一并提供），解码命令如下：

```bash
flutter symbolize -i trace.txt -d symbols/<版本号>/app.android-arm64.symbols
```

（iOS 崩溃堆栈使用同一目录下的 `app.ios-arm64.symbols`。）

## 开发

日常开发只需标准 Flutter 工具链：

```bash
flutter analyze   # 静态检查（未使用的成员与死代码在本项目中按错误处理）
flutter test      # 单元测试与 widget 测试
```

歌词标题解析（`LyricsEngine.cleanTitle`）的回归语料位于
`test/fixtures/real_bilibili_titles.json`（540 条真实 B 站标题）。
调整解析规则前请先补充或核对语料，避免依赖机器本地的临时文件。

（`.github/workflows/ci.yml`）改为手动执行
`flutter analyze` 与 `flutter test`，Flutter 版本固定为 3.44.8，升级 SDK 时请同步更新。

## 致谢

本项目许多功能参考 **[AprDeci/bili-music](https://github.com/AprDeci/bili-music)**

## 许可证

MIT
