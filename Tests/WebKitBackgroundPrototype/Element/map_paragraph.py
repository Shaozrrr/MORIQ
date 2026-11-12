"""Synthetic experiment only; do not use as a general HTML/DOCX converter."""
from pathlib import Path
from tempfile import NamedTemporaryFile
import os
import xml.etree.ElementTree as ET
from zipfile import ZipFile
root = Path('/tmp/moriq-wk-background-probe')
source, target = root / 'paragraph-before.docx', root / 'paragraph-after.docx'
ns = {'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main', 'wp':'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'}
for prefix, uri in ns.items(): ET.register_namespace(prefix,uri)
with ZipFile(source) as src:
    document = ET.fromstring(src.read('word/document.xml'))
    paragraphs = document.findall('.//w:body/w:p', ns)
    matches = [p for p in paragraphs if ''.join(t.text or '' for t in p.findall('.//w:t', ns)) == 'CARD TEXT']
    assert len(matches) == 1, 'ambiguous paragraph text'
    anchors = [(p, run) for p in paragraphs for run in p.findall('w:r',ns) if run.find('.//wp:anchor',ns) is not None]
    assert len(anchors) == 1, 'expected one synthetic background anchor'
    parent, run = anchors[0]
    anchor = run.find('.//wp:anchor', ns)
    h, v = anchor.find('wp:positionH',ns), anchor.find('wp:positionV',ns)
    h.set('relativeFrom','column'); v.set('relativeFrom','paragraph')
    parent.remove(run); matches[0].append(run)
    xml = ET.tostring(document,encoding='utf-8',xml_declaration=True)
    with NamedTemporaryFile(dir=root, suffix='.docx',delete=False) as temporary:
        temp_path = temporary.name
    try:
        with ZipFile(temp_path,'w') as dst:
            for item in src.infolist():
                data = xml if item.filename == 'word/document.xml' else src.read(item.filename)
                dst.writestr(item,data)
        os.replace(temp_path,target)
    finally:
        if os.path.exists(temp_path): os.unlink(temp_path)
print('PASS mapped synthetic background to matching editable Word paragraph:',target)
