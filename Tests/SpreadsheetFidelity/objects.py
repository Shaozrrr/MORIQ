from pathlib import Path
from tempfile import TemporaryDirectory
from subprocess import run
from os import environ
from openpyxl import Workbook, load_workbook
from openpyxl.chart import BarChart, Reference
from openpyxl.comments import Comment
from openpyxl.worksheet.datavalidation import DataValidation

with TemporaryDirectory(prefix='moriq-sheet-objects-') as temp:
    root = Path(temp)
    book = Workbook(); sheet = book.active; sheet.title = '数据'
    sheet.append(['类别', '数值']); sheet.append(['甲', 10]); sheet.append(['乙', 20])
    sheet['A5'] = '官网'; sheet['A5'].hyperlink = 'https://example.com'
    sheet['B3'].comment = Comment('测试批注', 'MORIQ')
    validation = DataValidation(type='list', formula1='"甲,乙"')
    sheet.add_data_validation(validation); validation.add(sheet['D2'])
    chart = BarChart(); chart.add_data(Reference(sheet, min_col=2, min_row=1, max_row=3), titles_from_data=True)
    sheet.add_chart(chart, 'E2')
    hidden = book.create_sheet('隐藏'); hidden.sheet_state = 'hidden'; hidden['A1'] = '保留隐藏'
    source = root / 'budget.xlsx'; book.save(source); original = source.read_bytes()
    executable = Path(environ.get('MORIQ_SHEET_TEST_EXECUTABLE', '/tmp/moriq-sheet-fidelity-test')).resolve(strict=True)
    run([str(executable), temp], check=True, capture_output=True, timeout=120)
    result = load_workbook(root / 'xlsx/budget.xlsx'); sheet = result['数据']
    assert result.sheetnames == ['数据', '隐藏'] and result['隐藏'].sheet_state == 'hidden'
    assert result['隐藏']['A1'].value == '保留隐藏'
    assert sheet['A5'].hyperlink and sheet['A5'].hyperlink.target.rstrip('/') == 'https://example.com'
    assert sheet['B3'].comment and sheet['B3'].comment.text == '测试批注'
    assert len(sheet._charts) == 1 and len(sheet._charts[0].series) == 1
    assert len(sheet.data_validations.dataValidation) == 1 and 'D2' in str(sheet.data_validations.dataValidation[0].sqref)
    assert source.read_bytes() == original
    print('PASS spreadsheet roundtrip retains chart, hyperlink, comment, validation, hidden sheet and source')
