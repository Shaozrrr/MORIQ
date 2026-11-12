"""Focused ODS/XLSX column and style regression. Uses isolated generated workbooks."""
from copy import copy
from pathlib import Path
from subprocess import run
from tempfile import TemporaryDirectory
from zipfile import ZipFile
from xml.etree import ElementTree as ET
from os import environ
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill, Alignment

exe = Path(environ['MORIQ_SHEET_TEST_EXECUTABLE']).resolve(strict=True)
oldexe = Path(environ['MORIQ_SHEET_BASELINE_EXECUTABLE']).resolve(strict=True)
java = Path(environ['MORIQ_SHEET_JAVA']).resolve(strict=True)
helper = Path(environ['MORIQ_SHEET_HELPER']).resolve(strict=True)
office = Path(environ['MORIQ_SHEET_OFFICE']).resolve(strict=True)
S = '{urn:oasis:names:tc:opendocument:xmlns:style:1.0}'
T = '{urn:oasis:names:tc:opendocument:xmlns:table:1.0}'
FO = '{urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0}'
TEXT = '{urn:oasis:names:tc:opendocument:xmlns:text:1.0}'

def mutate_package(path, entry, transform):
    temporary = path.with_suffix('.tmp')
    with ZipFile(path) as src, ZipFile(temporary, 'w') as dst:
        for item in src.infolist():
            data = src.read(item.filename)
            if item.filename == entry:
                root = ET.fromstring(data); transform(root)
                data = ET.tostring(root, encoding='utf-8', xml_declaration=True)
            dst.writestr(item, data)
    temporary.replace(path)

def convert_ods(ods, folder):
    folder.mkdir()
    profile = folder / 'profile'
    run([str(office), '-env:UserInstallation=' + profile.as_uri(), '--headless', '--convert-to', 'xlsx', '--outdir', str(folder), str(ods)], check=True, capture_output=True, timeout=60)
    result = folder / (ods.stem + '.xlsx'); assert result.is_file()
    return result

def correct(ods, xlsx):
    run([str(java), '-Djava.awt.headless=true', '-jar', str(helper), str(ods), str(xlsx), 'ods', 'xlsx'], check=True, capture_output=True, timeout=60)

def cells_equal(a, b):
    for name in a.sheetnames:
        for row in a[name]:
            for x in row:
                y = b[name][x.coordinate]
                if x.value is None and not x.has_style:
                    continue
                assert x.value == y.value and x.number_format == y.number_format
                # Font family is intentionally restored from ODS; every other
                # font property and every non-font style must remain intact.
                oldfont, newfont = copy(x.font), copy(y.font)
                oldfont.name = newfont.name
                oldfont.scheme = newfont.scheme
                assert oldfont == newfont, (name, x.coordinate, 'font properties')
                for prop in ('fill', 'border', 'alignment', 'protection'):
                    assert copy(getattr(x, prop)) == copy(getattr(y, prop)), (name, x.coordinate, prop)

