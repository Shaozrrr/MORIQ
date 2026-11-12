"""Force paragraph reflow in a synthetic output; not a production mapping."""
from pathlib import Path
from copy import deepcopy
from zipfile import ZipFile
import xml.etree.ElementTree as ET
root=Path('/tmp/moriq-wk-background-probe')
source=root/'paragraph-after.docx'; output=root/'paragraph-reflow.docx'
ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
with ZipFile(source) as src:
    doc=ET.fromstring(src.read('word/document.xml'))
    body=doc.find('.//w:body',ns)
    paragraphs=body.findall('w:p',ns)
    intro=next(p for p in paragraphs if ''.join(t.text or '' for t in p.findall('.//w:t',ns))=='INTRODUCTION TEXT')
    for _ in range(100): body.insert(0,deepcopy(intro))
    with ZipFile(output,'w') as dst:
        for item in src.infolist(): dst.writestr(item,ET.tostring(doc,encoding='utf-8',xml_declaration=True) if item.filename=='word/document.xml' else src.read(item.filename))
print('Created',output)
