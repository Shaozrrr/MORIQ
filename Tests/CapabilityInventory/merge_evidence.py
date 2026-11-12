#!/usr/bin/env python3
"""Join explicitly supplied synthetic matrix logs to a declaration inventory.

The output never promotes a declaration to supported/accepted. Logs are
historical observations and may not match the inspected source or bundle.
"""
import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

LINE = re.compile(r'^(PASS_AUDIO|FAIL_AUDIO|NOT_OFFERED|PASS|FAIL) ([a-z0-9]+)->([a-z0-9]+)(?::.*)?$')
AUDIO_SUMMARY = re.compile(r'^AUDIO_MATRIX passed=(\d+) failed=(\d+)$')
VIDEO_SUMMARY = re.compile(r'^VIDEO_MATRIX passed=(\d+) failed=(\d+) audio_passed=(\d+) audio_failed=(\d+)$')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def observations(path, kind):
    raw = path.read_bytes()
    text = raw.decode('utf-8')
    found, totals, summaries = [], Counter(), []
    for line in text.splitlines():
        match = LINE.fullmatch(line)
        if match:
            result, source, target = match.groups()
            if kind == 'audio':
                if result in ('PASS_AUDIO', 'FAIL_AUDIO'):
                    raise ValueError('audio log contains video extraction marker')
                category = 'audio'
            elif result in ('PASS_AUDIO', 'FAIL_AUDIO'):
                category = 'video_to_audio'
            else:
                if result == 'NOT_OFFERED':
                    raise ValueError('unexpected video NOT_OFFERED record')
                category = 'animated_image' if source == 'gif' else 'video'
            status = ('not_offered_for_test_fixture' if result == 'NOT_OFFERED' else
                      'fixture_pass' if result.startswith('PASS') else 'fixture_fail')
            totals[result] += 1
            found.append({'category': category, 'input': source, 'target': target, 'result': status})
        summary = (AUDIO_SUMMARY if kind == 'audio' else VIDEO_SUMMARY).fullmatch(line)
        if summary:
            summaries.append(tuple(map(int, summary.groups())))
    if len(summaries) != 1:
        raise ValueError(f'{kind} log must contain exactly one completed summary')
    expected = ((totals['PASS'], totals['FAIL']) if kind == 'audio' else
                (totals['PASS'], totals['FAIL'], totals['PASS_AUDIO'], totals['FAIL_AUDIO']))
    if summaries[0] != expected:
        raise ValueError(f'{kind} log summary does not match records: {summaries[0]} != {expected}')
    return found, {'log_sha256': sha(raw), 'records': len(found), 'summary': list(summaries[0])}


def merge(inventory, audio_path, video_path):
    if inventory.get('schema') != 1 or not isinstance(inventory.get('pairs'), list):
        raise ValueError('unsupported inventory')
    rows = inventory['pairs']
    index = {}
    for row in rows:
        key = (row['category'], row['input'], row['target'])
        if key in index or row.get('status') != 'declared_conditional_not_verified':
            raise ValueError('duplicate or already-promoted inventory row')
        index[key] = {**row, 'synthetic_observations': []}
    metadata, unmatched = {}, []
    for kind, path in [('audio', audio_path), ('video', video_path)]:
        records, metadata[kind] = observations(path, kind)
        seen = set()
        for record in records:
            key = (record['category'], record['input'], record['target'])
            if key in seen:
                raise ValueError(f'duplicate observation in {kind}: {key}')
            seen.add(key)
            if key not in index:
                unmatched.append(record)
            else:
                index[key]['synthetic_observations'].append({'result': record['result'], 'source_log': kind})
    merged = [index[key] for key in sorted(index)]
    return {
        'schema': 1,
        'warning': 'Historical synthetic observations only; source, bundle and log revisions are not verified equal. No row is certified, and quality/real files/UI remain unverified.',
        'fixture_scope': {'audio': 'short synthetic audio; output basic decode; floating-point FLAC is conditionally excluded',
                          'video': 'short synthetic video; first video/audio frame decode and GIF frame count; no quality, full tracks, subtitle or synchronization claim'},
        'log_metadata': metadata,
        'counts': dict(sorted(Counter(o['result'] for row in merged for o in row['synthetic_observations']).items())),
        'unmatched_observations': unmatched,
        'pairs': merged,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--inventory', required=True, type=Path)
    parser.add_argument('--audio-log', required=True, type=Path)
    parser.add_argument('--video-log', required=True, type=Path)
    args = parser.parse_args()
    raw = args.inventory.read_bytes()
    result = merge(json.loads(raw), args.audio_log, args.video_log)
    result['inventory_sha256'] = sha(raw)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
