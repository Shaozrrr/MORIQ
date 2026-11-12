# F02 MORIQ AI 助手 — 触发、隐私、体验和工程

## 用户实际体验
在 Safari、IDE 或 PDF 上按 `⌘ ⇧ Space` → 底部中央出现黑色 MORIQ 胶囊 → 可直接输入问题 → 胶囊自然展开 → 流式回复。用户点击“读取当前屏幕”“框选区域”“选中文本”其中一个后，先看到要加入的内容预览和发送范围，再调用自己的 API Key。连续提问沿用当前会话。Esc 收起；再次快捷键唤醒并恢复上次会话（如果用户选择保留）。

## UI 状态
`hidden → compact → expanded → attaching-context → ready → responding → idle`；失败进入 `error`，显示重试；新会话、复制回答、清除对话放在次级菜单。尺寸参考设计规范，展开的聊天高度受当前屏幕安全区域限制，不覆盖 Mac Dock。

## 系统实现
- 参考 `jxmnhm/aski/Sources/Aski/Window/FloatingPanel.swift`：`NSPanel(styleMask:.nonactivatingPanel)`、`.canJoinAllSpaces`/`.fullScreenAuxiliary`，仅需要输入时成为 key，避免无端抢原应用焦点。SwiftUI 内容可由 `NSHostingView` 承载。
- 全局热键优先系统支持的注册机制（Carbon `RegisterEventHotKey` 可按目标版本核验）；快捷键冲突时不强行抢系统组合。AppKit 使用 `NSWorkspace.shared.frontmostApplication` 保存原应用并在关闭后恢复其焦点。
- 对“当前屏幕”使用 ScreenCaptureKit，截屏授权与 API 发送授权分别管理；截图前显示实际发送内容；对选区使用 Vision OCR 或图像作为模型输入。
- 持续感知不是后台全天录屏：用户显式开启后，限定窗口使用期间按合理间隔主动抓取，并有持续可见蓝色状态 + 停止入口；在锁屏、睡眠、窗口关闭、关闭功能、退出程序时立即停。网络请求按上下文变更/用户确认触发，不自动每帧调用模型。

## BYOK 与模型适配
- 使用系统 Keychain (`SecItemAdd/CopyMatching/Update/Delete`) 保存 API Key；提供人话教程，例如如何取得 Key、如何检查余额、Key 是否发送给第三方。
- 模型适配器接口 `ModelProvider` 支持 `validateConfiguration`, `stream(messages,attachments)`, `cancel`, `capabilities`；能力不支持图像时禁用屏幕上下文选项。
- 支持 429、超时、权限拒绝、网络错误、输入过长、图像太大、密钥错误的具体说明。
- 不可把用户的聊天记录或模型密钥写入遥测和明文日志；可选本地加密保存历史，支持“一键清除”。

## 源码与现有代码审查
`https://github.com/jxmnhm/aski`：已经检查 `FloatingPanel.swift` 的 NSPanel 行为与 `KeychainStore.swift` 的 Security 框架调用。具体项目实现不能无条件复制；选中的代码要根据 MORIQ 的 Bundle ID 和沙盒重新实现。

## 验收
- 在 Xcode、Safari、全屏视频、双显示器上快捷键唤醒；不意外激活设置窗口；输入焦点正常；Esc 和重开状态正常。
- 未连接 API Key 时说明如何配置，不假装回答；未授权屏幕访问时普通纯文本对话仍可用。
- 关闭持续感知后 0 后续截图任务；模型发送必须有显式授权路径；流式输出期间可以停止。
