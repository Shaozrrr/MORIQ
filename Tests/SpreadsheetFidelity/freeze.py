from pathlib import Path
from tempfile import TemporaryDirectory
from subprocess import run
from os import environ
from zipfile import ZipFile
from xml.etree import ElementTree as ET
from openpyxl import Workbook, load_workbook

exe = environ['MORIQ_SHEET_TEST_EXECUTABLE']
C = '{urn:oasis:names:tc:opendocument:xmlns:config:1.0}'
with TemporaryDirectory(prefix='moriq-multisheet-') as temp:
    root=Path(temp); w=Workbook(); w.active.title='预算 & 计划'; w.active.freeze_panes='B3'; w.active['A1']='保留'
    s=w.create_sheet('只冻结列'); s.freeze_panes='D1'; s['A1']='列'
    s=w.create_sheet('只冻结行'); s.freeze_panes='A5'; s['A1']='行'
    s=w.create_sheet('不冻结'); s['A1']='无'; w.save(root/'budget.xlsx')
    run([exe,temp],check=True,capture_output=True)
    with ZipFile(root/'ods/budget.ods') as z:
        xml=ET.fromstring(z.read('settings.xml'))
        tables=next(e for e in xml.iter(C+'config-item-map-named') if e.get(C+'name')=='Tables')
        entries={e.get(C+'name'):{x.get(C+'name'):x.text for x in e if x.tag==C+'config-item'} for e in tables}
        assert entries['预算 & 计划']['HorizontalSplitPosition']=='1'
        assert entries['预算 & 计划']['VerticalSplitPosition']=='2'
        assert entries['只冻结列']['HorizontalSplitPosition']=='3'
        assert entries['只冻结行']['VerticalSplitPosition']=='4'
        assert '不冻结' not in entries
    restored=load_workbook(root/'xlsx/budget.xlsx')
    assert [restored[n].freeze_panes for n in restored.sheetnames]==['B3','D1','A5',None]
    assert load_workbook(root/'budget.xlsx')['预算 & 计划'].freeze_panes=='B3'
    print('PASS: multi-sheet frozen rows, columns, both, none and Unicode names survive')
