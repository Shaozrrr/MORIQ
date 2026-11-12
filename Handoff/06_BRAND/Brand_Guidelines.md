# MORIQ 品牌与资源目录说明

## 品牌名
正式名称 **MORIQ**（全部大写）。不再出现 ScreenBuddy 品牌或旧屏幕形 Logo。寓意可解释为 MORE + IQ / More intelligent utility，但这不是经过商标审核的法律定义。品牌名可用性需要正式商标检索。

## Logo 守则
以 `Original_Approved/Brand_Reference_Board.png` 和四张单独原稿为视觉准绳。黑/白/蓝：`#000000`、`#FFFFFF`、`#2563FF`。Logo 有规律的旋转感，形状定稿后不能随意改曲线，更不能改成另外一种旋涡。单色菜单栏版需要随 macOS `isTemplate=true` 适配亮/暗菜单栏。

## 已包含的原始确认图
- `Brand_Reference_Board.png`：完整品牌展示板。
- `macOS_App_Icon_Approved.png`：带白色圆角图标的 Dock 应用版。
- `Menu_Bar_Monochrome_Approved.png`：黑色单色标记。
- `Horizontal_Logo_Approved.png`：图形 + MORIQ 横版。
- `Dark_Pill_Brand_Approved.png`：黑底白字 + 蓝色强调。

## 已包含的导出资源
- `Brand_Mark_Transparent.png`：从横版视觉提取的透明位图图形。
- `Wordmark_Transparent.png`：从横版视觉提取的透明文字图形。
- `Brand_Mark_16/18/22/32/64/128/256/512/1024.png`：方便前期 Demo 与测试。
- `MenuBar_Template_16/18/22/32/64/128/256.png`：单色位图缩放导出，发布前需要检查小尺寸边缘。

**重要**：上述导出来自生图原稿的白底提取，不等于精确 SVG。若开发时发现边缘锯齿、原图比例不一致，正确流程是设计师按认可母版重建矢量，然后从同一个矢量源导出 Dock iconset / menu bar / wordmark，并校验各尺寸，不能分别生成新 Logo。

## 动画
- `Animation/Previous_Approved_Concept.gif`：保留已经认可的分镜灵感。
- `Animation/MORIQ_Brand_Reveal_30fps.mp4`：同品牌图形进行连续帧旋转聚合 + 完整 MORIQ 字标显现。
- `Animation/MORIQ_Brand_Reveal.gif`：适合快速预览。
- `Animation/Final_Frame.png`：最终锁定画面。

真实 App 动效首选直接使用 Core Animation / SwiftUI 原生变换而非 GIF，保证 60/120Hz 显示器流畅；本包视频用于视觉对齐，不是运行时必须嵌入的播放器。
