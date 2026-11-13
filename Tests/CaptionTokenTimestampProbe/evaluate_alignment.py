#!/usr/bin/env python3
"""Exploratory alignment with public composite-clip coarse speaker labels.

Thresholds are experimental arguments, NOT product recommendations. The
reference marks whole source clips, not manual word-level ground truth. Speaker
ID mapping is oracle-optimized on the same recording and is optimistic.
"""
import argparse
import itertools
import json
from collections import defaultdict
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--words',type=Path,required=True)
p.add_argument('--turns',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True)
p.add_argument('--minimum',type=float,required=True)
p.add_argument('--maximum-other',type=float,required=True)
a=p.parse_args()
assert 0 <= a.maximum_other < a.minimum <= 1
hyp=json.loads(a.words.read_text()); ref=json.loads(a.reference.read_text()); diar=json.loads(a.turns.read_text())
rate=hyp['sampleRate']; assert rate==16000
words=[w for window in hyp['windows'] if window['final'] for w in window['words']]
refs=[(int(round(s['start']*rate)),int(round(s['end']*rate)),s['speaker']) for s in ref]
turns=[(int(round(s['startTimeSeconds']*rate)),int(round(s['endTimeSeconds']*rate)),s['speaker']) for s in diar['segments']]

def coverage(start,end,regions):
    per=defaultdict(list)
    for lo,hi,name in regions:
        lo=max(lo,start); hi=min(hi,end)
        if hi>lo: per[name].append((lo,hi))
    result={}
    for name,segments in per.items():
        merged=[]
        for lo,hi in sorted(segments):
            if merged and lo<=merged[-1][1]: merged[-1]=(merged[-1][0],max(merged[-1][1],hi))
            else: merged.append((lo,hi))
        result[name]=sum(hi-lo for lo,hi in merged)/(end-start)
    return result

def classify(start,end,regions):
    if end<=start: return None
    ranked=sorted(coverage(start,end,regions).items(),key=lambda x:x[1],reverse=True)
    if not ranked or ranked[0][1]<a.minimum or any(score>=a.maximum_other for _,score in ranked[1:]): return None
    return ranked[0][0]

pairs=[(classify(w['start'],w['end'],refs),classify(w['start'],w['end'],turns)) for w in words]
source=sorted({x for x,y in pairs if x is not None}); predicted=sorted({y for x,y in pairs if y is not None})
assert len(source)==2 and len(predicted)==2
mapping=max((dict(zip(predicted,perm)) for perm in itertools.permutations(source)),key=lambda m:sum(x==m.get(y) for x,y in pairs if x is not None and y is not None))
no_reference=sum(x is None for x,y in pairs)
no_match=sum(x is not None and y is None for x,y in pairs)
correct=sum(x is not None and y is not None and x==mapping[y] for x,y in pairs)
wrong=sum(x is not None and y is not None and x!=mapping[y] for x,y in pairs)
assert len(words)==no_reference+no_match+correct+wrong
print(f'final_word_hypotheses={len(words)} reference_unmatched={no_reference} speaker_unmatched={no_match} matched_correct={correct} matched_wrong={wrong}')
print('Reference = coarse clip-level speaker, not human word timings; IDs optimistically remapped on same audio; overlapping-window duplicates remain.')
print('No diarization accuracy, production threshold, real-time latency, speaker identity, or word timestamp accuracy claimed.')
