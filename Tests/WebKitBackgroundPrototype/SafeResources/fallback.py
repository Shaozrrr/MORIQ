"""Synthetic fail-closed policy with an already-created baseline DOCX.
Not integrated with MORIQ; this does not create or validate the baseline.
"""
import os
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory
from prepare import prepare

def prepare_or_copy_baseline(source:Path, baseline:Path, output:Path):
    result=prepare(source)
    if result['html'] is not None: return {'html':result['html'],'notice':None,'published':False}
    if not baseline.is_file(): raise ValueError('ordinary conversion baseline unavailable')
    with TemporaryDirectory(prefix='.moriq-resource-',dir=output.parent) as work:
        temporary=Path(work)/'baseline.docx';shutil.copyfile(baseline,temporary)
        os.link(temporary,output)  # no overwrite; temporary directory cleaned on exit
    return {'html':None,'notice':'网页资源或样式不支持；已保留普通转换结果，背景可能丢失','published':True}
