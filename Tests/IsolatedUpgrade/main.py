#!/usr/bin/env python3
"""Test package transactions under a disposable directory, without launching an app."""
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

candidate = pathlib.Path(sys.argv[1]).resolve(strict=True)

def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''): h.update(chunk)
    return h.hexdigest()

def plist(app):
    with open(app / 'Contents/Info.plist', 'rb') as f: return plistlib.load(f)

def signature(app):
    run('codesign', '--verify', '--deep', '--strict', str(app))
    result = subprocess.run(['codesign', '-dv', '--verbose=2', str(app)], check=True, capture_output=True, text=True).stderr
    def find(prefix):
        return next(line[len(prefix):] for line in result.splitlines() if line.startswith(prefix))
    return find('Identifier='), find('TeamIdentifier='), find('Authority=')

# A changing source would invalidate any conclusion about a staged candidate.
critical = ['Contents/Info.plist', 'Contents/MacOS/MORIQ', 'Contents/MacOS/MORIQ.debug.dylib', 'Contents/Resources/ffmpeg']
source_hash = {name: digest(candidate / name) for name in critical}
new_id, team, authority = signature(candidate)
new_plist = plist(candidate)
assert new_id == new_plist['CFBundleIdentifier'] and team != 'not set'
assert new_plist['CFBundleVersion'] != '1', 'test requires the candidate build number to differ from the fixture old version'
with tempfile.TemporaryDirectory(prefix='moriq-upgrade-isolated-') as temp:
    root = pathlib.Path(temp)
    old = root / 'MORIQ.app'
    (old / 'Contents/MacOS').mkdir(parents=True)
    shutil.copyfile('/usr/bin/true', old / 'Contents/MacOS/fixture')
    (old / 'Contents/MacOS/fixture').chmod(0o755)
    with open(old / 'Contents/Info.plist', 'wb') as f:
        plistlib.dump({'CFBundleIdentifier': new_id, 'CFBundleExecutable': 'fixture', 'CFBundleName': 'MORIQ fixture', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1'}, f)
    run('codesign', '--force', '--sign', authority, str(old))
    old_sig = signature(old)
    assert old_sig[:2] == (new_id, team)
    old_hash = digest(old / 'Contents/MacOS/fixture')
    staged = root / 'candidate.app'
    run('ditto', str(candidate), str(staged))
    assert signature(staged)[:2] == (new_id, team)
    assert plist(staged)['CFBundleVersion'] == new_plist['CFBundleVersion']
    assert all(digest(staged / name) == value and digest(candidate / name) == value for name, value in source_hash.items())
    print('PASS staged complete candidate preserves signature, version and key resource hashes', flush=True)
    # Corruption must be detected before the current package is swapped.
    info = staged / 'Contents/Info.plist'
    with open(info, 'ab') as f: f.write(b'\n')
    bad = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], capture_output=True)
    assert bad.returncode != 0 and signature(old) == old_sig and digest(old / 'Contents/MacOS/fixture') == old_hash
    print('PASS invalid staged signature leaves existing fixture intact', flush=True)
    shutil.rmtree(staged)
    run('ditto', str(candidate), str(staged))
    assert signature(staged)[:2] == (new_id, team)
    assert all(digest(staged / name) == value and digest(candidate / name) == value for name, value in source_hash.items())
    backup = root / 'previous.app'
    # Inject failure between taking the backup and publishing the candidate.
    try:
        os.replace(old, backup)
        raise RuntimeError('injected failure after backup')
    except RuntimeError:
        if backup.exists(): os.replace(backup, old)
    assert signature(old) == old_sig and digest(old / 'Contents/MacOS/fixture') == old_hash
    print('PASS injected failure restores previous fixture', flush=True)
    os.replace(old, backup)
    try:
        os.replace(staged, old)
        assert signature(old)[:2] == (new_id, team)
        assert plist(old)['CFBundleVersion'] == new_plist['CFBundleVersion']
        assert all(digest(old / name) == value for name, value in source_hash.items())
    except BaseException:
        if old.exists(): shutil.rmtree(old)
        os.replace(backup, old)
        raise
    print('PASS upgraded isolated fixture with verified candidate', flush=True)
    # Roll back without reading or touching the real installed app or data.
    os.replace(old, staged)
    os.replace(backup, old)
    assert signature(old) == old_sig and plist(old)['CFBundleVersion'] == '1'
    assert digest(old / 'Contents/MacOS/fixture') == old_hash
    print('PASS rollback restores old signed fixture and version', flush=True)
print('PASS all temporary copies removed; installed app and user data were not touched', flush=True)
