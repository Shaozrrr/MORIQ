"""Rich text must stay intact while unrelated cell fonts are repaired."""
from os import environ
from pathlib import Path
from subprocess import run
from tempfile import TemporaryDirectory
from openpyxl import Workbook, load_workbook
from openpyxl.cell.rich_text import CellRichText, TextBlock
from openpyxl.cell.text import InlineFont
from openpyxl.styles import Font

exe = Path(environ['MORIQ_SHEET_TEST_EXECUTABLE']).resolve(strict=True)
office = Path(environ['MORIQ_SHEET_OFFICE']).resolve(strict=True)
with TemporaryDirectory(prefix='moriq-rich-font-') as temp:
    root = Path(temp)
    book = Workbook()
    book._fonts[0] = Font(name='Arial', size=11)
    book.active['A1'] = CellRichText('normal ', TextBlock(InlineFont(rFont='Arial', b=True), 'bold'))
    book.active['B1'] = '普通粗体'
    book.active['B1'].font = Font(name='Arial', size=11, bold=True)
    book.save(root / 'budget.xlsx')
    run([str(exe), str(root)], check=True, capture_output=True, timeout=120)
    baseline_dir = root / 'baseline'; baseline_dir.mkdir()
    run([str(office), '-env:UserInstallation=' + (root / 'profile').as_uri(), '--headless', '--convert-to', 'xlsx', '--outdir', str(baseline_dir), str(root / 'ods/budget.ods')], check=True, capture_output=True, timeout=60)
    result = load_workbook(root / 'xlsx/budget.xlsx', rich_text=True).active
    baseline = load_workbook(baseline_dir / 'budget.xlsx', rich_text=True).active
    assert repr(result['A1'].value) == repr(baseline['A1'].value)
    assert str(result['A1'].value) == 'normal bold'
    assert (result['B1'].font.name, result['B1'].font.bold) == ('Arial', True)
    print('PASS rich-text runs unchanged and ordinary cell font restored')
