"""An optional metadata limit must not invalidate an otherwise exported workbook."""
from os import environ
from pathlib import Path
from subprocess import run
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from openpyxl import Workbook, load_workbook

java = Path(environ['MORIQ_SHEET_JAVA']).resolve(strict=True)
helper = Path(environ['MORIQ_SHEET_HELPER']).resolve(strict=True)
with TemporaryDirectory(prefix='moriq-oversize-') as temp:
    root = Path(temp)
    source, target = root / 'source.ods', root / 'output.xlsx'
    styles = '''<office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"><style:style style:name="Default" style:family="table-cell"><style:text-properties fo:font-family="Arial" fo:font-size="11pt"/></style:style></office:document-styles>'''
    with ZipFile(source, 'w') as archive:
        archive.writestr('styles.xml', styles)
        archive.writestr('content.xml', '<root><!--' + 'x' * (33 * 1024 * 1024) + '--></root>')
    book = Workbook()
    book.active['A1'] = '保留'
    book.save(target)
    original = target.read_bytes()
    run([str(java), '-Djava.awt.headless=true', '-jar', str(helper), str(source), str(target), 'ods', 'xlsx'], check=True, capture_output=True, timeout=60)
    assert target.read_bytes() == original
    assert load_workbook(target).active['A1'].value == '保留'
    print('PASS oversized optional metadata falls back without changing exported workbook')
