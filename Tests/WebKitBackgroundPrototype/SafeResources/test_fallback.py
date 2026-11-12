from pathlib import Path
from tempfile import TemporaryDirectory
from fallback import prepare_or_copy_baseline
with TemporaryDirectory(prefix='moriq-safe-fallback-') as tmp:
    root=Path(tmp);source=root/'source.html';baseline=root/'baseline.docx';output=root/'result.docx'
    source.write_text('<html><body><img src="missing.png">保留文字</body></html>')
    baseline.write_bytes(b'REPRESENTATIVE-BASELINE-DOCX-CONTENT')
    before=source.read_bytes(),baseline.read_bytes()
    result=prepare_or_copy_baseline(source,baseline,output)
    assert result['html'] is None and result['published'] and '背景可能丢失' in result['notice']
    assert output.read_bytes()==baseline.read_bytes() and before==(source.read_bytes(),baseline.read_bytes())
    output.write_bytes(b'EXISTING')
    try:prepare_or_copy_baseline(source,baseline,output)
    except FileExistsError:pass
    else:raise AssertionError('overwrote existing output')
    assert output.read_bytes()==b'EXISTING'
print('PASS unsupported resources explicitly fall back to existing baseline without changing source or overwriting')
