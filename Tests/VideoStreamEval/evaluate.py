#!/usr/bin/env python3
"""Score explicit answers; no API calls. Unverifiable claims stay manual review."""
import argparse, json, re
from pathlib import Path

UNCERTAIN = re.compile(r'不确定|无法确定|不能确定|无法判断|不能判断|无法确认|看不到|没看到|未看到|无法看到|无法获知|无法得知|不清楚|不知道|不一定|未能判断|cannot determine|not sure|uncertain|not enough', re.I)
COMPARISON = re.compile(r'之前|此前|先前|原先|原来|后来|随后|相较|相比|对比|变成|变为|变更为|改为|变化|previous|earlier|compared|changed from', re.I)

def evaluate(manifest, responses):
    expected_ids = [case['id'] for case in manifest['cases']]
    if len(expected_ids) != len(set(expected_ids)): raise ValueError('duplicate case ids in manifest')
    by_id = {}
    for response in responses:
        key = response.get('id')
        if key not in expected_ids or key in by_id: raise ValueError('unknown or duplicate response id')
        by_id[key] = response
    results = []
    for case in manifest['cases']:
        item = by_id.get(case['id'])
        if item is None:
            results.append({'id':case['id'], 'status':'missing', 'reason':'no answer'}); continue
        answer = item.get('answer')
        if not isinstance(answer, str) or not answer.strip():
            results.append({'id':case['id'], 'status':'fail', 'reason':'empty answer'}); continue
        normalized = answer.upper()
        if any(value.upper() in normalized for value in case['forbidden']):
            results.append({'id':case['id'], 'status':'fail', 'reason':'forbidden content'}); continue
        if case['kind'] == 'unobservable':
            if UNCERTAIN.search(answer): results.append({'id':case['id'], 'status':'review', 'reason':'uncertainty detected; human must check no fabricated claim'})
            else: results.append({'id':case['id'], 'status':'fail', 'reason':'unsupported certainty'})
            continue
        expected = case.get('expected_any', [case['expected']])
        if not any(value.upper() in normalized for value in expected):
            results.append({'id':case['id'], 'status':'fail', 'reason':'expected content missing'}); continue
        if case['id'] == 'current_no_comparison' and COMPARISON.search(answer):
            results.append({'id':case['id'], 'status':'fail', 'reason':'unrequested comparison'}); continue
        results.append({'id':case['id'], 'status':'pass', 'reason':'literal checks passed; manual review still required'})
    return results

def main():
    p=argparse.ArgumentParser(); p.add_argument('manifest',type=Path); p.add_argument('responses',type=Path); p.add_argument('--output',type=Path)
    a=p.parse_args(); manifest=json.loads(a.manifest.read_text(encoding='utf-8')); answers=json.loads(a.responses.read_text(encoding='utf-8'))
    result=evaluate(manifest,answers); encoded=json.dumps(result,ensure_ascii=False,indent=2)+'\n'
    if a.output: a.output.write_text(encoded,encoding='utf-8')
    print(encoded, end='')
    return 1 if any(x['status'] in ('fail','missing') for x in result) else 0
if __name__ == '__main__': raise SystemExit(main())
