#!/usr/bin/env python3
"""Offline, read-only checks of the app's known bundled runtime dependencies."""
import argparse
import hashlib
import re
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile
import zlib

BINARIES = {
 'Contents/MacOS/MORIQ': {'arm64', 'x86_64'},
 'Contents/Resources/ffmpeg': {'arm64', 'x86_64'},
 'Contents/Resources/SpeechEngine/moriq-speech': {'arm64', 'x86_64'},
 'Contents/Resources/Pandoc/pandoc-arm64': {'arm64'},
 'Contents/Resources/Pandoc/pandoc-x86_64': {'x86_64'},
 'Contents/Resources/OfficeEngine/jre-arm64/bin/java': {'arm64'},
 'Contents/Resources/OfficeEngine/jre-x86_64/bin/java': {'x86_64'},
 'Contents/Resources/OfficeSuite/LibreOffice-arm64.app/Contents/MacOS/soffice': {'arm64'},
 'Contents/Resources/OfficeSuite/LibreOffice-x86_64.app/Contents/MacOS/soffice': {'x86_64'},
}
FILES = [
 'Contents/Resources/WhaleBackground.html',
 'Contents/Resources/SpeechEngine/LICENSE.whisper.cpp',
 'Contents/Resources/SpeechEngine/LICENSE.whisper-model',
 'Contents/Resources/SpeechEngine/ggml-base.bin',
 'Contents/Resources/SpeechEngine/README.md',
 'Contents/Resources/SpeechEngine/main.cpp',
 'Contents/Resources/THIRD_PARTY_NOTICES.md',
 'Contents/Resources/Vortex-LICENSE.txt',
 'Contents/Resources/Pandoc/LICENSE.txt',
 'Contents/Resources/Pandoc/PROVENANCE.txt',
 'Contents/Resources/OfficeEngine/CONVERTER-LICENSE',
 'Contents/Resources/OfficeEngine/jre-arm64/NOTICE',
 'Contents/Resources/OfficeEngine/jre-x86_64/NOTICE',
 'Contents/Resources/OfficeSuite/LibreOffice-arm64.app/Contents/Resources/LICENSE',
 'Contents/Resources/OfficeSuite/LibreOffice-x86_64.app/Contents/Resources/LICENSE',
 'Contents/Resources/licenses/FFmpeg-LGPL-2.1.txt',
]
JARS = ['Contents/Resources/OfficeEngine/converter.jar',
        'Contents/Resources/OfficeEngine/sheet-view-preserver.jar']

def read_arches(path):
    result = subprocess.run(['lipo', '-archs', str(path)], check=True, capture_output=True, text=True)
    return set(result.stdout.split())

def read_minimum(path, arch):
    result=subprocess.run(['otool','-l','-arch',arch,str(path)],check=True,capture_output=True,text=True)
    match=re.search(r'cmd LC_BUILD_VERSION\b(?:(?!\n\s*cmd ).)*?\bminos (\d+(?:\.\d+)*)',result.stdout,re.S)
    if not match: raise ValueError('missing minimum version')
    return tuple(map(int,match.group(1).split('.')))

def check(app, arch_reader=read_arches, min_reader=read_minimum):
    app = Path(app)
    failures=[]
    for relative, expected in BINARIES.items():
        path=app/relative
        if not path.is_file() or not os.access(path, os.X_OK):
            failures.append(f'缺少可执行文件：{relative}'); continue
        try: actual=arch_reader(path)
        except (OSError, subprocess.CalledProcessError, ValueError):
            failures.append(f'无法检查架构：{relative}'); continue
        if not expected.issubset(actual): failures.append(f'架构不完整：{relative}，需 {sorted(expected)}，实际 {sorted(actual)}')
    for relative in FILES:
        if not (app/relative).is_file(): failures.append(f'缺少资源或许可：{relative}')
    for relative in JARS:
        try:
            with zipfile.ZipFile(app/relative) as jar:
                if not jar.namelist() or jar.testzip() is not None: raise zipfile.BadZipFile('empty or corrupt')
        except (OSError, zipfile.BadZipFile, EOFError, RuntimeError, NotImplementedError, zlib.error): failures.append(f'JAR 缺失或损坏：{relative}')
    try:
        with (app/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
        if not isinstance(info, dict) or not all(info.get(k) for k in ('CFBundleIdentifier','CFBundleVersion','LSMinimumSystemVersion')):
            failures.append('Info.plist 缺少标识、构建号或最低系统版本')
    except (OSError, plistlib.InvalidFileException, ValueError): failures.append('Info.plist 缺失或损坏')
    try:
        minimum=tuple(map(int,info['LSMinimumSystemVersion'].split('.')))
        for arch in ('arm64','x86_64'):
            if min_reader(app/'Contents/Resources/SpeechEngine/moriq-speech',arch) > minimum+(0,)*(3-len(minimum)):
                failures.append(f'字幕引擎 {arch} 最低系统版本高于应用')
    except (OSError, subprocess.CalledProcessError, ValueError, TypeError, KeyError, UnboundLocalError, AttributeError):
        failures.append('无法检查字幕引擎最低系统版本')
    model=app/'Contents/Resources/SpeechEngine/ggml-base.bin'
    try:
        with model.open('rb') as f:
            checksum=hashlib.sha256()
            for chunk in iter(lambda: f.read(1024*1024),b''): checksum.update(chunk)
            digest=checksum.hexdigest()
        if model.stat().st_size != 147951465 or digest != '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe':
            failures.append('字幕模型大小或 SHA-256 不正确')
    except OSError: failures.append('无法校验字幕模型')
    return failures

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    app=parser.parse_args().app
    if not app.is_dir(): print('失败：应用目录不存在。',file=sys.stderr); return 1
    errors=check(app)
    for item in errors: print('失败：'+item,file=sys.stderr)
    if errors: print(f'依赖体检未通过：{len(errors)} 项。',file=sys.stderr); return 1
    print('已通过已知随包文件、JAR 完整性和双架构基础检查。')
    print('未验证签名公证、许可义务、动态库全部依赖、真实转换或 Intel 实机。')
    return 0
if __name__=='__main__': sys.exit(main())
