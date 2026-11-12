#!/usr/bin/env python3
"""Validate an exported synthetic transport trace; never connects to a service."""
import argparse, json
from pathlib import Path

def validate(events, *, max_age_ms=1500, min_interval_ms=1000):
    errors=[]; active=False; connected=False; captures={}; last_at=-1; last_send=None; session=None
    for i, event in enumerate(events):
        kind=event.get('type'); at=event.get('at_ms')
        if not isinstance(at, int) or at < 0 or at < last_at:
            errors.append(f'{i}: invalid or nonmonotonic timestamp'); continue
        last_at=at
        if kind=='start':
            if active: errors.append(f'{i}: duplicate start')
            active=True; connected=True; captures={}; last_send=None; session=event.get('session')
            if not isinstance(session,str) or not session: errors.append(f'{i}: missing session')
        elif kind=='capture':
            frame=event.get('frame'); frame_session=event.get('session')
            if not active or frame_session != session or event.get('origin') != 'synthetic': errors.append(f'{i}: unauthorized capture')
            elif not isinstance(frame,str) or not frame or frame in captures: errors.append(f'{i}: invalid or duplicate frame')
            else: captures[frame]=at
        elif kind=='send':
            frame=event.get('frame')
            if not active or not connected or event.get('session') != session: errors.append(f'{i}: send outside connected session')
            elif frame not in captures: errors.append(f'{i}: unrecognized frame')
            elif at - captures[frame] > max_age_ms: errors.append(f'{i}: stale frame')
            if last_send is not None and at-last_send < min_interval_ms: errors.append(f'{i}: rate exceeded')
            last_send=at
        elif kind=='disconnect': connected=False; captures={}
        elif kind=='reconnect':
            if not active: errors.append(f'{i}: reconnect after stop')
            connected=True; last_send=None; captures={}
        elif kind in ('stop','reset'):
            if not active: errors.append(f'{i}: duplicate stop')
            active=False; connected=False; captures={}; last_send=None; session=None
        else: errors.append(f'{i}: unknown event')
    if active: errors.append('trace ended without stop or reset')
    return errors

def main():
    p=argparse.ArgumentParser(); p.add_argument('trace',type=Path); args=p.parse_args()
    events=json.loads(args.trace.read_text(encoding='utf-8'))
    if not isinstance(events,list): raise ValueError('trace must be a JSON array')
    errors=validate(events)
    print(json.dumps({'passed':not errors, 'errors':errors},ensure_ascii=False,indent=2))
    return 1 if errors else 0
if __name__=='__main__': raise SystemExit(main())
