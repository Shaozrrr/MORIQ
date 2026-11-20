#!/usr/bin/env python3
"""Create a signed ARM-only candidate from an existing signed universal app.

This tool does not notarize, publish, or install the result.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from moriq_release import ReleaseError, identity_check, run, safe_new_dir

DROP = (
    'OfficeSuite/LibreOffice-x86_64.app',
    'OfficeEngine/jre-x86_64',
    'Pandoc/pandoc-x86_64',
)
KEEP = (
    'OfficeSuite/LibreOffice-arm64.app/Contents/MacOS/soffice',
    'OfficeEngine/jre-arm64/bin/java',
    'OfficeEngine/converter.jar',
    'OfficeEngine/sheet-view-preserver.jar',
    'Pandoc/pandoc-arm64',
    'ffmpeg',
    'SpeechEngine/moriq-speech',
    'SpeechEngine/ggml-base.bin',
)

def tree_manifest(root):
    """Hash regular files and compare symlink targets without following links."""
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            item = Path(directory)/name
            relative = str(item.relative_to(root))
            if item.is_symlink():
                result[relative] = ('link', os.readlink(item))
            elif item.is_file():
                digest = hashlib.sha256()
                with item.open('rb') as f:
                    for block in iter(lambda: f.read(1024 * 1024), b''):
                        digest.update(block)
                result[relative] = ('file', digest.hexdigest())
    return result

def prepare(source, out, identity, expected_build):
    identity_check(identity)
    src = Path(source).expanduser().resolve(strict=True)
    if src.name != 'MORIQ.app' or not src.is_dir():
        raise ReleaseError('输入必须是已签名的 MORIQ.app。')
    run(['codesign', '--verify', '--deep', '--strict', src])
    identity_team = re.search(r'\(([A-Z0-9]{10})\)$', identity)
    source_details = run(['codesign', '-dv', '--verbose=4', src], capture=True)
    source_team = re.search(r'^TeamIdentifier=(.+)$', source_details, re.M)
    if not identity_team or not source_team or source_team.group(1) != identity_team.group(1):
        raise ReleaseError('输入应用与签名身份的团队不一致。')
    with (src/'Contents/Info.plist').open('rb') as f:
        info = plistlib.load(f)
    if str(info.get('CFBundleVersion')) != expected_build:
        raise ReleaseError('输入构建号与预期不一致。')
    res = src/'Contents/Resources'
    for name in DROP + KEEP:
        item = res/name
        if not item.exists() or item.is_symlink():
            raise ReleaseError(f'依赖缺失或为符号链接：{name}')
    arches = set(run(['lipo', '-archs', src/'Contents/MacOS/MORIQ'], capture=True).split())
    if not {'arm64', 'x86_64'} <= arches:
        raise ReleaseError('输入应用不是完整双架构版本。')
    # Extract entitlements directly from the signed source, never invent them.
    p = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(src)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    entitlements = plistlib.loads(p.stdout)
    output = safe_new_dir(out)
    dest = output/'MORIQ.app'; dest.mkdir()
    exclusions = [f'--exclude=/Contents/Resources/{name}' for name in DROP]
    run(['rsync', '-aE', *exclusions, str(src)+'/', str(dest)+'/'])
    main = dest/'Contents/MacOS/MORIQ'; thin = output/'moriq-arm64'
    run(['lipo', '-thin', 'arm64', main, '-output', thin])
    thin.chmod(0o755); thin.replace(main)
    ent = output/'entitlements.plist'
    ent.write_bytes(plistlib.dumps(entitlements))
    run(['codesign', '--force', '--sign', identity, '--options', 'runtime',
         '--timestamp', '--entitlements', ent, dest])
    run(['codesign', '--verify', '--deep', '--strict', dest])
    if set(run(['lipo', '-archs', main], capture=True).split()) != {'arm64'}:
        raise ReleaseError('输出主程序不是单一 ARM 架构。')
    p = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(dest)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if plistlib.loads(p.stdout) != entitlements:
        raise ReleaseError('输出签名权限与输入不一致。')
    for name in KEEP:
        if not (dest/'Contents/Resources'/name).exists():
            raise ReleaseError(f'输出缺少依赖：{name}')
    for name in ('OfficeSuite/LibreOffice-arm64.app/Contents/MacOS/soffice', 'OfficeEngine/jre-arm64/bin/java', 'Pandoc/pandoc-arm64', 'ffmpeg', 'SpeechEngine/moriq-speech'):
        run(['lipo', '-verify_arch', 'arm64', dest/'Contents/Resources'/name])
    run(['codesign', '--verify', '--deep', '--strict', dest/'Contents/Resources/OfficeSuite/LibreOffice-arm64.app'])
    for name in ('OfficeSuite/LibreOffice-arm64.app', 'OfficeEngine/jre-arm64'):
        if tree_manifest(res/name) != tree_manifest(dest/'Contents/Resources'/name):
            raise ReleaseError(f'保留的依赖内容与输入不一致：{name}')
    for name in DROP:
        if (dest/'Contents/Resources'/name).exists():
            raise ReleaseError(f'输出仍含 Intel 专属依赖：{name}')
    print('ARM 候选已签名:', dest)
    print('源主程序 SHA-256:', hashlib.sha256((src/'Contents/MacOS/MORIQ').read_bytes()).hexdigest())
    print('尚未进行应用入口验收、公证或发布。')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True); parser.add_argument('--out', required=True)
    parser.add_argument('--identity', required=True); parser.add_argument('--expected-build', required=True)
    args = parser.parse_args()
    try: prepare(args.app, args.out, args.identity, args.expected_build)
    except (ReleaseError, OSError, ValueError, subprocess.CalledProcessError) as e:
        print('失败:', e, file=sys.stderr); sys.exit(1)
