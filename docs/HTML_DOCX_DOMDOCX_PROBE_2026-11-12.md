# HTML→可编辑 Word 背景：dom-docx 补充评估

2026-11-12，测试仅使用自建 HTML 和内嵌 1×1 PNG，未读取用户文档，未修改 MORIQ 转换实现。现有 LibreOffice、GenOffice 同类样本的证据参见 `HTML_WORD_BACKGROUND_RESEARCH_2026-11-12.md`。

[dom-docx 官方仓库](https://github.com/floodtide/dom-docx) 标明 MIT 许可，输出原生可编辑 OOXML；其默认 inline 路径无需浏览器，仅解析行内样式；computed 路径在 Node 下需 Playwright 和 Chromium。项目自身列明外部样式表在 inline 路径不支持，也不保证复杂多页布局。MIT 许可仅是组件许可证，实际打包需逐项审查依赖和许可。

在隔离临时目录通过 `npm install --ignore-scripts --no-audit --no-fund dom-docx@1.0.3` 安装，Node 22.22.3，调用 `convertHtmlToDocx(html)` 并直接检查输出 `word/document.xml` 和 `word/media/`：

| 合成 HTML 样本 | 实测 |
| --- | --- |
| 行内 `<p style="background-color:#ff0000">INLINE_MARK</p>` | 文字以 Word XML 文本出现，`w:shd` 包含 `ff0000` 段落底色。 |
| `<body style="background-color:#0000ff"><p>PAGE_MARK</p></body>` | 文本出现，没有 `w:background` 或蓝色底色。 |
| `<p style="background-image:url(data:image/png;base64,...) ">IMAGE_MARK</p>` | 文本出现，`word/media/` 没有背景图片。 |
| `<style>.sample { background-color:#00ff00 }</style><p class="sample">CLASS_MARK</p>` | 文本出现，绿色样式未保留；标准错误明确提醒默认模式忽略类样式。 |

此为有限结构检查，未对 Word/WPS 页面视觉、嵌套背景、背景定位/重复、外链资源和浏览器 computed 模式做验收，不能外推所有输入或该项目其他版本。实验包及文件在测试后清理。

[html-docx-js 官方仓库](https://github.com/evidenceprime/html-docx-js) 采用 altChunk；项目说明 LibreOffice 和 Google Docs 不支持该方式，故不能仅因为 Word 可导入就作为多应用兼容方案。[privateOmega/html-to-docx](https://github.com/privateOmega/html-to-docx) 采用另一实现并说明不是完整解决方案，本次未用样本证明能解决背景。

**建议：**保留现有成熟引擎为基础。对明确可映射的纯色背景，可研究生成原生段落或单元格底纹并在 Word、WPS、LibreOffice 做可编辑和视觉回归；CSS 图像、页面底色、外部样式及复杂布局不能假定由该组件覆盖。若要保留复杂网页的页面背景，需单独解决本地资源加载、缺失检测、浏览器运行安全及图像绘制/分页，再用复杂样本逐项验证；在这些证据具备前，不应声称完整保真。
