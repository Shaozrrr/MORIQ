import hashlib
import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile
here=Path(__file__).parent
spec=importlib.util.spec_from_file_location('fallback',here/'fallback.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
root=Path('/tmp/moriq-wk-map-probe')
source=root/'source.html';baseline=root/'source.docx';marked=root/'marked.docx';manifest=root/'manifest.json'
digest=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p):digest(p) for p in (source,baseline,marked,manifest)}
with TemporaryDirectory(prefix='moriq-map-fallback-') as tmp:
    directory=Path(tmp)
    result=directory/'success.docx'; notice=m.convert_with_fallback(marked,manifest,baseline,result)
    assert '实验映射完成' in notice
    with ZipFile(result) as z:
        body=z.read('word/document.xml').decode();assert body.count('DUPLICATE TEXT')==2 and 'MQR' not in body
    bad=json.loads(manifest.read_text());bad[0]['marker']='MISSING_UNIQUE_MARKER'
    bad_manifest=directory/'bad.json';bad_manifest.write_text(json.dumps(bad))
    fallback=directory/'fallback.docx'; notice=m.convert_with_fallback(marked,bad_manifest,baseline,fallback)
    assert '背景未能保留' in notice and fallback.read_bytes()==baseline.read_bytes()
    with ZipFile(fallback) as z:
        body=z.read('word/document.xml').decode();assert body.count('DUPLICATE TEXT')==2 and 'MQR' not in body
    sentinel=directory/'existing.docx';sentinel.write_text('keep')
    try:m.convert_with_fallback(marked,bad_manifest,baseline,sentinel)
    except FileExistsError:pass
    else:raise AssertionError('existing file overwritten')
    assert sentinel.read_text()=='keep'
assert all(digest(Path(p))==v for p,v in before.items())
print('PASS isolated fallback preserves baseline bytes, original files and existing output; warning explicit')
