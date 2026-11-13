# MORIQ 功能对照与验收

参考 GitHub 项目的公开代码和功能说明；本表记录待达到的具体行为，不宣称 MORIQ 已优于这些项目。外部代码和资产不得未经许可复制进产品。

还参考了 [Filee](https://github.com/KnifeLemon/Filee)、[Kumquat](https://github.com/TheAlexRay/kumquat) 的本地多格式架构。Office、视频与音频需要不同引擎；格式数量不等于每对格式都可以互转，必须按输入、引擎和输出逐项验收。

| MORIQ 功能 | 对照项目 | 基线与 MORIQ 的验收点 |
| --- | --- | --- |
| 转换圆盘 | [Swivel](https://github.com/jonathanlotan/Swivel)、[OpenShelf 拖拽监听](https://github.com/Manan-Santoki/OpenShelf/blob/main/Sources/OpenShelf/DragDetection/DragMonitor.swift) | Finder 原位拖放、低空闲负载、修饰键稳定识别、目标可用性与原件保护；多屏、失败和取消均需实测。 |
| 文件暂存架 | [OpenShelf](https://github.com/Manan-Santoki/OpenShelf)、[DragShelf](https://github.com/nanonigit/DragShelf) | 跨应用拖入拖出、保留原件、重启恢复、丢失文件提示和边缘动效；需要跨 App 与多屏验收。 |
| 剪贴板 | [Maccy 剪贴板实现](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift) | 文本、图片、富文本、多文件，敏感类型过滤、搜索与键盘操作；本地加密历史的密钥不可用及数据恢复需要验收。 |
| 超级截图 | [Pinlume](https://github.com/pinlume/pinlume)、[shotty](https://github.com/uuu4/shotty)、[ScreenLingo](https://github.com/xaelkaz/ScreenLingo) | 截图后原位标注、复制、OCR 和翻译；像素坐标、透明度、多屏、语言包及实际粘贴需要验收。 |
| AI 助手 | [CoreContext](https://github.com/prtk1910/CoreContext)、[Wisp](https://github.com/ycl-2004/Wisp) | 用户主动唤出，遵循用户选择的屏幕上下文方式；清晰说明数据处理，所选模型不支持图片时不假称能直接理解图像。 |
| 实时字幕 | [AirTranslate](https://github.com/himomohi/AirTranslate)、[live-translate](https://github.com/mtib/live-translate)、[Apple 实时字幕](https://support.apple.com/guide/mac-help/mchldd11f4fd/mac)、[Windows 实时字幕](https://support.microsoft.com/en-us/accessibility/windows/use-live-captions-to-better-understand-audio) | 系统声音与麦克风的选择和明确授权；显示原文与译文、原位修正、稳定滚动和历史。系统声音与麦克风同时使用、长时间及外部设备须另行验证，不能将本机小样本当成竞品对齐结论。 |
| 屏幕便签 | [my-stickies](https://github.com/shastraw-ai/my-stickies)、[Sticky Finger](https://github.com/mandouix/Sticky-Finger) | 编辑和持久化、关闭后恢复、可靠查找；MORIQ 按用户要求仅固定在桌面，不照搬竞品的窗口置顶方式。 |

比较结果需要在同一设备、相同输入和可复现用例下测试速度、流畅度、成功率和功能覆盖后才能下结论。