with TemporaryDirectory(prefix='moriq-width-matrix-') as temp:
    base = Path(temp)
    for font in ('Calibri', 'Arial', 'Times New Roman', 'Courier New'):
        current = base / font; current.mkdir()
        wb = Workbook(); wb._fonts[0] = Font(name=font, size=11)
        sheet = wb.active; sheet.title = '数据 & 标注'
        for i, width in enumerate((5, 8.43, 12, 24, 40), 1):
            key = chr(64 + i); sheet.column_dimensions[key].width = width; sheet[f'{key}1'] = '1234567890'
        sheet['A2'] = '汉字'; sheet['B2'] = '=SUM(1,2)'
        sheet['C2'] = '特别样式'; sheet['C2'].font = Font(name='Times New Roman', bold=True, color='FFFF0000')
        sheet['C2'].fill = PatternFill('solid', fgColor='FF00FF00'); sheet['C2'].alignment = Alignment(horizontal='center')
        sheet.freeze_panes = 'B3'; other = wb.create_sheet('其它'); other['A1'] = '留存'; other.column_dimensions['A'].width = 17
        source = current / 'budget.xlsx'; wb.save(source); raw = source.read_bytes()
        run([str(exe), str(current)], capture_output=True, check=True, timeout=120)
        corrected = load_workbook(current / 'xlsx/budget.xlsx')
        assert corrected._fonts[0].name == font
        for i, target in enumerate((5, 8.43, 12, 24, 40), 1):
            value = corrected['数据 & 标注'].column_dimensions[chr(64 + i)].width
            assert abs(value - target) < 0.3, (font, target, value)
        assert abs(corrected['其它'].column_dimensions['A'].width - 17) < 0.3
        assert corrected['数据 & 标注'].freeze_panes == 'B3' and source.read_bytes() == raw
        if font == 'Arial':
            baseline = current / 'baseline'; baseline.mkdir(); (baseline/'budget.xlsx').write_bytes(raw)
            run([str(oldexe), str(baseline)], capture_output=True, check=True, timeout=120)
            uncorrected = load_workbook(baseline/'xlsx/budget.xlsx')
            cells_equal(uncorrected, corrected)
            original = load_workbook(source)
            for coordinate in ('A1', 'A2', 'B2', 'C2'):
                assert corrected['数据 & 标注'][coordinate].font.name == original['数据 & 标注'][coordinate].font.name
        print('PASS width/font, multiple sheets and preserved styles:', font, flush=True)

    ods = base / 'Arial/ods/budget.ods'
    # Simulate a user changing both content and column width in the intermediate ODS.
    def edit(root):
        table = next(e for e in root.iter(T+'table') if e.get(T+'name') == '数据 & 标注')
        first = table.find(T+'table-column'); style = first.get(T+'style-name')
        target = next(e for e in root.iter(S+'style') if e.get(S+'name') == style and e.get(S+'family') == 'table-column')
        prop = target.find(S+'table-column-properties'); width = prop.get(S+'column-width'); assert width.endswith('cm')
        prop.set(S+'column-width', f'{float(width[:-2]) * 1.5:.5f}cm')
        para = next(table.iter(TEXT+'p')); para.text = '用户修改的内容'
    mutate_package(ods, 'content.xml', edit)
    edited = convert_ods(ods, base/'edited'); correct(ods, edited)
    result = load_workbook(edited); assert result['数据 & 标注']['A1'].value == '用户修改的内容'
    assert abs(result['数据 & 标注'].column_dimensions['A'].width - 7.5) < 0.3
    print('PASS edited ODS text and resized column are respected', flush=True)

    # Missing fonts must never trigger a guessed-width rewrite.
    def missing(root):
        for style in root.iter(S+'style'):
            if style.get(S+'name') == 'Default' and style.get(S+'family') == 'table-cell':
                prop = style.find(S+'text-properties'); prop.set(FO+'font-family', 'MORIQ Definitely Missing Font 91F2'); prop.set(S+'font-name', 'MORIQ Definitely Missing Font 91F2'); return
        raise AssertionError('Default style missing')
    mutate_package(ods, 'styles.xml', missing)
    unavailable = convert_ods(ods, base/'missing'); before = unavailable.read_bytes(); correct(ods, unavailable)
    # Freeze metadata can independently be preserved, so compare style and columns, not whole ZIP bytes.
    with ZipFile(unavailable) as z:
        styles_after = z.read('xl/styles.xml'); sheet_after = z.read('xl/worksheets/sheet1.xml')
    original = base/'missing-before.xlsx'; original.write_bytes(before)
    with ZipFile(original) as z:
        # Cell fonts may still be restored by name, including an unavailable
        # font, but width correction must leave the Normal font unchanged.
        ns = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
        oldfont = ET.fromstring(z.read('xl/styles.xml')).find(ns+'fonts')[0]
        newfont = ET.fromstring(styles_after).find(ns+'fonts')[0]
        assert ET.tostring(oldfont) == ET.tostring(newfont)
        def cols(data):
            root = ET.fromstring(data); ns = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
            el = root.find(ns+'cols'); return [(x.get('min'),x.get('max'),x.get('width')) for x in el] if el is not None else []
        assert cols(z.read('xl/worksheets/sheet1.xml')) == cols(sheet_after)
    print('PASS missing font leaves Normal font and widths unchanged', flush=True)
