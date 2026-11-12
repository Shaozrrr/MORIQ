#!/usr/bin/env python3
"""Deterministic offline tests; no network, screenshots, credentials or model."""
from session_driver import Driver, event_observability
from validate_trace import validate


def check():
    d = Driver(interval_ms=1000, max_age_ms=1500)
    d.start(0, 'session-1', 'display-1')
    assert d.capture(0, 'a', session='session-1', display='display-1')
    first = d.pump(0)
    assert d.capture(100, 'b', session='session-1', display='display-1')
    assert d.capture(200, 'c', session='session-1', display='display-1')
    assert d.pending.key == 'c' and d.pump(500) is None
    assert d.complete(600, first) and d.ask(600) == 'a'
    assert d.pump(999) is None
    second = d.pump(1000)
    assert second[1].key == 'c' and d.complete(1001, second)
    assert d.ask(1001) == 'c'
    assert d.ask(1701) is None  # context must not survive freshness limit
    assert d.capture(1800, 'stale', session='session-1', display='display-1')
    assert d.pump(3401) is None and d.pending is None
    assert d.capture(3402, 'inflight', session='session-1', display='display-1')
    old = d.pump(3402)
    d.disconnect(3403)
    assert d.ask(3403) is None
    assert not d.capture(3404, 'offline', session='session-1', display='display-1')
    d.reconnect(3405)
    assert not d.complete(3406, old)
    assert d.ask(3406) is None
    assert d.capture(3407, 'fresh', session='session-1', display='display-1')
    token = d.pump(3407)
    assert d.complete(3408, token) and d.ask(3408) == 'fresh'
    d.stop(3409)
    assert not d.complete(3410, token) and d.ask(3410) is None
    d.start(3411, 'session-2', 'display-2')
    assert not d.capture(3412, 'old-display', session='session-1', display='display-1')
    assert d.ask(3412) is None
    assert d.capture(3413, 'new-display', session='session-2', display='display-2')
    token = d.pump(3413)
    assert d.complete(3414, token) and d.ask(3414) == 'new-display'
    d.stop(3415)
    assert validate(d.trace) == [], validate(d.trace)
    assert [e['frame'] for e in d.trace if e['type'] == 'send'] == ['a', 'c', 'inflight', 'fresh', 'new-display']
    print('PASS offline one-slot backpressure, freshness, reconnect, stop and display/session isolation')

    # A short event can occur between 1 FPS samples. It is not evidence of
    # absence; any model answer claiming to know it is an unjustified guess.
    assert event_observability(250, 500, [0, 1000, 2000]) == 'unobservable'
    assert event_observability(250, 500, [0, 250, 1000]) == 'sampled'
    assert event_observability(250, 500, [500]) == 'unobservable'  # exclusive end
    print('PASS short unobserved event is marked unobservable, not absent')

    for action in (lambda: d.reconnect(3416), lambda: d.start(3410, 'bad', 'display')):
        try:
            action()
        except ValueError:
            pass
        else:
            raise AssertionError('invalid state/time accepted')


if __name__ == '__main__':
    check()
