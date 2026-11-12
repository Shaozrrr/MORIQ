"""Compare round-trip cell fonts with the original, not just engine output."""
from os import environ
from pathlib import Path
from subprocess import run
from tempfile import TemporaryDirectory
from zipfile import ZipFile
from xml.etree import ElementTree as ET

from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill

executable = Path(environ['MORIQ_SHEET_TEST_EXECUTABLE']).resolve(strict=True)
with TemporaryDirectory(prefix='moriq-font-roundtrip-') as temp:
    root = Path(temp)
    book = Workbook()
    book._fonts[0] = Font(name='Arial', size=11)
    book.active['A1'] = '普通文本'
    book.active['B1'] = '加粗'
    book.active['B1'].font = Font(name='Arial', size=11, bold=True)
    book.active['C1'] = '斜体'
    book.active['C1'].font = Font(name='Times New Roman', size=15, italic=True)
    book.active['B2'].font = Font(name='Arial', size=11, bold=True)
    book.active['B2'].fill = PatternFill('solid', fgColor='FFFFFF00')
    book.save(root / 'budget.xlsx')
    run([str(executable), str(root)], check=True, capture_output=True, timeout=120)
    source_book = load_workbook(root / 'budget.xlsx')
    result_book = load_workbook(root / 'xlsx' / 'budget.xlsx')
    source = source_book.active
    result = result_book.active
    assert result_book._fonts[result_book._cell_styles[0].fontId].name == source_book._fonts[source_book._cell_styles[0].fontId].name, 'unstyled blank cells changed default font'
    for coordinate in ('A1', 'B1', 'C1', 'B2'):
        a, b = source[coordinate].font, result[coordinate].font
        assert (a.name, a.sz, a.bold, a.italic) == (b.name, b.sz, b.bold, b.italic), (
            coordinate, (a.name, a.sz, a.bold, a.italic), (b.name, b.sz, b.bold, b.italic)
        )
    assert result['B2'].value is None and result['B2'].fill.fgColor.rgb[-6:] == 'FFFF00'
    print('PASS round-trip cell fonts match original')
    # A user edits the intermediate ODS: the selected cell's explicit font
    # must follow that edit rather than an old copy of the original XLSX.
    ods = root / 'ods' / 'budget.ods'
    modified = root / 'modified.ods'
    style_ns = '{urn:oasis:names:tc:opendocument:xmlns:style:1.0}'
    with ZipFile(ods) as source_zip, ZipFile(modified, 'w') as output_zip:
        for entry in source_zip.infolist():
            data = source_zip.read(entry.filename)
            if entry.filename == 'content.xml':
                document = ET.fromstring(data)
                for style in document.iter(style_ns + 'style'):
                    if style.get(style_ns + 'name') == 'ce1':
                        props = style.find(style_ns + 'text-properties')
                        assert props is not None
                        props.set(style_ns + 'font-name', 'Times New Roman')
                        break
                else:
                    raise AssertionError('expected explicit cell style')
                data = ET.tostring(document, encoding='utf-8', xml_declaration=True)
            output_zip.writestr(entry, data)
    office = Path(environ['MORIQ_SHEET_OFFICE']).resolve(strict=True)
    java = Path(environ['MORIQ_SHEET_JAVA']).resolve(strict=True)
    helper = Path(environ['MORIQ_SHEET_HELPER']).resolve(strict=True)
    out = root / 'edited'; out.mkdir()
    run([str(office), '-env:UserInstallation=' + (root / 'profile').as_uri(), '--headless', '--convert-to', 'xlsx', '--outdir', str(out), str(modified)], check=True, capture_output=True, timeout=60)
    result_path = out / 'modified.xlsx'
    run([str(java), '-Djava.awt.headless=true', '-jar', str(helper), str(modified), str(result_path), 'ods', 'xlsx'], check=True, capture_output=True, timeout=60)
    assert load_workbook(result_path).active['B1'].font.name == 'Times New Roman'
    print('PASS current ODS font edit is preserved')
    # Optional width/font postprocessing must not fail an otherwise successful
    # conversion merely because an output worksheet exceeds our XML limit.
    large = root / 'large-output.xlsx'
    with ZipFile(root / 'xlsx/budget.xlsx') as original_zip, ZipFile(large, 'w') as large_zip:
        for entry in original_zip.infolist():
            data = original_zip.read(entry.filename)
            if entry.filename == 'xl/worksheets/sheet1.xml':
                marker = b'</worksheet>'
                assert marker in data
                data = data.replace(marker, b'<!--' + b'x' * (33 * 1024 * 1024) + b'-->' + marker, 1)
            large_zip.writestr(entry, data)
    before = large.read_bytes()
    run([str(java), '-Djava.awt.headless=true', '-jar', str(helper), str(ods), str(large), 'ods', 'xlsx'], check=True, capture_output=True, timeout=60)
    assert large.read_bytes() == before
    print('PASS large output worksheet safely skips optional postprocessing')
    # Near Excel's style limit, leave font restoration untouched rather than
    # adding more cell styles. Generate the large fixture only in a temp dir.
    limited = root / 'style-limit.xlsx'
    ns = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
    with ZipFile(root / 'xlsx/budget.xlsx') as original_zip, ZipFile(limited, 'w') as target_zip:
        for entry in original_zip.infolist():
            data = original_zip.read(entry.filename)
            if entry.filename == 'xl/styles.xml':
                document = ET.fromstring(data)
                fonts = document.find(ns + 'fonts')
                for font in fonts.findall(ns + 'font'):
                    name = font.find(ns + 'name')
                    if name is not None:
                        name.set('val', 'MORIQ Fallback Font')
                xfs = document.find(ns + 'cellXfs')
                exemplar = ET.tostring(xfs[0])
                while len(xfs) < 64000:
                    xfs.append(ET.fromstring(exemplar))
                xfs.set('count', str(len(xfs)))
                data = ET.tostring(document, encoding='utf-8', xml_declaration=True)
            target_zip.writestr(entry, data)
    run([str(java), '-Djava.awt.headless=true', '-jar', str(helper), str(ods), str(limited), 'ods', 'xlsx'], check=True, capture_output=True, timeout=60)
    with ZipFile(limited) as archive:
        document = ET.fromstring(archive.read('xl/styles.xml'))
        assert len(document.find(ns + 'cellXfs')) == 64000
    limited_book = load_workbook(limited)
    assert limited_book.active['B1'].value == '加粗'
    assert limited_book.active['B1'].font.name == 'MORIQ Fallback Font'
    print('PASS style-limit fallback avoids adding cell styles')
