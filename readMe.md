# Amaveth

项目目录 `Amaveth`，参考 Monefy / com.monefy.app.lite，保留独立英文记账业务，不替换其他项目。Android applicationId：`com.aaazero.yueh`；iOS Bundle ID：`com.aaazero.yueh.ios`。显示名称按 2026-11-11 规范 §13.1 的 18 个字母校验；包名字符规则与显示名称规则不同，§13.2 只要求双端不同。名称未做商标可用性确认。

## 当前范围与依据

- 当前版本 `1.0.2+3`。A 面无需登录、广告、订阅和内购；没有内部 IM、Demo、A/B 开关入口。
- 当前 B 面依据：`/Users/ddg/chatgpt/google/马甲包对接规范2026-11-11.md`，SHA-256 `814a30da1551eec350a4ea6e196b43c994b354093d817cf82598d738853f7865`。
- DataVerna/hashcalc `71e141c521128288cb915be59418bc1fcf799a5b` 是抽取基线；新规范明确要求的启动、mock 开关与缓存行为优先，不能继续宣称整个启动行为与旧基线完全相同。
- 项目内置源码，不依赖远程 im_shell。Android 原生 Activity 承载唯一 WebView；iOS 提前创建唯一 WKWebView，并由原生窗口展示，Flutter 保留业务与桥接/推送/看门狗状态处理。
- 读账本失败不会阻挡 B 面。main.dart 的 SDK/方向初始化不阻塞启动；WebView 缓存加载早于 Dart main/runApp。

## mock 接口与缓存（§2.3、§9.6）

配置地址目前为 `https://u4k2.top/api/config`，保留工作区既有值；2026-11-11 从本机请求返回 403，未证实生产接口联调可用。需由项目组确认出口 IP 白名单、接口归属与实际 200 响应样例。禁止为此在后台创建测试接口。

- 200 + 有效 HTTPS `h5url`：保存并开启 B。解析支持顶层 `h5url` 或 `data.h5url`；规范未给出 JSON 外壳，真实样例仍需复核。旧 `data.url` 不作为新规范成功响应。
- URL 字符串原样加载，不重拼 query、不覆盖渠道码；不变不重载，变化立即加载新地址。
- 404：清除 B 地址缓存，立即停用 B 并切到 A；保留网站 cookies、登录存储、缓存、IndexedDB 和 Service Worker 数据。
- 网络错误、超时、5xx、403、无效 200：不能等同 404。有 B 缓存则继续使用；无缓存且重试后仍不可达则展示 A。后一条是用户于 2026-11-11 的补充口径，不是规范原文明示的关闭规则，不持久化成关闭状态。
- 真正回前台时继续比对，包括正在 A 面时。Activity 内部切换不当作一次新的前台进入。
- 冷启动等待由系统/原生同款 splash 承担，移除 Flutter 三秒后先露 A、Flutter logo loading、Connecting/转圈。B 页面自身首次加载失败仍使用英文原生重试页；这与 mock 无缓存失败显示 A 是两种情况。
- Android 原生缓存为进程启动的权威来源；iOS 使用本应用 UserDefaults。启动时重新生成当前版本的六项注入信息，不复用上个版本的注入脚本。

## 客户端配置与平台凭据

| 项目 | 配置及状态 |
| --- | --- |
| mock 接口 | `SSG_CONFIG_URL`，默认上述既有地址；Android Gradle 与 iOS Info.plist 均透传同一 dart-define，原生启动不等待 Dart 传值 |
| Web 地址 | 由接口 `h5url` 决定；`SSG_WEB_URL` 仅保留兼容默认值，不会绕过接口强制启用 B |
| 渠道码 | 可选，由返回的完整 URL 携带，不写死或自动添加 |
| Android OneSignal | `SSG_ANDROID_ONESIGNAL_ID` 目前为空，待提供本 App 的配置 |
| iOS OneSignal | `SSG_IOS_ONESIGNAL_ID` 目前为空，待提供本 App 的配置，不能借用其他 App 身份 |
| Firebase/APNs | 未配置验收；需在相应 OneSignal 后台完成，服务端还需登记双端包名及各自 App ID/REST Key |
| 主体/邮箱 | `AFRICAN PROVERBS PAGE LLC`、`raincofarri@gmail.com`；2026-11-14 用户确认 |
| Google Sites | `https://sites.google.com/view/amaveth/privacy-policy` 与 `/terms-of-use`；只配置了占位 URL，尚未发布或验证 |

App API Key、Firebase Admin 私钥、APNs 私钥不能放入 JSON 客户端参数、源码、APK、说明文档或 Git。修改 iOS Bundle ID 后需按新 ID 配置签名团队、APNs 和服务端登记；不宣称旧 ID 的配置自动可复用。Android 保留包名和签名以兼容已有本地数据。

`config/test.example.json` 和 `production.example.json` 仅为客户端构建参数示例。可以区分 OneSignal 等测试/正式凭据，但 mock 后台只建生产接口，不能将客户端调试配置理解成允许创建后台测试接口。复制为被 Git 忽略的 `*.local.json` 后替换公开客户端值。

## 构建与调试

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
flutter build ios --release --no-codesign
```

客户端参数示例：

```sh
flutter build apk --release --target-platform android-arm64 --dart-define-from-file=config/production.local.json
```

最终验收使用当前代码重新构建的 Release。iOS 未签名构建不能直接安装到 iPhone。Profile/Debug 只用于明确标注的调试范围，不与 Release 结论混用。

只开发 A 面可使用 `flutter run --target=tool/a_preview.dart`，不用于正常提审。`ENABLE_IM` 已不生效；正常 main.dart 始终运行接口决策。

本 SDK 的首次 `flutter run` 可能无法从仅含 activity-alias 的源 Manifest 识别启动入口。先执行 `flutter build apk --debug --target-platform android-arm64`，再 Android Studio Run；flutter clean 删除 APK 后需重新预构建。这是当前 SDK 的解析兼容方式，未改全局 Flutter SDK、未将原生 launcher 改回 Flutter。已安装 Release 与 Debug 签名不同仍不能覆盖；不得擅自卸载或清数据。

## 隔离原生验收

`ORG_GRADLE_PROJECT_shellReview=true` 仅供独立的 `.startupcheck` Release 原生验收；正常包不带该后缀、不包含 instrumentation。独立测试 APK 才包含反射断言。`shell-acceptance-rules.pro` 只在隔离变体保留原生类名，不能将其测量直接等同正常包性能。

证据见 `docs/evidence/mock-startup-2026-11-11/`，测试包放 `build/acceptance/`。隔离包与正常包路径、包名及 SHA 必须分别记录，不能误交测试包。当前完整验收进展见 `项目交接.md`，旧 DataVerna 对齐报告和 A 面旧包记录仅作历史证据。

## 上架与交付

只保留 `googlplay/` 一套资料。英文协议正文品牌和 App 内远端入口已随名称更新；主体/邮箱已于 2026-11-14 替换为用户确认信息，Google Sites 未发布。旧宣传图可能仍含原候选名称，真实英文 Web 截图、最终披露和商店素材仍需复核，不能视为上架资料验收完成。本轮不推送 GitHub、不上传蒲公英、不发布 Google Sites。
