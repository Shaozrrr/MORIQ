# HTML 转 Word：背景图保真调研（2026-11-12）

## 结论与范围

当前 MORIQ 的 LibreOffice 路径会丢失已实测的 HTML 页面背景和元素背景。转换结果会提示背景图可能无法保留；这只是限制提示，不是保真修复。本次没有将候选原型接入产品。

[GenOffice html2docx](https://github.com/genspark-ai/genoffice/tree/1738aecba0b40c7806485104101405033ded7601/packages/html2docx) 是值得继续评估的 Apache-2.0 候选，源版本 `1738aecba0b40c7806485104101405033ded7601`。它在真实浏览器提取布局并截图背景，再生成原生 OOXML 文本；不是完整的无浏览器 HTML 转换器。它的 [架构说明](https://github.com/genspark-ai/genoffice/blob/1738aecba0b40c7806485104101405033ded7601/packages/html2docx/ARCHITECTURE.md) 描述了页面背景方案，但不应据此推断对所有 CSS 背景均支持。

| 样本/检查 | 打包 LibreOffice | GenOffice 隔离原型 |
|---|---|---|
| body 本地背景图，定位 100px、200px | DOCX 中未发现图片，背景丢失 | 背景嵌入；渲染页中红块位置与输入在缩放比例内相符 |
| 上述样本的文字 | 可编辑文本 | `word/document.xml` 含原文 `EDITABLE TEXT 4812`，作为 Word 文字保留 |
| 段落元素 CSS 背景图 | 背景丢失 | 测试产物无嵌入图片，背景丢失 |
| 页面背景资源不存在 | 仍输出文件 | 仍输出文件，未报告缺失；不可认定为安全成功 |
| 保持原 HTML 文件 | MORIQ 使用临时副本处理 | 试验 CLI 读取原 HTML 并写入独立 DOCX；不代表其他输入或运行环境已验证 |

这些是少量自建样本，不代表所有 CSS、分页、Word/WPS/Pages 兼容性或字体和复杂布局。背景资源缺失的检测、外部样式表及层叠规则、分页、图片重复和裁剪、任意元素背景均未达到可交付标准。

## 复现

以下仅供隔离研究，不读取用户文档或联网加载页面资源。需预装 Git、Node 22、npm、Chrome、Python Pillow 和 `pdftoppm`。依赖只安装到 `/tmp`；Chrome 是本机研究依赖，不代表 MORIQ 已打包它。

```sh
git clone --filter=blob:none --no-checkout https://github.com/genspark-ai/genoffice.git /tmp/moriq-h2d-source
git -C /tmp/moriq-h2d-source sparse-checkout init --cone
git -C /tmp/moriq-h2d-source sparse-checkout set packages/html2docx
git -C /tmp/moriq-h2d-source checkout 1738aecba0b40c7806485104101405033ded7601
mkdir -p /tmp/moriq-h2d-probe
cp -R /tmp/moriq-h2d-source/packages/html2docx/src /tmp/moriq-h2d-probe/
cp -R /tmp/moriq-h2d-source/packages/html2docx/tools /tmp/moriq-h2d-probe/
printf '%s\n' '{"private":true,"type":"module"}' > /tmp/moriq-h2d-probe/package.json
cd /tmp/moriq-h2d-probe
npm install --ignore-scripts --no-save docx@9.7.1 vite@7.3.7 tsx playwright-core@1.61.1
python3 - <<'PY'
from PIL import Image
from pathlib import Path
p = Path('.')
Image.new('RGB', (120, 80), '#ed3344').save(p / 'red.png')
page = '''<!doctype html><html><head><meta charset="utf-8"><style>
html,body {margin:0;min-height:1100px}
body {background-image:url(red.png);background-repeat:no-repeat;background-position:100px 200px}
p {position:relative;margin:80px 60px;font:24px sans-serif}
</style></head><body><p>EDITABLE TEXT 4812</p></body></html>'''
(p / 'page.html').write_text(page)
(p / 'missing.html').write_text(page.replace('red.png', 'missing.png'))
(p / 'element.html').write_text('''<!doctype html><html><head><meta charset="utf-8"><style>
p {width:300px;height:200px;background:url(red.png) no-repeat 50px 40px;margin:80px;font:24px sans-serif}
</style></head><body><p>EDITABLE ELEMENT 4812</p></body></html>''')
PY
shasum -a 256 page.html missing.html element.html > input-hashes.txt
CHROME_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' npx tsx tools/cli.ts page.html page.docx --verbose
CHROME_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' npx tsx tools/cli.ts missing.html missing.docx --verbose
CHROME_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' npx tsx tools/cli.ts element.html element.docx --verbose
shasum -a 256 -c input-hashes.txt
unzip -l page.docx | grep 'word/media/'
unzip -p page.docx word/document.xml | grep -o 'EDITABLE TEXT 4812'
unzip -l element.docx | grep 'word/media/' || true
```

使用 MORIQ 打包 LibreOffice 将 `page.docx` 转成 PDF、再渲染第一页，可目视核对背景位置。原试验输出为 `/tmp/moriq-genoffice-probe/rendered.png`，临时文件可能被系统清理。

## 安全与依赖判断

`src/convert.ts` 调用 `BrowserDriver.evaluate` 读取 DOM/计算样式，并调用驱动截图；`src/driver.ts` 明确要求浏览器页面能力。OOXML 生成部分可单独消费其内部意图树与图像，但仓库没有证明能在不依赖浏览器的情况下直接把任意 HTML 和 CSS 转成该意图树并保留背景。CLI 使用 `playwright-core` 和本机 Chrome，需另行解决用户本地 HTML 脚本执行、外部网络请求、资源读取权限和失败检测；不能直接作为 MORIQ 的安全离线引擎。

其他候选方面，[XonLoke/html-to-docx](https://github.com/XonLoke/html-to-docx) 文档说明依赖浏览器计算样式，且复杂布局会简化；[dom-docx](https://github.com/floodtide/dom-docx) 的公开说明没有证明能保留一般 CSS 背景图片。两者未在本次验收中证实满足缺失资源检测和目标保真要求。目前未找到可直接替换、同时满足无浏览器、可编辑、背景定位和缺失资源明确失败的成熟组件。
