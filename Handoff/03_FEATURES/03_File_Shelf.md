# F03 悬浮文件暂存架

## 真实流程
选中文件并从 Finder 拖向屏幕右侧，接近边缘时出现窄蓝色提示条，继续靠近则黑色暂存架从侧面滑出；释放后文件以卡片形式暂存；侧边留下“2”文件计数；用户切到邮件时再从该条轻触展开并拖出文件；原文件位置保持不变。

## 实现
- OpenShelf `ShelfPanel.swift` 用 `NSPanel(.borderless,.nonactivatingPanel)`, `QLPreviewPanel` 实现浮动预览；`ShelfWindowController.swift` 实现贴边与滑出、动态尺寸与减少动态效果兼容。
- 创建 `ShelfModel` 保存 `FileReference(url/bookmark,displayName,UTType,addedAt)`, `ShelfWindowController` 负责边缘触发、屏幕位置、安全区域、窗口动画； `ShelfDropView(NSView)` 接受拖入的 file URLs，并以 `NSDraggingSource` 实现拖出。
- 沙盒下的 bookmark 必须采用经用户交互授权且可恢复的 security-scoped bookmark；读取时调用 startAccessing / stopAccessing 并正确释放。已删除文件显示失效卡片供用户处理，不可悄悄删除原文件。
- 缓存仅保存必要文件信息/缩略图；缩略图可 QuickLookThumbnailing 异步生成，避免同步读取数百兆文件。
- 左右边缘优先右侧，支持用户在设置高级选项调整；多屏幕按当前指针选位置。Full-screen Space、Dock 自动隐藏、刘海/菜单栏安全区域实测。

## 动效细则
进入边缘 8–14pt 感应区后提示条先亮蓝，约 100ms 进一步移动可展开；文件临近时卡片槽放大 1.04，松手轻微回弹，离开后延迟约 700ms 收起。用户点击手动打开的架子必须等指针进入过一次才允许自动收起，避免闪烁。

## 失败/验收
没有有效文件 URL 时不暂存；拖到目录/第三方 App 失败时文件依然留在架子；退出/重启恢复 URL；改名/删除显示更新；外接屏断开后浮窗回到主显示器。系统禁止取得文件数据时给明确授权路径。
