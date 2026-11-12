# 随包 HTML→PDF→Word 背景链路核查

MORIQ 随包的 Stirling Office Convert 0.3.3 不能将 HTML 直接输出为 DOCX；可先转 PDF，再转 DOCX。该链路没有替换产品现有转换路径。

2026-11-12 的合成样本包含两段可编辑文字、页面背景和两个设置了 repeat 背景的段落。结果：

- 原 HTML 使用本地文件引用时，HTML→PDF 返回成功并警告图片被省略；不能把退出码 0 当作资源完整。
- 使用隔离资源预处理原型将图片嵌成 data URI 后，页面背景出现在 HTML→PDF 结果中的预期位置；PDF→DOCX 后，文字仍是 Word 文本，页面背景仍以独立图片存在。LibreOffice 将该 DOCX 渲染回 PDF 后，红色背景区域约为 `(80,160)–(95,176)`，与原 PDF 中 `(80,160)–(96,176)` 接近（900px 高的测试图）。
- 两个段落的 repeat 背景在 HTML→PDF 阶段已丢失，因此该链路不能用于宣称一般网页背景保真。
- 默认不加网络许可时，用 127.0.0.1 监听器的图片样本实测收到 0 次请求；转换仍返回 0，诊断提示关联图片未绘制。此测试不能证明其他协议或所有资源的安全行为。

## 样本复现

```sh
cd $HOME/Documents/Codex/2026-11-09/gen-2/outputs/MORIQ
mkdir -p /tmp/moriq-bundled-html-check
python3 - <<'PY'
from PIL import Image
from pathlib import Path
p=Path('/tmp/moriq-bundled-html-check')
Image.new('RGB',(20,20),'red').save(p/'red.png')
(p/'sample.html').write_text('''<!doctype html><html><head><meta charset="utf-8"><style>
body { margin:0; padding:0; background-image:url(red.png); background-repeat:no-repeat; background-position:100px 200px; }
p.card { width:200px; height:60px; background-image:url(red.png); background-repeat:repeat; margin:0 0 80px; font:16px/20px Arial }
</style></head><body><p class="card">EDITABLE TEXT ONE</p><p class="card">EDITABLE TEXT TWO</p></body></html>''')
PY
Vendor/OfficeEngine/jre-arm64/bin/java -jar Vendor/OfficeEngine/converter.jar /tmp/moriq-bundled-html-check/sample.html -o /tmp/moriq-bundled-html-check/direct.pdf
PYTHONPATH=/tmp/moriq-css-sanitize-deps:Tests/WebKitBackgroundPrototype/SafeResources $HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 - <<'PY'
from pathlib import Path
from prepare import prepare
p=Path('/tmp/moriq-bundled-html-check'); result=prepare(p/'sample.html')
assert result['html'] is not None, result
(p/'prepared.html').write_text(result['html'])
PY
Vendor/OfficeEngine/jre-arm64/bin/java -jar Vendor/OfficeEngine/converter.jar /tmp/moriq-bundled-html-check/prepared.html -o /tmp/moriq-bundled-html-check/prepared.pdf
Vendor/OfficeEngine/jre-arm64/bin/java -jar Vendor/OfficeEngine/converter.jar /tmp/moriq-bundled-html-check/prepared.pdf -o /tmp/moriq-bundled-html-check/result.docx
unzip -p /tmp/moriq-bundled-html-check/result.docx word/document.xml | grep -o 'EDITABLE TEXT ONE\|EDITABLE TEXT TWO'
unzip -l /tmp/moriq-bundled-html-check/result.docx | grep 'word/media/'
pdftoppm -f 1 -l 1 -scale-to 900 -png -singlefile /tmp/moriq-bundled-html-check/prepared.pdf /tmp/moriq-bundled-html-check/prepared
```

样本中的预处理器位于 `Tests/WebKitBackgroundPrototype/SafeResources`，只在实验环境安装 tinycss2，lxml 和 Pillow 来自实验 Python；它尚未随应用分发，也不是普通转换基线的完整安全保证。x86_64 机器应使用 `jre-x86_64`。

## 产品提示和后续工作

现有 HTML→DOCX 结果记录提示“网页背景图可能仅保留首页或丢失，请检查版式和图片”；单项转换完成提示也显示该限制，批量完成提示引导查看各项转换记录。提示是当前限制，不代表背景问题已解决。

继续推进需在可分发的依赖、受限资源加载和缺图失败保证下，解决元素背景、文字/图片几何、多页重排与真实 Word/WPS 验收。现有 WebKit 合成原型证明了部分可能性，但尚不满足一般页面接入标准，参见 `Tests/WebKitBackgroundPrototype/README.md`。
