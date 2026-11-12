from pathlib import Path
from PIL import Image
from prepare import prepare
root=Path('/tmp/moriq-safe-e2e');(root/'styles'/'nested').mkdir(parents=True,exist_ok=True);(root/'imgs').mkdir(exist_ok=True)
Image.new('RGB',(20,20),'red').save(root/'imgs'/'red.png')
(root/'styles'/'nested'/'cards.css').write_text('p.card {width:200px;height:60px;background-image:url(../../imgs/red.png);background-repeat:repeat;margin:0 0 80px;font:16px/20px Arial}')
(root/'styles'/'main.css').write_text('@import "nested/cards.css";html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden}')
source=root/'original.html'; source.write_text('<html><head><meta charset="utf-8"><link rel="stylesheet" href="styles/main.css"></head><body><p id="one" class="card">DUPLICATE TEXT</p><p id="two" class="card">DUPLICATE TEXT</p></body></html>')
result=prepare(source);assert result['notice'] is None,result
(root/'prepared.html').write_text(result['html'])
print('PASS prepared nested CSS and image as embedded data:',result['resources'])
