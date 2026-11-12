# 06｜关键功能具体实现路径

这份文件给 Codex 说明“到底怎么做”，不是只列技术名词。

## 1. 菜单栏常驻和设置

1. App 启动时用 `NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)` 创建状态项。
2. 设置 `statusItem.button?.image` 为单色模板图；不要使用已废弃的 `statusItem.image`。
3. 设置 `button.image?.isTemplate = true`，由 macOS 根据浅色/深色菜单栏自动适配。
4. 点击按钮打开 `NSPopover` 或 SwiftUI Popover。
5. Popover 分组显示 AI 连接、权限、快捷键、捕获模式、Live、排除应用、隐私和历史。
6. 不创建额外的主设置窗口；复杂子项可在同一个 Popover 内切换子页。

## 2. 全局快捷键

1. 用 Carbon `RegisterEventHotKey` 注册默认 `⌥ Space`。
2. 快捷键配置保存本地。
3. 注册失败时显示冲突提示，不要静默换快捷键。
4. 支持用户重新录入组合键。
5. 热键触发时先记录 `NSWorkspace.shared.frontmostApplication` 的 PID、应用名和时间戳，再显示 ScreenBuddy。
6. 不能先显示浮窗再查询前台 App，否则会把 ScreenBuddy 自己当作捕获目标。

## 3. 浮窗实现

1. 使用 `NSPanel`，通过 SwiftUI `NSHostingView` 承载内容。
2. 用 `NSVisualEffectView` 或 SwiftUI material 实现半透明底材。
3. 面板需要可获得键盘焦点；实现合适的 `canBecomeKey` / `canBecomeMain` 行为。
4. 面板位置按当前鼠标所在屏幕或前台窗口所在屏幕决定；优先使用当前活动显示器。
5. 使用 `NSScreen.visibleFrame` 计算底部位置，避开菜单栏与 Dock。
6. 目标尺寸：输入态约 290×44 pt；回答态宽 340–420 pt，高度最大为可用屏幕 55–65%。
7. 内容区使用独立 ScrollView，输入区固定；不要用一个外层固定高度把回答裁掉。
8. Esc 关闭并归还焦点；按快捷键再次唤出。

## 4. Siri 风格边缘动效

1. 用 SwiftUI `AngularGradient` 沿 `RoundedRectangle` 的 stroke 绘制流动彩色边缘。
2. 通过可动画角度或 `TimelineView` 推进渐变起点。
3. 外围再叠一层低透明度 blur，产生柔和的光晕。
4. Input 态慢速；Thinking 态加快；Answer 态降低亮度并减速；Hidden 态移除所有效果。
5. 不要把光效做成粗厚的彩色霓虹边框。
6. Reduce Motion 时切换为静态低对比渐变。

## 5. 主动截图

### 5.1 获取目标窗口

- 触发快捷键时记录前台 App PID。
- 通过 `SCShareableContent` 查询可分享窗口。
- 将窗口 owner PID 与前台 PID 匹配，并结合 `CGWindowListCopyWindowInfo` 的 window number / bounds 辅助匹配。
- 过滤 ScreenBuddy 自身窗口、桌面背景、不可见窗口。
- 如果同一应用有多个窗口，优先选择触发时的 key/front window；无法可靠判断时让用户从候选窗口中选，不要猜。

### 5.2 捕获图像

- 用 `SCContentFilter` 指定目标窗口或显示器。
- 用 `SCScreenshotManager.captureImage` 捕获单帧。
- 需要区域截图时：先捕获目标显示器，再按用户框选区域裁切；处理 Retina scale 和多显示器坐标转换。
- 截图写入受控临时目录，文件名使用随机 UUID；权限尽量收紧。
- 截图完成后，将图像作为 Codex `localImage` 输入。
- 请求完成后按保留策略删除临时文件；默认不写入长期历史。

### 5.3 失败处理

- 系统权限未授予：引导用户打开系统设置。
- 窗口受保护/DRM/安全输入：说明系统或目标 App 不允许捕获。
- 目标窗口已关闭：要求重新捕获。
- 不允许在失败时偷偷捕获整个显示器或其他应用。

## 6. 区域框选

1. 在当前显示器上显示透明覆盖层。
2. 用户拖拽创建矩形，Esc 取消。
3. 读取屏幕坐标并转换成捕获图像坐标。
4. 裁切前限制最小尺寸和边界，防止空图。
5. 预览可选；发送前可以让用户确认区域。
6. 多显示器情况下，区域只能在用户当前选择的显示器范围内；跨屏选区作为后续功能。

## 7. 持续感知

