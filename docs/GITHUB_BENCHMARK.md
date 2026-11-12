# MORIQ 功能对照与验收

参考 GitHub 项目的公开代码和功能说明；本表记录待达到的具体行为，不宣称 MORIQ 已优于这些项目。外部代码和资产不得未经许可复制进产品。

还参考了 [Filee](https://github.com/KnifeLemon/Filee)、[Kumquat](https://github.com/TheAlexRay/kumquat) 的本地多格式架构。Office、视频与音频需要不同引擎；格式数量不等于每对格式都可以互转，必须按输入、引擎和输出逐项验收。

| MORIQ 功能 | 对照项目 | 基线与 MORIQ 的验收点 |
| --- | --- | --- |
| 转换圆盘 | [Swivel](https://github.com/jonathanlotan/Swivel)、[OpenShelf 拖拽监听](https://github.com/Manan-Santoki/OpenShelf/blob/main/Sources/OpenShelf/DragDetection/DragMonitor.swift) | Finder 原位拖放、低空闲负载、修饰键稳定识别、目标可用性与原件保护；多屏、失败和取消均需实测。 |
| 文件暂存架 | [OpenShelf](https://github.com/Manan-Santoki/OpenShelf)、[DragShelf](https://github.com/nanonigit/DragShelf) | 跨应用拖入拖出、保留原件、重启恢复、丢失文件提示和边缘动效；需要跨 App 与多屏验收。 |
| 剪贴板 | [Maccy 剪贴板实现](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift) | 文本、图片、富文本、多文件，敏感类型过滤、搜索与键盘操作；本地加密历史的密钥不可用及数据恢复需要验收。 |
| 超级截图 | [Pinlume](https://github.com/pinlume/pinlume)、[shotty](https://github.com/uuu4/shotty)、[ScreenLingo](https://github.com/xaelkaz/ScreenLingo) | 截图后原位标注、复制、OCR 和翻译；像素坐标、透明度、多屏、语言包及实际粘贴需要验收。 |
| AI 助手 | [CoreContext](https://github.com/prtk1910/CoreContext)、[Wisp](https://github.com/ycl-2004/Wisp) | 用户主动唤出、上下文可预览、发送前明确确认；所选模型不支持图片时不假称能直接理解图像。 |

比较结果需要在同一设备、相同输入和可复现用例下测试速度、流畅度、成功率和功能覆盖后才能下结论。
