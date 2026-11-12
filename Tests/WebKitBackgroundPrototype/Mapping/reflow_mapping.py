"""Add non-target paragraphs before mapping to exercise Word page reflow."""
import copy
import importlib.util
from pathlib import Path
from zipfile import ZipFile
from lxml import etree as ET
root=Path('/tmp/moriq-wk-map-probe')
source=root/'marked.docx'; expanded=root/'marked-reflow.docx'; output=root/'mapped-reflow.docx'
ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
with ZipFile(source) as original:
    doc=ET.fromstring(original.read('word/document.xml'));body=doc.find('.//w:body',ns)
    paragraph=ET.Element('{%s}p'%ns['w']);run=ET.SubElement(paragraph,'{%s}r'%ns['w']);text=ET.SubElement(run,'{%s}t'%ns['w']);text.text='SYNTHETIC INTRODUCTION'
    for _ in range(100): body.insert(0,copy.deepcopy(paragraph))
    with ZipFile(expanded,'w') as result:
        for item in original.infolist(): result.writestr(item,ET.tostring(doc,encoding='utf-8',xml_declaration=True) if item.filename=='word/document.xml' else original.read(item.filename))
spec=importlib.util.spec_from_file_location('mapping',Path(__file__).parent/'map_docx.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
module.run(expanded,root/'manifest.json',output)
print('PASS mapping after inserting 100 non-target paragraphs:',output)
