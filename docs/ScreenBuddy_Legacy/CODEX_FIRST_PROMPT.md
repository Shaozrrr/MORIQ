# 可直接复制给 Codex 的第一条开发指令

请先完整阅读仓库根目录 `AGENTS.md`，以及 `01_DECISIONS.md`、`05_TECH_ARCHITECTURE.md`、`06_IMPLEMENTATION_GUIDE.md`、`08_BUSINESS_AND_POLICY.md`、`09_CODEX_TASK_BREAKDOWN.md`、`11_RISKS_AND_OPEN_ITEMS.md`。

你现在不是直接开发完整 ScreenBuddy，而是先完成 Sprint 0 的技术验证。不要跳过验证，不要擅自扩大范围。

## 第一阶段只做这些事

1. 初始化原生 macOS SwiftUI + AppKit 工程。
2. 创建菜单栏 NSStatusItem，点击后打开简单 Popover。
3. 创建 NSPanel 浮窗，初始隐藏；用测试按钮模拟唤出；浮窗底部居中、圆角、只有一个输入框。
4. 实现默认全局快捷键 `⌥ Space`，并能释放注册。
5. 在唤出前记录前台应用 PID，证明不会误把 ScreenBuddy 自己当作目标窗口。
6. 建立 ScreenCaptureService 协议和 Mock；真实 ScreenCaptureKit 捕获作为独立 P0 spike。
7. 建立 CodexAppServerClient 的 JSONL 子进程通信 spike：initialize、initialized、thread/start、turn/start、delta、turn/completed。
8. 建立 SIWCAuthService 的接口和官方流程验证计划；不要自行猜 OAuth endpoint，不要使用私有 cookie/session。
9. 把用户选定的品牌参考素材放进 Assets；不要重画或替换 Logo。

## 明确暂时不做

- 不做支付。
- 不做 Pro 付费墙。
- 不做 MCP Server。
- 不做自动操控电脑。
- 不做语音。
- 不做云端同步。
- 不做 Token 中转。
- 不做后台自动模型调用。

## 交付要求

完成后报告：
- Xcode / Swift / macOS SDK 版本。
- 工程目录。
- 已完成的 P0 项。
- 实际构建命令与结果。
- 实际测试命令与结果。
- SIWC + Codex App Server 是否跑通；若未跑通，准确写出卡点。
- 需要用户提供或确认的内容。

不要把“写了代码”当成“功能已验证”。
