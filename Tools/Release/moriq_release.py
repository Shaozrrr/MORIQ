#!/usr/bin/env python3
"""Build, sign and package locally. This tool never submits or publishes anything."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / 'MORIQ.xcodeproj'
ENTITLEMENTS = ROOT / 'MORIQ' / 'MORIQ.entitlements'

class ReleaseError(Exception): pass

def run(args, *, capture=False):
    try:
        p = subprocess.run([str(a) for a in args], check=True, text=True,
                           stdout=subprocess.PIPE if capture else None,
                           stderr=subprocess.PIPE if capture else None)
        return (p.stdout or '') + (p.stderr or '')
    except subprocess.CalledProcessError as e:
        raise ReleaseError(f'命令失败 ({e.returncode}): {args[0]}') from e
    except OSError as e:
        raise ReleaseError(f'无法执行 {args[0]}: {e.strerror}') from e

def identity_check(identity, runner=run):
    if not identity.startswith('Developer ID Application: '):
        raise ReleaseError('必须提供 Developer ID Application 证书名称，不能使用开发证书或 ad-hoc 签名。')
    listing = runner(['security', 'find-identity', '-v', '-p', 'codesigning'], capture=True)
    identities = re.findall(r'\"([^\"]+)\"', listing)
    if identity not in identities:
        raise ReleaseError('找不到匹配的有效 Developer ID Application 签名身份。')
    return identity

def safe_new_dir(raw):
    path = Path(raw).expanduser().absolute()
    if path.exists() or path.is_symlink(): raise ReleaseError(f'输出路径已存在：{path}')
    resolved = path.resolve()
    for forbidden in (Path('/Applications'), Path.home() / 'Applications', ROOT):
        if resolved == forbidden.resolve() or forbidden.resolve() in resolved.parents:
            raise ReleaseError('输出目录不能位于应用安装目录或项目源码目录。')
    path.mkdir(parents=True, exist_ok=False)
    return path

def assert_universal(app, runner=run):
    binary = app / 'Contents/MacOS/MORIQ'
    arches = set(runner(['lipo', '-archs', binary], capture=True).split())
    if not {'arm64', 'x86_64'} <= arches: raise ReleaseError(f'应用不是双架构：{sorted(arches)}')

def require_universal_binary(path, runner=run):
    arches = set(runner(['lipo', '-archs', path], capture=True).split())
    if not {'arm64', 'x86_64'} <= arches:
        raise ReleaseError(f'辅助程序不是双架构：{path} ({sorted(arches)})')

def require_system_dylibs(path, runner=run):
    output = runner(['otool', '-L', path], capture=True)
    libraries = []
    for line in output.splitlines():
        if line.startswith((' ', '\t')) and ' (compatibility version ' in line:
            libraries.append(line.strip().split(' (compatibility version ', 1)[0])
    if not libraries or any(not (item.startswith('/usr/lib/') or item.startswith('/System/Library/')) for item in libraries):
        raise ReleaseError(f'辅助程序含未核对的非系统动态依赖：{path}')

def require_speech_resources(res, minimum, runner=run):
    speech = res / 'SpeechEngine/moriq-speech'
    try:
        required = tuple(int(v) for v in minimum.split('.'))
        if not required: raise ValueError()
    except (AttributeError, ValueError):
        raise ReleaseError('应用缺少有效的最低系统版本。')
    for arch in ('arm64', 'x86_64'):
        output = runner(['otool', '-l', '-arch', arch, speech], capture=True)
        match = re.search(r'cmd LC_BUILD_VERSION\b(?:(?!\n\s*cmd ).)*?\bminos (\d+(?:\.\d+)*)', output, re.S)
        if not match or tuple(map(int, match.group(1).split('.'))) > required + (0,) * (3-len(required)):
            raise ReleaseError(f'字幕引擎 {arch} 最低系统版本不兼容：{minimum}')
    model = res / 'SpeechEngine/ggml-base.bin'
    license_file = res / 'SpeechEngine/LICENSE.whisper-model'
    if not model.is_file() or not license_file.is_file() or model.stat().st_size != 147951465:
        raise ReleaseError('缺少字幕模型或模型许可，或模型大小不正确。')
    with model.open('rb') as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''): digest.update(chunk)
        digest = digest.hexdigest()
    if digest != '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe':
        raise ReleaseError('字幕模型校验失败。')

def require_developer_signature(path, runner=run):
    runner(['codesign', '--verify', '--strict', path])
    desc = runner(['codesign', '-dv', '--verbose=4', path], capture=True)
    if 'Authority=Developer ID Application:' not in desc or 'runtime' not in desc or 'Timestamp=' not in desc:
        raise ReleaseError(f'嵌套组件缺少 Developer ID、加固运行时或可信时间戳：{path}')

def build(out):
    output = safe_new_dir(out)
    derived = output / 'derived'
    run(['xcodebuild', '-project', PROJECT, '-scheme', 'MORIQ', '-configuration', 'Release',
         '-derivedDataPath', derived, 'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO',
         'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO', 'build'])
    app = derived / 'Build/Products/Release/MORIQ.app'
    if not app.is_dir(): raise ReleaseError('未找到构建产物。')
    assert_universal(app)
    print('本地双架构未签名构建完成:', app)
    print('尚未签名、公证或发布。')

def sign(app_path, out, identity, version, build_number):
    identity_check(identity)
    if not re.fullmatch(r'\d+(?:\.\d+){1,2}', version) or not re.fullmatch(r'[1-9]\d*', build_number):
        raise ReleaseError('版本须为数字形式（如 1.2.0），构建号须为正整数。')
    source = Path(app_path).expanduser().resolve(strict=True)
    if source.name != 'MORIQ.app' or not source.is_dir(): raise ReleaseError('输入必须是 MORIQ.app 构建产物。')
    assert_universal(source)
    output = safe_new_dir(out)
    dest = output / 'MORIQ.app'
    run(['ditto', source, dest])
    info = dest / 'Contents/Info.plist'
    with info.open('rb') as f: metadata = plistlib.load(f)
    metadata['CFBundleShortVersionString'] = version; metadata['CFBundleVersion'] = build_number
    with info.open('wb') as f: plistlib.dump(metadata, f, fmt=plistlib.FMT_XML, sort_keys=False)
    res = dest / 'Contents/Resources'
    # FFmpeg is built by this project and currently ad-hoc signed. Other vendor
    # binaries retain their own signatures; do not use --deep as a signer.
    ffmpeg = res / 'ffmpeg'
    if not ffmpeg.is_file(): raise ReleaseError('缺少随包 FFmpeg。')
    speech = res / 'SpeechEngine/moriq-speech'
    license_file = res / 'SpeechEngine/LICENSE.whisper.cpp'
    source_file = res / 'SpeechEngine/main.cpp'
    if not speech.is_file() or not license_file.is_file() or not source_file.is_file():
        raise ReleaseError('缺少字幕引擎、许可或辅助程序源码。')
    require_universal_binary(speech)
    require_system_dylibs(speech)
    require_speech_resources(res, metadata.get('LSMinimumSystemVersion'))
    for helper in (ffmpeg, speech):
        run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', helper])
    required = [ffmpeg, speech,
        res/'Pandoc/pandoc-arm64', res/'Pandoc/pandoc-x86_64',
        res/'OfficeEngine/jre-arm64/bin/java', res/'OfficeEngine/jre-x86_64/bin/java',
        res/'OfficeSuite/LibreOffice-arm64.app', res/'OfficeSuite/LibreOffice-x86_64.app']
    for item in required:
        if not item.exists(): raise ReleaseError(f'缺少依赖：{item}')
        require_developer_signature(item)
    run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp',
         '--entitlements', ENTITLEMENTS, dest])
    run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', dest])
    require_developer_signature(dest)
    assert_universal(dest)
    print('已生成本地签名候选:', dest)
    print('尚未公证或发布；仍需检查全部嵌套代码、许可及实际机器运行。')

def package(app_path, out, identity):
    identity_check(identity)
    app = Path(app_path).expanduser().resolve(strict=True)
    if app.name != 'MORIQ.app': raise ReleaseError('输入必须是签名后的 MORIQ.app。')
    assert_universal(app); require_developer_signature(app)
    run(['codesign', '--verify', '--deep', '--strict', app])
    output = safe_new_dir(out)
    dmg = output / 'MORIQ.dmg'
    with tempfile.TemporaryDirectory(prefix='moriq-dmg-', dir=output) as tmp:
        staging = Path(tmp)
        run(['ditto', app, staging / 'MORIQ.app'])
        os.symlink('/Applications', staging / 'Applications')
        run(['hdiutil', 'create', '-fs', 'HFS+', '-format', 'UDZO', '-volname', 'MORIQ', '-srcfolder', staging, dmg])
    run(['codesign', '--sign', identity, '--timestamp', dmg])
    run(['codesign', '--verify', '--strict', dmg])
    print('已生成本地 DMG:', dmg)
    print('尚未公证、上传或发布。')

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('preflight'); p.add_argument('--identity', required=True)
    p = sub.add_parser('build'); p.add_argument('--out', required=True)
    p = sub.add_parser('sign'); p.add_argument('--app', required=True); p.add_argument('--out', required=True); p.add_argument('--identity', required=True); p.add_argument('--version', required=True); p.add_argument('--build-number', required=True)
    p = sub.add_parser('package'); p.add_argument('--app', required=True); p.add_argument('--out', required=True); p.add_argument('--identity', required=True)
    a = parser.parse_args(argv)
    try:
        if a.command == 'preflight': identity_check(a.identity); print('找到有效证书；这不代表可公证或可发行。')
        elif a.command == 'build': build(a.out)
        elif a.command == 'sign': sign(a.app, a.out, a.identity, a.version, a.build_number)
        else: package(a.app, a.out, a.identity)
    except (ReleaseError, FileNotFoundError, PermissionError, plistlib.InvalidFileException, OSError) as e:
        print(f'失败：{e}', file=sys.stderr); return 1
    return 0

if __name__ == '__main__': sys.exit(main())
