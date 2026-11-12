"""Synthetic regression checks for marker mapping; never run on user documents."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile
from lxml import etree as ET

here=Path(__file__).parent
spec=importlib.util.spec_from_file_location('mapping',here/'map_docx.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
original=Path('/tmp/moriq-wk-map-probe')
with TemporaryDirectory(prefix='moriq-map-test-') as tmp:
    root=Path(tmp); module.ROOT=root
    for name in ('element-0.png','element-1.png','marked.docx','manifest.json'):
        (root/name).write_bytes((original/name).read_bytes())
    records=json.loads((root/'manifest.json').read_text())
    output=root/'success.docx'; module.run(root/'marked.docx',root/'manifest.json',output)
    with ZipFile(output) as z:
        body=z.read('word/document.xml').decode()
        assert body.count('DUPLICATE TEXT')==2 and all(r['marker'] not in body for r in records)
        assert body.count('behindDoc="1"')==2
    broken=deepcopy(records); broken[0]['marker']='NONEXISTENT_UNIQUE_MARKER'
    (root/'missing-marker.json').write_text(json.dumps(broken))
    try: module.run(root/'marked.docx',root/'missing-marker.json',root/'must-not-exist.docx')
    except ValueError: pass
    else: raise AssertionError('missing marker accepted')
    assert not (root/'must-not-exist.docx').exists()
    (root/'element-1.png').unlink()
    try: module.run(root/'marked.docx',root/'manifest.json',root/'missing-image.docx')
    except ValueError: pass
    else: raise AssertionError('missing image accepted')
    assert not (root/'missing-image.docx').exists()
print('PASS duplicate text mapped via unique IDs; missing marker/resource rejected without output')
