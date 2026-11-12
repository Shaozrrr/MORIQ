# 04｜品牌与 Logo 交接

## 1. 唯一采用的品牌参考

采用用户在 2026-11-09 明确选择的附件：`assets/brand_board_user_selected.png`。

这张品牌板中的核心图形是：一块黑色倾斜屏幕/面板，右下方有一块错位的钴蓝面板；旁边是粗体无衬线 `ScreenBuddy` 字标。

不要再发散设计，不要自行替换成之前被否定的 S 丝带、交叠蝴蝶结、星星、轨道、叶片、四角框、Copilot 类图形。

## 2. 颜色

品牌图形和字标只使用两种品牌色：

- Black：`#000000`
- Cobalt Blue：`#2563FF`

品牌展示底色：白色 `#FFFFFF`。白色是画布/透明区域，不作为第三种品牌强调色。

不要使用浅蓝、灰色、粉色、紫色渐变、玻璃光效、阴影或额外装饰色来改造 Logo。

## 3. Logo 组合

- Primary lockup：图形在左，`ScreenBuddy` 字标在右。
- Primary symbol：只保留黑色面板 + 钴蓝面板。
- App icon：沿用用户品牌板中的图形构图；容器是否加圆角底板，按品牌板参考，不得把容器误用到顶栏。
- Menu bar icon：同一图形的纯黑/纯白单色适配版本，不加方框、不带字。
- Favicon：用纯图形，尺寸缩小后必要时简化小细节，但不能换成别的概念。

## 4. 菜单栏适配

- macOS Menu Bar 需要 template image。
- 浅色模式：黑色单色。
- 深色模式：白色单色。
- 不用蓝色填充、不用彩色渐变、不加方形背景。
- 保留主图形的两个面板关系，但在 18×18 pt 下必须做视觉简化和像素网格检查。

## 5. 素材说明

`assets/` 中包含：
- `brand_board_user_selected.png`：用户原始品牌板，作为最终视觉参考。
- `primary_mark_reference_crop.png`：主图形裁切参考。
- `primary_wordmark_lockup_reference.png`：横向字标裁切参考。
- `primary_mark_color_raster_reference.png`：从品牌板提取的透明底彩色 PNG 参考。
- `menu_bar_black_raster_reference.png` / `menu_bar_white_raster_reference.png`：从主图形提取的单色预览。
- 其他裁切文件：用于 App Icon / 菜单栏版对照。

**重要：这些 PNG 是从用户提供的品牌板裁切/处理得到的参考图，不是原始矢量母版。** 交付生产包前，设计人员需要依据原图手工描摹为 SVG/PDF/Asset Catalog，检查曲线、重叠关系、边缘、透明度和小尺寸表现。不得直接把整张品牌板当作 App 图标。

## 6. 字标

- 文字必须为 `ScreenBuddy`，大小写如上。
- 黑色、无衬线、偏中粗字重。
- 不额外添加 slogan，除非用户后续确认。
- 字标不进入菜单栏图标。

## 7. 禁止事项

- 不得再生成一套替代 Logo。
- 不得增加第三种品牌色。
- 不得把蓝色改成淡紫/浅蓝渐变。
- 不得把菜单栏图标放进圆角方框。
- 不得把 Siri 彩色边缘光效用到 Logo 本身；Siri-inspired 彩色流光仅属于浮窗交互动效。
