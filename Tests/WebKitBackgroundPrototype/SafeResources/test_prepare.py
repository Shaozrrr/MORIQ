import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
from PIL import Image
from lxml import html
from prepare import prepare

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
with TemporaryDirectory(prefix='moriq-safe-resources-') as tmp:
    outer=Path(tmp);root=outer/'input';root.mkdir()
    (root/'styles'/'nested').mkdir(parents=True);(root/'imgs').mkdir()
    Image.new('RGB',(8,8),'red').save(root/'imgs'/'red.png')
    Image.new('RGB',(8,8),'blue').save(outer/'outside.png')
    (root/'imgs'/'escape.png').symlink_to(outer/'outside.png')
    (root/'outside-dir').symlink_to(outer, target_is_directory=True)
    (root/'styles'/'cycle.css').write_text('@import "cycle.css";')
    (root/'styles'/'network.css').write_text('@import "https://127.0.0.1/not-allowed.css";')
    (root/'styles'/'nested'/'extra.css').write_text('p { background-image:url("../../imgs/red.png"); background-repeat:repeat }')
    (root/'styles'/'main.css').write_text('@import "nested/extra.css"; body { margin:0; padding:0 }')
    source=root/'sample.html'
    original='<html><head><link rel="stylesheet" href="styles/main.css"></head><body><p style="background-image:url(imgs/red.png)">可编辑内容 4812</p><img src="imgs/red.png" alt="red"><a href="https://example.com/">链接</a></body></html>'
    source.write_text(original)
    before={str(p):digest(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
    result=prepare(source)
    assert result['notice'] is None,result
    assert result['html'].count('data:image/png;base64,')==3,result['html']
    assert html.fromstring(result['html']).xpath('//body')[0].text_content()==html.fromstring(original).xpath('//body')[0].text_content()
    assert 'https://example.com/' in result['html'] and set(result['resources'])=={'sample.html','styles/main.css','styles/nested/extra.css','imgs/red.png'}
    assert all(digest(Path(p))==v for p,v in before.items())
    cases={
      'missing':'<img src="imgs/missing.png">',
      'network':'<p style="background-image:url(https://127.0.0.1/x.png)">x</p>',
      'traversal':'<img src="../outside.png">',
      'symlink':'<img src="imgs/escape.png">',
      'symlink-dir':'<img src="outside-dir/outside.png">',
      'cycle':'<link rel="stylesheet" href="styles/cycle.css">',
      'nested-network':'<link rel="stylesheet" href="styles/network.css">',
      'encoded-traversal':'<img src="%2e%2e/outside.png">',
      'local-file-url':'<img src="file:///tmp/outside.png">',
      'script':'<script>window.x=1</script>',
      'srcset':'<img src="imgs/red.png" srcset="imgs/red.png 2x">',
      'font':'<style>@font-face {font-family:x;src:url(imgs/red.png)}</style>',
      'implicit-image-set':'<p style="background-image:image-set(\"imgs/red.png\" 1x)">x</p>',
    }
    for name,body in cases.items():
        bad=root/(name+'.html');bad.write_text('<html><body>'+body+'</body></html>')
        output=prepare(bad)
        assert output['html'] is None and '回退' in output['notice'],(name,output)
    print('PASS nested stylesheet imports and images; preserved text and source; unsupported/missing/network/traversal/symlink fail closed')
