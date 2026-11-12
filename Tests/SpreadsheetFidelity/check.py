from pathlib import Path
from tempfile import TemporaryDirectory
from datetime import datetime
from subprocess import run
from os import environ
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill, Alignment

with TemporaryDirectory(prefix='moriq-sheet-fidelity-') as temp:
    root = Path(temp)
    book = Workbook(); sheet = book.active; sheet.title = '预算'
    sheet.merge_cells('A1:C1'); sheet['A1'] = '项目预算 MORIQ'; sheet['A1'].font = Font(bold=True, color='FF2059D9', size=16)
    sheet['A1'].fill = PatternFill('solid', fgColor='FFE6EEFF'); sheet['A1'].alignment = Alignment(horizontal='center')
    sheet.append(['项目', '单价', '数量']); sheet.append(['设计', 42.5, 3]); sheet.append(['开发', 80, 2])
    sheet['B5'] = '=SUM(B3:B4)'; sheet['C5'] = '=SUM(C3:C4)'; sheet['B3'].number_format = '0.00'
    sheet['A7'] = datetime(2026, 11, 11); sheet['A7'].number_format = 'yyyy-mm-dd'
    sheet.freeze_panes = 'B3'; sheet.column_dimensions['A'].width = 24
    other = book.create_sheet('备注'); other['A1'] = '第二页内容'; other['A2'] = "='预算'!B5"
    source = root / 'budget.xlsx'; book.save(source)
    # Resolve a convenience symlink before launching: macOS identifies the
    # executable's app bundle from argv[0], which locates packaged engines.
    executable = Path(environ.get('MORIQ_SHEET_TEST_EXECUTABLE', '/tmp/moriq-sheet-fidelity-test')).resolve(strict=True)
    result = run([str(executable), temp], capture_output=True, text=True, check=True)
    converted = load_workbook(root / 'xlsx/budget.xlsx', data_only=False)
    cached = load_workbook(root / 'xlsx/budget.xlsx', data_only=True)
    checks = {
        'cached_formula_values': cached['预算']['B5'].value == 122.5 and cached['备注']['A2'].value == 122.5,
        'sheet_names': converted.sheetnames == ['预算', '备注'],
        'merged_cells': 'A1:C1' in [str(x) for x in converted['预算'].merged_cells.ranges],
        'formula': converted['预算']['B5'].value == '=SUM(B3:B4)',
        'cross_sheet_formula': converted['备注']['A2'].value in ("='预算'!B5", '=预算!B5'),
        'bold': converted['预算']['A1'].font.bold is True,
        'fill': converted['预算']['A1'].fill.fgColor.rgb == 'FFE6EEFF',
        'number_format': '0.00' in converted['预算']['B3'].number_format,
        'date': converted['预算']['A7'].value == datetime(2026, 11, 11),
        'freeze_panes': converted['预算'].freeze_panes == 'B3',
        'column_width': abs(converted['预算'].column_dimensions['A'].width - 24) < 1,
        'pdf_created': (root / 'pdf/budget.pdf').stat().st_size > 0,
        'source_preserved': source.is_file(),
    }
    print('observed freeze:', repr(converted['预算'].freeze_panes), 'width:', repr(converted['预算'].column_dimensions['A'].width), 'default font:', repr(book._fonts[0].name), '→', repr(converted._fonts[0].name), 'formula values:', repr(cached['预算']['B5'].value), repr(cached['备注']['A2'].value))
    for key, passed in checks.items(): print(('PASS ' if passed else 'FAIL ') + key)
    if not all(checks.values()): raise SystemExit(1)
