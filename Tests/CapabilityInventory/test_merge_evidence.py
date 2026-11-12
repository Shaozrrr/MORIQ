#!/usr/bin/env python3
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory

path = Path(__file__).with_name('merge_evidence.py')
spec = importlib.util.spec_from_file_location('evidence', path)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

def row(category, source, target):
    return {'category': category, 'input': source, 'target': target,
            'status': 'declared_conditional_not_verified', 'condition': 'fixture only'}

with TemporaryDirectory(prefix='moriq-evidence-test-') as temp:
    root = Path(temp)
    audio = root / 'audio.log'; video = root / 'video.log'
    audio.write_text('PASS wav->mp3\nNOT_OFFERED aifc->flac: precision protection\nAUDIO_MATRIX passed=1 failed=0\n')
    video.write_text('PASS mov->mp4\nFAIL mov->flv: failed\nPASS_AUDIO mov->mp3\nPASS gif->mp4\nVIDEO_MATRIX passed=2 failed=1 audio_passed=1 audio_failed=0\n')
    inventory = {'schema': 1, 'pairs': [row('audio', 'wav', 'mp3'), row('audio', 'aifc', 'flac'),
                  row('video', 'mov', 'mp4'), row('video', 'mov', 'flv'), row('video_to_audio', 'mov', 'mp3'),
                  row('animated_image', 'gif', 'mp4'), row('pdf', 'pdf', 'txt')]}
    result = module.merge(inventory, audio, video)
    assert result['counts'] == {'fixture_fail': 1, 'fixture_pass': 4, 'not_offered_for_test_fixture': 1}
    assert not result['unmatched_observations']
    assert all(r['status'] == 'declared_conditional_not_verified' for r in result['pairs'])
    assert not next(r for r in result['pairs'] if r['category'] == 'pdf')['synthetic_observations']
    assert next(r for r in result['pairs'] if r['input'] == 'gif')['synthetic_observations'][0]['result'] == 'fixture_pass'
    video.write_text('PASS mov->mp4\n')
    try: module.merge(inventory, audio, video)
    except ValueError: pass
    else: raise AssertionError('truncated log accepted')
    video.write_text('PASS mov->mp4\nPASS mov->mp4\nVIDEO_MATRIX passed=2 failed=0 audio_passed=0 audio_failed=0\n')
    try: module.merge(inventory, audio, video)
    except ValueError: pass
    else: raise AssertionError('duplicate pair accepted')
print('PASS evidence join, conditional exclusion, failures, GIF category, unknowns and truncated/duplicate rejection')
