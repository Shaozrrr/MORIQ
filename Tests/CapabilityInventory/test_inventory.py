#!/usr/bin/env python3
"""Exercise the declaration inventory against a candidate bundle; no user files."""
import json, subprocess, sys
from collections import Counter
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit('usage: python3 Tests/CapabilityInventory/test_inventory.py <MORIQ.app>')
root = Path(__file__).resolve().parents[2]
script = root / 'Tests/CapabilityInventory/run.sh'
result = subprocess.run(['sh', str(script), str(Path(sys.argv[1]).resolve())], capture_output=True, text=True, timeout=120, check=True)
data = json.loads(result.stdout)
assert data['schema'] == 1 and data['architecture'] in ('arm64', 'x86_64')
rows = data['pairs']; assert rows
keys = [(r['category'], r['input'], r['target']) for r in rows]
assert len(keys) == len(set(keys)), 'duplicate rows'
assert keys == sorted(keys), 'unstable ordering'
assert all(r['status'] == 'declared_conditional_not_verified' and r['condition'] for r in rows)
assert all(r['input'] != r['target'] for r in rows)
assert {'zip', 'tar', 'tar.gz'} == set(data['archive_targets'])
assert ('pdf','pdf','png') in keys and ('pdf','pdf','jpeg') in keys
assert ('multipage_tiff','tiff','png') in keys
if data['engines']['ffmpeg_effective']:
    assert ('pdf','pdf','webp') in keys and ('multipage_tiff','tiff','webp') in keys
    assert any(r['category'] == 'video' for r in rows)
else:
    assert not any(r['category'] in ('animated_image','video_to_audio') for r in rows)
print('PASS inventory JSON, deterministic ordering, conditional status, no duplicate/same-extension pairs, and engine gates')
print('Declared conditional rows:', len(rows), '; category counts:', dict(sorted(Counter(r['category'] for r in rows).items())))
