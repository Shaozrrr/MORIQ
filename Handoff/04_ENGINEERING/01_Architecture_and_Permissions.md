# 工程架构、模块间通信、权限与真实 macOS 行为

## 目标版本与开发环境
macOS 15+，Apple Silicon 优先；Xcode 最新支持 macOS 15+ 的稳定版；Swift 6/并发检查由工程环境实际决定。主设置 SwiftUI，系统能力及全局窗体 AppKit，原生 Framework API；不要以 Swift Package 里的 WindowGroup 冒充完整 macOS 应用生命周期。Xcode 工程需要真实 Bundle Identifier、Info.plist、Entitlements、Assets.xcassets、菜单栏和可选 LSUIElement 策略。

## 模块职责
```
MORIQApp
 ├─ AppLifecycle/MenuBarCoordinator        启动/退出/登录项/菜单栏
 ├─ SettingsStore                         5 项开关、快捷键、偏好持久化
 ├─ PermissionCoordinator                截屏/辅助功能/文件/通知权限解释
 ├─ HotkeyCoordinator                    唯一注册点，冲突检测与取消
 ├─ FloatingWindowCoordinator            NSPanel、显示器、安全区、焦点
 ├─ DemoCoordinator                      纯展示动画状态机，无系统操作
 ├─ Conversion/
 │   ├─ DragMonitor                       Finder 拖动、修饰键监听
 │   ├─ WheelCoordinator                  圆盘生成、扇区命中、Esc
 │   └─ ConverterEngine                   类型识别、转换/临时文件/输出
 ├─ AI/
 │   ├─ AssistantPanel                    灵动胶囊 + 交互
 │   ├─ ContextPicker                     截屏/选区/文本预览与授权
 │   ├─ ModelProvider                     BYOK + 流式输出
 │   └─ KeychainStore                     机密凭证
 ├─ Shelf/
 │   ├─ EdgeMonitor                       拖动到屏幕边缘
 │   ├─ ShelfPanel                        展开、收起、拖出
 │   └─ FileReferenceStore                bookmarks / Quick Look
 ├─ Clipboard/
 │   ├─ PasteboardMonitor                 changeCount
 │   ├─ ClipboardStore                    搜索/收藏/清除
 │   └─ ClipboardPanel                    召唤与选中
 └─ Screenshot/
     ├─ CaptureService                    ScreenCaptureKit
     ├─ SelectionOverlay                  选区/窗口拾取
     ├─ OCREngine                         Vision
     ├─ TranslationEngine                 Translation / BYOK
     ├─ AnnotationEditor                  标注/马赛克
     └─ PinPanel                          置顶贴图
```

## 线程与生命周期
系统回调和 NSWindow 管理位于 `@MainActor`；文件转换、OCR、网络请求不阻塞主线程，使用结构化 Task 与 AsyncSequence，所有取消都要向下传递。全局状态开关的 `setEnabled(false)` 必须同步取消热键/监视器/计时器，再处理已显示的窗口。转换进行中点击“关闭”时应询问是否取消正在执行的任务或让它完成（首版推荐继续任务但停止新任务入口，并有可见进度/取消入口）。

## 统一浮动窗口
`FloatingWindowCoordinator` 为每次调用计算屏幕：首先选择包含当前指针/选区的 `NSScreen`；若当前屏幕不可用回退主屏；窗口不能越过 `visibleFrame`；处理空间切换、全屏辅助窗口、Dock 自动隐藏和刘海/菜单栏。与焦点相关的逻辑必须根据是否需要文本输入区别处理（圆盘不激活，AI 输入窗可暂时成为 key）。禁止反复 `NSApp.activate` 造成前台软件闪烁。

## 全局键位（需允许用户自定义）
- 转换圆盘：按住拖动中的 `⇧ Shift`。检测修饰键不等于可以全局捕获任意文件内容；需理解拖拽上下文。
- AI 助手：`⌘ ⇧ Space`。此组合在部分环境可能被占用，启动时检查是否注册成功。
- 剪贴板：`⌘ ⇧ V`，可能和第三方剪贴板软件冲突。
- 截图：`⌘ ⇧ X`，可能和应用已有快捷键冲突。
- 暂存架：拖到屏幕边缘，另可从操作圆盘加入。

## 权限真相
| 功能 | 可能涉及的系统权限/机制 | 未授权时必须怎么做 |
|---|---|---|
| 圆盘 | 通常事件监视 + 拖拽 pasteboard；沙盒文件访问依系统/来源不同 | 告诉用户为什么不能读/写，并提供选择输出目录 |
| AI | 屏幕录制权限用于截屏；网络与 Keychain | 纯文本模式照常可用，禁用屏幕附加 |
| 暂存架 | 拖拽 file URLs、security-scoped bookmarks | 允许暂存元数据/提示授权，不隐式复制/移动 |
| 剪贴板 | 读 NSPasteboard；自动模拟粘贴可能需辅助功能 | 未授权只将选中项放回剪贴板 |
| 超级截图 | 系统屏幕捕获权限、Vision/Translation | 解释屏幕授权，给系统设置路径 |

不可承诺“永久免费无权限”或“无需任何权限”适用于所有场景。屏幕捕获、辅助功能、文件访问所需条目和 macOS 版本行为必须在实机签名构建中检查；沙盒与 Mac App Store 分发能力可能不同，先决定目标发行渠道再确定 Entitlements。

## 数据模型与通知
标准结果 `OperationResult(id,operation,success,outputs,error,startedAt,finishedAt)`；统一显示可读错误；不在 UI 伪造进度百分比。各模块通过明确的服务接口交流，禁止剪贴板模块直接拿 AI 密钥或 AI 模块持续读取所有历史数据。
