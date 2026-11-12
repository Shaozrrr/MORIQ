"""Conflicting ODS font-face names must not guess a replacement font."""
from os import environ
from pathlib import Path
from subprocess import run
from tempfile import TemporaryDirectory
from zipfile import ZipFile
from openpyxl import Workbook, load_workbook

java = Path(environ['MORIQ_SHEET_JAVA']).resolve(strict=True)
helper = Path(environ['MORIQ_SHEET_HELPER']).resolve(strict=True)
prefix = '''xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"'''
with TemporaryDirectory(prefix='moriq-ambiguous-font-') as temp:
    root = Path(temp)
    source, output = root / 'input.ods', root / 'output.xlsx'
    with ZipFile(source, 'w') as archive:
        archive.writestr('styles.xml', f'<office:document-styles {prefix}><style:font-face style:name="Shared" svg:font-family="Arial"/></office:document-styles>')
        archive.writestr('content.xml', f'<office:document-content {prefix}><style:font-face style:name="Shared" svg:font-family="Courier New"/></office:document-content>')
    book = Workbook()
    book.active['A1'] = '保留'
    book.save(output)
    before = output.read_bytes()
    run([str(java), '-Djava.awt.headless=true', '-jar', str(helper), str(source), str(output), 'ods', 'xlsx'], check=True, capture_output=True, timeout=60)
    assert output.read_bytes() == before
    assert load_workbook(output).active['A1'].value == '保留'
    print('PASS conflicting font-face definitions fall back without changing exported workbook')
