# Yueh 对照 DataVerna 的启动与原生接入复审

日期：2026-11-11。代码基准：DataVerna/hashcalc `1.0.14+18`，提交 `71e141c521128288cb915be59418bc1fcf799a5b`；未修改该基准工程。本报告审查指定接入链路，不宣称适用规范全项验收通过。

## 本次结论

B 面启动顺序、Activity 属性及原生承载链路已按基准对齐。A 面账本加载／失败不再是 B 面的前置条件。保留每款 App 的身份、A 面业务及用户要求的配置占位，不能因此认定真实推送或 IM 业务已通过。

## 实际调整及复核

| 项目 | 调整后／复核结论 |
| --- | --- |
| main.dart | 与基准逐字一致，仅 `HashCalcApp` 替换为 `YuehApp`；unawaited 推送初始化与方向设置、读取 cachedUrl、runApp(enableIm:true) 顺序一致 |
| ENABLE_IM | 已从主入口移除；传该 define 不再改变入口行为，配置示例也已移除该字段 |
| A 面独立性 | 根 home 直接创建 AbHost；A 面仅通过 toolBuilder 显示账本加载、失败或业务页面。慢／坏数据库不阻断 B 面决策与缓存 B 页 |
| FlutterHostActivity | exported=true、singleTask、taskAffinity、主题、configChanges、adjustResize、硬件加速等属性与基准一致 |
| ImActivity | exported=false、singleTask、同一 taskAffinity、ImSplashTheme、configChanges、portrait、adjustResize 等属性一致 |
| 桌面启动别名 | MainActivity → ImActivity，exported=true，MAIN／LAUNCHER，与基准一致 |
| Activity 恢复 | onNewIntent 调 super 并更新 intent；B 激活后 REORDER_TO_FRONT + NEW_TASK 打开 ImActivity，ACTION_SEND 时关闭多余宿主，B 面行为与基准一致 |
| 原生 B 核心 | ImActivity、ImWebViewHolder、ShellApplication、ShellBridge、ShellMemoryPolicy、ShellNotificationExtension，归一化包名、通道与英文翻译后与基准一致 |
| Flutter Android 分支 | 不嵌入 PlatformView；Dart 占位，原生 Activity 挂载唯一 WebView；缓存 Flutter 引擎继续处理事件／看门狗／推送 |
| iOS | 通过未签名完整构建；当前仍沿用基准的 Flutter/WKWebView 接入，不把 Android 原生承载结论套用到 iOS |

## 保留且明确的差异

1. 本项目不具备哈希文件分享业务，因此不声明 DataVerna 的 ACTION_SEND 文件导入 IntentFilter，也不复制 SharedFileImports／ImportCopy／AbHost.toolRequested。这是 A 面业务适配，不能说整个 Manifest 每一行完全相同；两类 Activity 和启动 alias 的全部 XML 属性已逐项一致。
2. 独立包名、桥接通道、品牌和英文提示继续保留；A 面全局主题和私有账本、关闭系统备份的 Application 配置继续保留。
3. 配置接口仍为 example.invalid，渠道和 OneSignal App ID／平台配置待提供。不沿用 DataVerna 的正式接口或身份。
4. A 面单独开发体验移到 `tool/a_preview.dart`，不改变正常 main.dart，也不在正常 A 面添加内部入口。此开发入口未作为本轮 B 面回归包构建；旧 ENABLE_IM=false 说明已更正。

## 验证范围

- Flutter analyze：无问题。
- Flutter test：59 项通过／项目，含原有 10 项记账与主题测试、47 项从基准适配的 B 面逻辑测试，以及新增的 2 项启动隔离测试。
- 新增测试分别覆盖：A 面数据库一直未完成时已发起远端决策；A 面数据库失败时缓存 B 页面仍保持选中，A 面错误不替换 B 页面。
- SDK 绑定／恢复测试使用 MethodChannel mock；仅测试命令传入虚拟客户端 ID，正常 APK 构建没有传入这些测试 ID，不等于真实送达通过。
- Android：当前源码重新构建 Release，1.0.1+2，arm64。
- APK SHA-256：`f2f78c0477d44ba205abafeb0ef92a08f8c0695f074968de562395624bfeab49`；证书 SHA-256：`35641a7ccb7fdbbc711e1a07cfe3c3e730533d4214866592b6ad8974861d255b`，私钥未输出。
- 手机：PFTM20，桌面冷启动后回桌面再进入两次，验证宿主始终只有一个、安装包摘要与当前 APK 相同；最终执行结果以同目录 `device-startup.json` 为准。
- Yuehui 原有 Debug 签名不能覆盖；已按用户明确授权卸载旧 Yuehui 再装 Release，清除范围仅为该旧 App 的本地数据。
- iOS：通过未签名完整构建，未签名、未进行 iPhone 真机与推送验收。

证据目录：`docs/evidence/dataverna-alignment-2026-11-11/`。原 1.0.0+1 的记录保留在旧证据目录，不能混用摘要。

## 仍未通过或未测

真实 B 面登录后业务、真实推送、性能阈值、iPhone 实机及 Google Sites 等仍未验收。接口与平台配置为空时，本轮手机运行验证的是正常入口／任务栈及占位配置回 A，不是 WebView 在线业务验收。不能把本次接入一致性复核当成整包上线批准。