1. 用户从顶栏菜单主动开启 Live。
2. 调用 `SCContentSharingPicker.shared` 让用户选择窗口/显示器。
3. 根据选定目标创建 `SCContentFilter`。
4. 创建 `SCStream`，配置帧率、分辨率和输出队列。
5. 初始建议每 1–2 秒本地检查一次画面；这只是产品默认值，需实测 CPU、电量和变化检测质量。
6. 本地计算 perceptual hash / downsampled frame diff，忽略重复帧；滚动、动画场景需限频。
7. 关键帧只保留最近 N 帧（初始 8–12 帧）和最近几分钟的 OCR 摘要；全部在本机。
8. 用户提问时，从缓存选择与问题相关的帧/文字发送给模型。
9. 默认不在后台自动调用模型。任何自动摘要、自动提醒、定时 AI 分析都要另行征得用户明确同意，并检查 SIWC 条款。
10. 用户停止 Live、退出应用、目标关闭、权限撤销、锁屏或系统睡眠时，正确停止/暂停 stream 并清缓存。

## 8. OCR 与 Accessibility

- OCR 使用 Vision `RecognizeTextRequest`，本地处理 `CGImage` 或 `CMSampleBuffer`。
- 中英混合优先；按系统版本设置支持的识别语言。
- OCR 输出保存 bounding box、文字、置信度和时间戳。
- Accessibility 作为增强，不作为基础截图问答的前提。使用 AXUIElement 读取目标 App 暴露的可访问树；如果目标 App 不暴露或返回错误，回退 OCR + 截图。
- 不承诺能读取所有 App 的所有内容，也不能保证隐藏单元格、未渲染页面或滚动区域以外的数据。

## 9. SIWC OAuth + Codex App Server

### 9.1 官方支持路径

OpenAI 官方 cookbook 给出本地/开源应用使用 Sign in with ChatGPT 的流程，并提供 Codex App Server 专门配置。流程包括：
1. 为每个安装实例生成稳定 `ext_agent_host_id`。
2. 在浏览器中打开官方 SIWC 授权，用户选择账号/工作区并同意 ChatGPT plan usage scope。
3. 通过 PKCE 回调取得 authorization code 和 client_id。
4. 交换 token，并验证返回的 ID token 签名、issuer、audience、nonce。
5. 将 client registration 和 token 本地保存；持久凭证放 Keychain。
6. 只有在授权包含 `chatgpt.tokens.use.direct` 时，才允许用 ChatGPT plan 发请求；仅仅登录成功不代表已授权模型用量。

建议 P0 先使用官方 `@siwc/local` / SIWC DevKit 参考实现验证流程，再决定 Swift 原生实现还是打包一个签名的本地 helper。不要自己猜 OAuth endpoint 或参数。

### 9.2 启动 Codex App Server

- 先检查 `codex app-server` 是否可运行。
- 启动时使用 stdio JSONL：`codex app-server --listen stdio://`。
- 按官方 SIWC Codex app-server 页面设置 provider：
  - `model_provider="openai_chatgpt_plan"`
  - `base_url="https://api.openai.com/v1"`
  - `env_key="ACCESS_TOKEN"`
  - `wire_api="responses"`
  - `requires_openai_auth=false`
  - `supports_websockets=false`
- 把 OAuth access token 放入子进程环境变量 `ACCESS_TOKEN`；不要把 token 放在命令行参数、日志或崩溃报告中。
- `initialize` 时 `clientInfo.name` 使用稳定应用标识，例如 `screenbuddy`；`title` 用 `ScreenBuddy`；version 用真实 App 版本。
- 初始化成功后发送 `initialized`。
- `thread/start` 建立会话；`turn/start` 发起请求。
- 输入中可包含文本和 `localImage`。
- 展示 `item/agentMessage/delta` 流式文本。
- `turn/completed` 时必须检查状态，只接受 `completed` 为成功。
- Token 过期时按 SIWC refresh flow 获取新 token，重启 app-server 并 `thread/resume` 恢复会话。

### 9.3 账户和模型

- 用官方 `model/list` 作为模型目录，但它不是权限证明。
- 必须通过一次真实完成的推理请求确认该用户当前能使用该模型。
- 显示用户正在使用自己的 ChatGPT plan；提供打开 ChatGPT Usage 的入口。
- 用户达到额度/速率限制时，清楚提示，不要重试风暴。

## 10. 数据库建议

最小表结构：

- `conversations(id, codex_thread_id, created_at, updated_at, title)`
- `messages(id, conversation_id, role, text, created_at, status)`
- `screen_contexts(id, conversation_id, app_bundle_id, window_title, captured_at, mode, ocr_text, local_image_path, expires_at)`
- `settings(key, value)`

默认不把原始截图写入长期历史。若用户显式开启截图历史，必须在 UI 中说明保留时间和清除方式。
