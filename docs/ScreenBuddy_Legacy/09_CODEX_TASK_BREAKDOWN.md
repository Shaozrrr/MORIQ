# 09｜Codex 开发任务拆分

原则：每个任务独立、能编译、能测试。先验证最危险的技术点，再铺 UI。

## Sprint 0｜技术可行性验证（先做）

### P0-01｜创建最小 macOS 原生工程

- 创建 SwiftUI macOS App，建议最低 macOS 14.0 起步（以 SDK 实际可用性为准）。
- 菜单栏常驻，无 Dock 主窗口。
- 先用占位图验证 NSStatusItem 点击和 Popover。
- 通过标准：App 能启动、菜单栏图标能显示/点击、退出时清理资源。

### P0-02｜验证 NSPanel 浮窗

- 创建一个底部居中的 NSPanel。
- 输入框可聚焦，Esc 隐藏，快捷键再次打开。
- 用 NSScreen.visibleFrame 避开 Dock。
- 通过标准：在单屏/双屏/全屏 Space 测试中位置正确；窗口不捕获自己。

### P0-03｜验证全局快捷键

- 封装 Carbon RegisterEventHotKey。
- 默认 ⌥ Space。
- 能注册、注销、冲突时报错。
- 通过标准：切换 Safari、Finder、Xcode 时均能唤出；App 退出后热键释放。

### P0-04｜验证 ScreenCaptureKit 主动截图

- 申请屏幕录制权限。
- 查询 shareable content。
- 匹配前台 App 窗口。
- 调用 SCScreenshotManager.captureImage。
- 通过标准：Safari、Finder、TextEdit、Excel/Numbers 至少各测一轮；失败场景可解释；不捕获 ScreenBuddy。

### P0-05｜验证 SIWC OAuth

- 按官方 Cookbook / `@siwc/local` DevKit 参考流程完成动态注册、PKCE、浏览器授权、token exchange、identity 验证、plan usage scope 检查。
- 确认授权只包含 identity 不代表可调用模型；必须检查 sharing / `chatgpt.tokens.use.direct`。
- 通过标准：授权成功、取消、过期、refresh、logout 都能处理；Token 只在本地。

### P0-06｜验证 Codex App Server

- 启动 `codex app-server --listen stdio://`。
- 配置 `openai_chatgpt_plan` Responses provider，并将 access token 通过 `ACCESS_TOKEN` 环境变量传入。
- 完成 initialize → initialized → thread/start → turn/start。
- 接收 `item/agentMessage/delta` 和 `turn/completed`。
- 通过标准：真实文本请求完成；模型权限失败、额度耗尽、token 过期可区分。

### P0-07｜验证截图作为模型输入

- 把临时 PNG 路径作为 `{type:"localImage", path:"..."}` 输入。
- 同时传一段文字问题。
- 通过标准：模型能理解截图并回答；文件请求后清理；不把截图写日志。

**P0 总门槛：** 以上 7 项中 SIWC 商业授权状态必须标记为“待确认”，技术成功不等于商业许可成功。若 P0-05/P0-06 失败，先修接入，不得用私有 cookie/缓存绕过。

## Sprint 1｜主应用骨架

### P1-01｜模块化服务层

- 建立 ScreenCaptureService、CodexAppServerClient、SIWCAuthService、HotkeyManager、ContextEngine 等协议/实现。
- UI 只通过 ViewModel 调服务。
- 关键服务提供 Mock。

### P1-02｜顶栏 Popover

- 所有设置入口放顶栏。
- AI 连接、屏幕权限、快捷键、捕获模式、Live、排除应用、隐私、历史、关于。
- 不做独立大 Preferences 窗口。

### P1-03｜品牌素材接入

- 依据 `assets/brand_board_user_selected.png` 重建矢量 Logo。
- 输出 App Icon、Primary Lockup、Menu Bar black/white template image。
- 顶栏图标不带框。
- 不得擅自改造符号。

## Sprint 2｜主交互

### P2-01｜底部单一对话框

- 默认隐藏。
- 快捷键唤出。
- 单一圆角输入气泡。
- 输入/思考/回答状态。
- 长回答内部滚动。
- Esc 关闭并归还焦点。

### P2-02｜Siri-inspired 边缘流光

- 自绘 AngularGradient/Canvas 边缘动效。
- 思考时加速，回答时减速，隐藏时淡出。
- Reduce Motion 降级。

### P2-03｜连续对话

- 同一 Codex thread 追问。
- 支持停止生成、网络错误重试、额度耗尽提示。

## Sprint 3｜屏幕上下文

### P3-01｜主动窗口截图

- 触发前记录前台窗口。
- 支持窗口和显示器捕获。
- 失败时不自动换目标。

### P3-02｜区域框选

- 自绘透明 overlay。
- 框选、取消、裁切、坐标换算。

### P3-03｜OCR

- Vision RecognizeTextRequest。
- 中英识别、坐标、置信度。
- OCR 失败回退截图。

### P3-04｜上下文组装

- 当前快照优先。
- “上一页/刚才那个”引用最近相关快照。
- 时间戳、应用来源、截图引用。
- 过期或缺失时明确告知。

## Sprint 4｜持续感知（Pro 候选）

### P4-01｜系统捕获源选择

- 使用 SCContentSharingPicker.shared。
- 用户选择窗口或显示器。

### P4-02｜SCStream 生命周期

- start / pause / resume / stop。
- 目标关闭、权限撤销、锁屏、睡眠恢复。

### P4-03｜本地变化检测

- 下采样、帧差/perceptual hash、关键帧去重。
- 限制帧数和缓存时长。
- 默认不发起后台 AI 请求。

### P4-04｜顶栏 Live 状态

- 显示捕获目标。
- Pause / Stop / Clear Cache。
- 用户随时可关闭。

## Sprint 5｜本地历史与隐私

### P5-01｜SQLite 本地会话

- 保存文本、thread ID、必要元数据。
- 默认不长期保存截图。

### P5-02｜排除应用与隐私控制

- Bundle ID 排除列表。
- 清空缓存/历史。
- Token Keychain 管理。

## Sprint 6｜发行前准备

- macOS 签名、Notarization、更新机制。
- 权限引导文案。
- 崩溃诊断脱敏。
- SIWC 条款与商业收费书面确认。
- 真实 Mac 多屏/不同 Dock 位置/深浅色/不同 App 测试。

## Codex 每个任务必须输出

1. 修改了哪些文件。
2. 实现了什么。
3. 如何运行。
4. 构建命令和真实结果。
5. 测试命令和真实结果。
6. 已知限制。
7. 未验证的部分。

不得声称“已完成”但没有实际编译/测试。
