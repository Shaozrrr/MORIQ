"""Atomic fallback policy for isolated marker-mapping experiments only."""
import importlib.util
import os
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory

spec=importlib.util.spec_from_file_location('mapping',Path(__file__).parent/'map_docx.py')
mapper=importlib.util.module_from_spec(spec);spec.loader.exec_module(mapper)

def convert_with_fallback(marked_docx:Path, manifest:Path, baseline_docx:Path, output:Path):
    if not baseline_docx.is_file(): raise ValueError('baseline output unavailable')
    output.parent.mkdir(parents=True,exist_ok=True)
    with TemporaryDirectory(prefix='.moriq-map-',dir=output.parent) as directory:
        candidate=Path(directory)/'result.docx'
        try:
            mapper.run(marked_docx,manifest,candidate)
            message='实验映射完成；请检查背景及版式'
        except (ValueError,KeyError,TypeError,OSError):
            shutil.copyfile(baseline_docx,candidate)
            message='部分元素背景未能保留，已保留普通转换结果；请检查版式'
        # Publish only a finished file, and never overwrite an existing result.
        os.link(candidate,output)
        return message
