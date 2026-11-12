# MORIQ — macOS V1 完整开发交接包

**先看这里：本交付包是正式产品规格、品牌资产和可播放的动画原型，不是已编译的 macOS App。**

MORIQ 原名 ScreenBuddy。正式面向用户的 App、设置界面、菜单栏和品牌动画，全部使用 **MORIQ**；“ScreenBuddy”仅作为历史项目名称。功能保留五项：万能转换圆盘、AI 助手、文件暂存架、智能剪贴板、超级截图（含 OCR/翻译/标注/贴图/问 AI）。

## 建议阅读顺序
1. `01_PRODUCT/01_Product_Requirements.md`：为什么做、谁用、边界、完整功能验收。
2. `02_DESIGN/01_UI_Design_System.md`、`02_DESIGN/02_Motion_and_Animation.md`：界面所有细节、演示窗口、动效。
3. `03_FEATURES/01_Converter.md` 到 `05_Screenshot_Translation.md`：五个功能逐秒用户流程、状态、系统能力、错误兜底。
4. `04_ENGINEERING/01_Architecture_and_Permissions.md`、`02_Data_and_Security.md`：工程结构、系统 API、权限/隐私/多显示器。
5. `05_DELIVERY/01_Implementation_Plan.md`、`02_Acceptance_Tests.md`：按里程碑落地和测试。
6. `06_BRAND/`：已经确认的品牌视觉与可用导出资产，以及两段动画（含上一版参考和更新后的高帧率实现）。

## 必须尊重的决定
- **原生 macOS**：SwiftUI 设置界面；AppKit 浮窗、快捷键、事件监听；不能做浏览器网站或 Electron 套壳。
- **主窗口只放五行功能**：功能图标、名称、一行说明、演示按钮、真实开关。不要上传入口、仪表盘、固定动画区、聊天主页。
- **每个演示独立弹出**：大面积桌面动效；画面右上角仅一个“↻ 重新播放”，弹窗标题栏有关闭按钮；底部无文案、无控制条。
- **所有真实操作都在 Finder、桌面或当前 App 的上层发生**，设置窗口不是处理中心。
- **AI 唤醒快捷键 `⌘ ⇧ Space`**，BYOK，API Key 存 Keychain，截图主动选择后才传输。
- **品牌**：MORIQ，黑 `#000000`、白 `#FFFFFF`、蓝 `#2563FF`，仅允许中性灰辅助。
- **不要拿演示动画充当实现**。系统功能必须可实际操作和验证。

## 资产说明
`Original_Approved` 是用户已认可视觉的原始光栅稿；不能声称已经拥有原始 SVG 路径。`Exported_Assets` 是从原始稿清白底后导出的透明 PNG，边缘需要设计师进行像素审核，特别是 16pt 菜单栏尺寸。`Animation/MORIQ_Brand_Reveal_30fps.mp4` 是程序化制作的更平顺可播放动画，品牌图形来自上述已认可光栅稿，不是原始矢量母版。`Previous_Approved_Concept.gif` 保留用户上一轮认可的创意过程作为参照。

## 交给 Codex 的第一条任务
读取整个 00–05 文档。先建立可在 Mac 上编译的 Xcode 原生工程，只做五项开关和独立弹窗演示及菜单栏；提交构建证据后逐项实现真实功能。不要一次性生成几千行未经编译的代码。每一里程碑必须提供可操作演示、错误日志和验收结果。

## 许可证提醒
参考 GitHub 项目不是授权直接拷贝代码。逐仓库核对 LICENSE、版本、依赖许可证、商用分发限制；参考设计机制可以，但直接复用代码需要满足所有授权义务。
