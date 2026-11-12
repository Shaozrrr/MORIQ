# F01 万能转换圆盘 — 操作、能力、实现、异常

## 真实用户流程
用户在 Finder 抓取 `IMG_0001.heic` 并拖动；按 `⇧ Shift`（可配置）后无需放开鼠标，圆盘出现在当前指针附近；只显示对 HEIC 有意义的 PNG、JPG、TIFF、PDF 等可用选项；高亮随拖动变化；松开后如果已选择有效格式，启动后台转换并关闭圆盘；完成后在同目录生成 `IMG_0001.png`；原文件不变。可以在任务完成后以系统通知提示结果（通知仅在用户同意时），失败时弹轻量提示并允许“打开错误详情”。

## 实现代码路线
- 研究 `OpenShelf/Sources/OpenShelf/DragDetection/DragMonitor.swift`：全局 `.leftMouseDown`/`.leftMouseDragged`、`NSEvent.pressedMouseButtons`、`NSPasteboard(name:.drag)` 的 `changeCount` 与 `.fileURL`。开始拖动后以约 16ms 关注状态，空闲只低频兜底；系统键盘 modifier flags 需做约 70ms 消抖。
- 参考 `Swivel` 思路；与 AppKit 全局浮动 `NSPanel` 解耦：`DragMonitor` 只产出 `DragSession(fileURLs,pointer,modifiers)`；`WheelCoordinator` 定位与渲染；`ConversionCoordinator` 执行任务。
- 使用 `NSScreen.screens` 找指针所在屏幕；按 `visibleFrame` 限制轮盘不得越界。Float panel 不抢焦点；不要把全局拖动事件解释成所有内容都能读。保留 Esc 取消、鼠标释放、窗口离焦与多选文件场景。
- `NSImage`, ImageIO、Core Image、PDFKit、AVFoundation、FFmpeg（仅在引入及授权/分发核查后）等按格式建立 `ConverterPlugin`，每个插件实现 `canConvert(sourceUTType,targetUTType)`, `convert(input,tempOutput,options,progress)`。
- 不可支持的目标从扇区里直接隐藏，不允许演示支持但真实版本只能报错。

## 源格式与目标格式
首批只承诺在测试矩阵通过后开启：HEIC/PNG/JPG/TIFF 相互转换，图像输出 PDF；WebP 必须实际验证 ImageIO/外部解码器可用后开启。音视频作为扩展插件，真实验证 FFmpeg 分发与许可后开放。PDF 合并/拆分需使用 PDFKit 独立动作，而非伪装为同类格式互转。批处理按每文件报结果。

## 输出与安全
- 先生成临时文件，并验证能打开/可读取，再原子写入用户选定目录；默认原目录，不覆盖现有文件，命名 `名字 (2).png`。
- 权限不够时不要偷偷复制到其他地方；提示用户选输出目录或授权。
- 图片元数据 EXIF、色彩配置/透明度、照片方向需分别验证；丢失 Alpha 或画质降低前给出说明或参数。
- 目录批量/嵌套拖拽默认不给潜在破坏性操作；ZIP 解压防止 `../` 路径穿越、软链接逃逸、压缩炸弹、覆盖已存在文件；ZIP 制作需可选排除隐藏文件。

## 测试用例
- Finder/桌面/外接屏/全屏/Retina/Stage Manager、Ctrl+Shift 冲突、拖动中按下/松开 Shift、Esc、触控板拖移、多个文件、同名输出、多次快速触发。
- 文件类型不支持、无权限、磁盘空间不足、损坏的 HEIC、转换中手动删除输入、应用退出中途任务取消。
- “关闭轮盘”要解除事件监听；空闲长期运行需无明显 CPU 占用。不得保证无需权限适用于每个来源 App，需真机验证。

## UI/动效
圆盘由中心文件缩略图 + 6–8 个最多可见选项组成；当前扇区亮蓝、其他黑色；中心类型文字短且清晰；当前文件不可输出到自身同格式且无其他操作时要禁用或转入压缩/编辑子轮盘。动效 300ms 内完成，不能发生松手后 500ms 才识别选择的问题。
