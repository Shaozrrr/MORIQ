# 05｜macOS 原生技术架构

## 1. 技术选型

| 层 | 建议技术 | 说明 |
|---|---|---|
| App 生命周期 | SwiftUI App + AppKit AppDelegate | 原生 macOS 菜单栏应用 |
| 菜单栏 | `NSStatusItem` / `NSStatusBar` | 用 button image，设置 template image |
| 顶栏设置 | SwiftUI Popover / NSPopover | 所有设置统一入口 |
| 主浮窗 | `NSPanel` + `NSVisualEffectView` + SwiftUI hosting | 非主窗口、可聚焦、底部定位 |
| 全局快捷键 | Carbon `RegisterEventHotKey` 封装 | 不依赖轮询；冲突可检测 |
| 截图 | ScreenCaptureKit | `SCShareableContent`、`SCContentFilter`、`SCScreenshotManager` |
| 持续感知 | ScreenCaptureKit `SCStream` | 只捕获用户选定窗口/显示器 |
| 系统选择器 | `SCContentSharingPicker.shared` | Apple 推荐的捕获源选择器 |
| OCR | Vision `RecognizeTextRequest` | 本地文字识别 |
| 辅助功能文本 | ApplicationServices Accessibility API | 可选增强；不保证所有应用可读 |
| AI 接入 | SIWC OAuth + Codex App Server | OAuth 由 ScreenBuddy 管理，Token 只在本机 |
| 本地存储 | SQLite / GRDB | 对话文本、设置、上下文元数据 |
| 凭证 | Keychain | SIWC token / client registration / host id |
| 日志 | OSLog | 只记录状态和错误类别，不记录截图/Token/屏幕文字 |

最低系统版本建议先定为 macOS 14.0+ 作为开发基线，最终需通过实际 API availability 和目标用户设备测试再锁定。不要在没有验证的情况下声称支持所有 macOS 版本。

## 2. 推荐工程目录

```text
ScreenBuddy/
├── App/
│   ├── ScreenBuddyApp.swift
│   ├── AppDelegate.swift
│   ├── AppCoordinator.swift
│   └── DependencyContainer.swift
├── Features/
│   ├── MenuBar/
│   │   ├── MenuBarController.swift
│   │   ├── MenuBarPopover.swift
│   │   └── MenuBarViewModel.swift
│   ├── FloatingAssistant/
│   │   ├── AssistantPanelController.swift
│   │   ├── AssistantPanelView.swift
│   │   ├── AssistantInputView.swift
│   │   ├── AssistantAnswerView.swift
│   │   ├── SiriEdgeEffect.swift
│   │   └── AssistantState.swift
│   ├── Onboarding/
│   ├── History/
│   └── Settings/
├── Services/
│   ├── HotkeyManager.swift
│   ├── ActiveApplicationTracker.swift
│   ├── ScreenCaptureService.swift
│   ├── RegionCaptureService.swift
│   ├── ContinuousCaptureService.swift
│   ├── ScreenChangeDetector.swift
│   ├── OCRService.swift
│   ├── AccessibilityReader.swift
│   ├── ContextEngine.swift
│   ├── PrivacyGuard.swift
│   ├── SIWCAuthService.swift
│   ├── CodexAppServerClient.swift
│   └── PermissionManager.swift
├── Models/
│   ├── ScreenContext.swift
│   ├── CaptureTarget.swift
│   ├── Conversation.swift
│   ├── ChatMessage.swift
│   └── UserSettings.swift
├── Storage/
│   ├── Database.swift
│   ├── Repositories/
│   └── KeychainStore.swift
├── Resources/
│   ├── Assets.xcassets/
│   ├── en.lproj/
│   └── zh-Hans.lproj/
└── Tests/
    ├── UnitTests/
    ├── IntegrationTests/
    └── UITests/
```

## 3. 关键模块职责

### AppCoordinator

- 创建并持有菜单栏状态项。
- 注册快捷键。
- 管理浮窗显示/隐藏。
- 记录唤出前的前台应用上下文。
- 负责应用退出时停止所有捕获流和子进程。

### AssistantPanelController

- 使用 `NSPanel` 管理底部浮窗。
- 允许键盘焦点进入输入框。
- 处理多显示器、Dock、全屏 Space、刘海屏。
- 管理 show/hide/expand 动画。
- 不负责截图或 AI 请求。

### ScreenCaptureService

- 负责主动截图。
- 查询可捕获内容并匹配目标窗口。
- 捕获失败时返回可解释错误，不得静默换窗口。
- 截图临时文件写入应用专用临时目录，使用后清理。

### ContinuousCaptureService

- 管理 `SCStream` 生命周期。
- 目标由用户通过系统 picker 选择。
- 暂停/恢复/停止明确可控。
- 将帧交给本地变化检测，不直接请求 AI。

### ContextEngine

- 管理当前快照、最近关键帧、OCR 文本、时间戳、应用信息。
- 根据用户问题选择最相关上下文。
- 对“刚才那个”“上一页”等指代使用有时间戳的上下文。
- 上下文缺失时明确说明，不能编造历史。

### SIWCAuthService

- 管理官方 Sign in with ChatGPT OAuth 流程。
- 为每个安装实例生成稳定 host ID。
- 管理 client registration、PKCE、callback、token exchange、refresh、logout。
- 只请求需要的 identity + ChatGPT plan usage scope。
- Token 存 Keychain，不上传 ScreenBuddy 服务器，不写日志。

### CodexAppServerClient

- 启动本地 `codex app-server --listen stdio://` 子进程。
- 将 OAuth access token 通过环境变量 `ACCESS_TOKEN` 传入进程，不放在命令行参数或日志中。
- 按官方 SIWC Codex app-server 文档配置 Responses provider。
- 通过 stdin/stdout 发送 JSONL JSON-RPC。
- 初始化连接后 start/resume thread，发起 turn，解析 delta 和完成事件。
- 维护线程 ID，支持取消和恢复。

## 4. 数据流

```text
Global Hotkey
   ↓
AppCoordinator 记录原前台 App / Window
   ↓
AssistantPanelController 显示底部圆角浮窗
   ↓ 用户输入问题
ScreenCaptureService 捕获允许的目标窗口
   ↓
ContextEngine 组织当前快照 + 必要历史 + OCR
   ↓
CodexAppServerClient 发送 text + localImage
   ↓
Codex App Server（本机进程）
   ↓
item/agentMessage/delta 流式事件
   ↓
AssistantAnswerView 渐进显示
```

## 5. Codex App Server 通信

- 默认 stdio transport，JSONL，一行一条 JSON-RPC 消息。
- 建立连接后先 `initialize`，成功后发送 `initialized`。
- 新对话 `thread/start`，继续对话 `thread/resume`。
- 发起请求 `turn/start`。
- 用户输入可包含：`{ "type": "text", "text": "..." }` 与 `{ "type": "localImage", "path": "/.../capture.png" }`。
- 读取 `item/agentMessage/delta` 增量文本。
- 收到 `turn/completed` 后检查 `turn.status`；只有 completed 才视为成功。
- 额度/授权失效时按官方错误流程重新登录或显示用量提示。
- 不使用实验性 WebSocket 作为第一版主通道；优先 stdio。

## 6. 运行方式

建议第一阶段先检测用户是否安装了官方 Codex CLI，并确认 `codex app-server` 能启动。若没有，显示官方安装教程。是否把 Codex CLI/App Server 二进制随 ScreenBuddy 打包，需先核对分发许可、更新策略和体积，不能默认直接复制打包。
