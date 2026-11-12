#!/usr/bin/env python3
"""Validate generator and scoring using only fabricated local data."""
import hashlib, json, tempfile
from pathlib import Path
from generate import generate
from evaluate import evaluate

with tempfile.TemporaryDirectory(prefix='moriq-video-eval-') as temp:
    root=Path(temp); generate(root)
    m=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
    assert len(m['cases']) == 6 and all(len(case['frames']) == 12 for case in m['cases'])
    for case in m['cases']:
        assert [f['at_ms'] for f in case['frames']] == list(range(0,3000,250))
        for frame in case['frames']:
            assert hashlib.sha256((root/frame['file']).read_bytes()).hexdigest() == frame['sha256']
    flash=next(c for c in m['cases'] if c['id']=='short_unobservable')
    # 1 FPS samples exactly at 0, 1000, 2000ms: a 250ms alert at 250ms is unseen.
    from generate import describe
    assert all(describe(flash['id'], n)[2] is None for n in (0,1,2))
    assert describe(flash['id'], 0.25)[2] == 'ALERT'
    answers=[{'id':c['id'],'answer': ('无法确定是否出现提示' if c['expected'] is None else c['expected'])} for c in m['cases']]
    scored=evaluate(m,answers)
    assert [x['status'] for x in scored] == ['pass','pass','pass','review','pass','pass']
    answers[2]['answer']='状态变成完成'; assert evaluate(m,answers)[2]['status']=='pass'
    answers[-1]['answer']='之前是 1275，现在是 6842'; assert evaluate(m,answers)[-1]['status']=='fail'
    assert evaluate(m,answers[:-1])[-1]['status']=='missing'
    try: evaluate(m,answers+[answers[0]])
    except ValueError: pass
    else: raise AssertionError('duplicate answers accepted')
    print('PASS synthetic generation, hashes, missed-event boundary, strict scoring and missing/duplicate cases')
from validate_trace import validate
trace=[{'type':'start','at_ms':0,'session':'one'},
       {'type':'capture','at_ms':0,'session':'one','frame':'a','origin':'synthetic'},
       {'type':'send','at_ms':100,'session':'one','frame':'a'},
       {'type':'capture','at_ms':1000,'session':'one','frame':'b','origin':'synthetic'},
       {'type':'send','at_ms':1100,'session':'one','frame':'b'},
       {'type':'disconnect','at_ms':1200}, {'type':'reconnect','at_ms':1300},
       {'type':'capture','at_ms':1400,'session':'one','frame':'c','origin':'synthetic'},
       {'type':'send','at_ms':1500,'session':'one','frame':'c'}, {'type':'stop','at_ms':1600}]
assert validate(trace)==[]
assert any('outside' in e for e in validate(trace+[{'type':'send','at_ms':1700,'session':'one','frame':'c'}]))
stale=trace[:2]+[{'type':'send','at_ms':1600,'session':'one','frame':'a'},{'type':'stop','at_ms':1700}]
assert any('stale' in e for e in validate(stale))
fast=trace[:3]+[{'type':'capture','at_ms':200,'session':'one','frame':'b','origin':'synthetic'}, {'type':'send','at_ms':300,'session':'one','frame':'b'}, {'type':'stop','at_ms':400}]
assert any('rate' in e for e in validate(fast))
assert any('without stop' in e for e in validate(trace[:-1]))
print('PASS trace validator detects post-close send, stale frame, rate limit and unclosed session')
