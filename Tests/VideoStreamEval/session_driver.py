"""Deterministic, offline transport simulator; it does not capture or send images.

The caller drives a virtual monotonic clock. Frame identifiers represent only
synthetic input. An in-flight completion is tagged with its connection epoch,
so late callbacks after disconnect, stop or display switch cannot be accepted.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Frame:
    key: str
    session: str
    display: str
    at_ms: int


class Driver:
    def __init__(self, *, interval_ms=1000, max_age_ms=1500):
        if interval_ms < 0 or max_age_ms < 0:
            raise ValueError('negative limits')
        self.interval_ms, self.max_age_ms = interval_ms, max_age_ms
        self.clock = -1
        self.trace = []
        self.active = self.connected = False
        self.session = self.display = None
        self.epoch = 0
        self.pending = self.inflight = self.latest = None
        self.last_send = None
        self.keys = set()

    def _time(self, at):
        if not isinstance(at, int) or at < 0 or at < self.clock:
            raise ValueError('nonmonotonic time')
        self.clock = at

    def _record(self, kind, **data):
        self.trace.append({'type': kind, 'at_ms': self.clock, **data})

    def start(self, at, session, display):
        self._time(at)
        if self.active or not session or not display:
            raise ValueError('invalid start')
        self.active = self.connected = True
        self.session, self.display = session, display
        self.epoch += 1
        self.keys.clear()
        self.pending = self.inflight = self.latest = None
        self.last_send = None
        self._record('start', session=session)

    def capture(self, at, frame, *, session, display, origin='synthetic'):
        self._time(at)
        if not self.active or not self.connected or session != self.session or display != self.display:
            return False
        if origin != 'synthetic' or not frame or frame in self.keys:
            raise ValueError('invalid synthetic frame')
        self.keys.add(frame)
        self.pending = Frame(frame, session, display, at)  # replace older unsent frame
        self._record('capture', session=session, frame=frame, origin=origin)
        return True

    def pump(self, at):
        self._time(at)
        if not self.active or not self.connected or self.inflight or not self.pending:
            return None
        if at - self.pending.at_ms > self.max_age_ms:
            self.pending = None
            return None
        if self.last_send is not None and at - self.last_send < self.interval_ms:
            return None
        frame, self.pending = self.pending, None
        self.inflight = (self.epoch, frame)
        self.last_send = at
        self._record('send', session=frame.session, frame=frame.key)
        return self.inflight

    def complete(self, at, token):
        self._time(at)
        if not self.active or not self.connected or self.inflight != token or token[0] != self.epoch:
            return False
        _, frame = token
        self.inflight = None
        if at - frame.at_ms > self.max_age_ms:
            return False
        self.latest = frame
        return True

    def ask(self, at):
        """Return the last delivered, fresh frame, or None if context is unavailable."""
        self._time(at)
        frame = self.latest
        if not self.active or not self.connected or frame is None or at - frame.at_ms > self.max_age_ms:
            return None
        return frame.key

    def disconnect(self, at):
        self._time(at)
        if not self.active or not self.connected:
            raise ValueError('not connected')
        self.connected = False
        self.epoch += 1
        self.pending = self.inflight = self.latest = None
        self._record('disconnect')

    def reconnect(self, at):
        self._time(at)
        if not self.active or self.connected:
            raise ValueError('invalid reconnect')
        self.connected = True
        self.epoch += 1
        self.last_send = None
        self._record('reconnect')

    def stop(self, at):
        self._time(at)
        if not self.active:
            raise ValueError('not active')
        self.active = self.connected = False
        self.epoch += 1
        self.pending = self.inflight = self.latest = None
        self.session = self.display = None
        self._record('stop')


def event_observability(start_ms, end_ms, delivered_capture_times_ms):
    """Use capture times of delivered frames; sampling is not recognition."""
    if start_ms < 0 or end_ms <= start_ms:
        raise ValueError('invalid event interval')
    return 'sampled' if any(start_ms <= time < end_ms for time in delivered_capture_times_ms) else 'unobservable'
