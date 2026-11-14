"""Explicit mapping between a provider connection and captured PCM samples.

The caller records a span only after it actually forwards those samples.  This
module neither buffers audio nor establishes that capture itself lost nothing.
All ranges are half open and all identifiers are caller-owned, opaque epochs.
"""
from dataclasses import dataclass

_MAX = (1 << 64) - 1


class TimelineError(ValueError):
    """Timing is invalid, outside the known spans, or not safely mappable."""


def _uint(value, name):
    if type(value) is not int or not 0 <= value <= _MAX:
        raise TimelineError(f'invalid {name}')
    return value


def _identifier(value, name):
    if not isinstance(value, str) or not value or len(value) > 128:
        raise TimelineError(f'invalid {name}')
    return value


@dataclass(frozen=True)
class SampleRange:
    epoch: str
    start: int
    end: int


@dataclass(frozen=True)
class _Span:
    upstream_start: int
    upstream_end: int
    stream_start: int
    stream_end: int


class AudioTimeline:
    """One connection and one sample epoch; never implicitly joins epochs.

    ``record_forwarded`` requires the explicit relative upstream start for each
    chunk. A gap in source samples is permitted but remains a gap when mapping.
    Only adjacent source and upstream spans are coalesced.
    """

    def __init__(self, epoch, connection, *, sample_rate=16000, max_spans=4096):
        self.epoch = _identifier(epoch, 'epoch')
        self.connection = _identifier(connection, 'connection')
        if type(sample_rate) is not int or not 1 <= sample_rate <= 192000:
            raise TimelineError('invalid sample rate')
        if type(max_spans) is not int or not 1 <= max_spans <= 100000:
            raise TimelineError('invalid span limit')
        self.sample_rate = sample_rate
        self.max_spans = max_spans
        self._spans = []

    def _check_identity(self, epoch, connection):
        if epoch != self.epoch or connection != self.connection:
            raise TimelineError('epoch or connection mismatch')

    def record_forwarded(self, *, epoch, connection, upstream_start, stream_start, sample_count):
        self._check_identity(epoch, connection)
        upstream_start = _uint(upstream_start, 'upstream start')
        stream_start = _uint(stream_start, 'stream start')
        sample_count = _uint(sample_count, 'sample count')
        if not sample_count or sample_count > _MAX - max(upstream_start, stream_start):
            raise TimelineError('invalid sample range')
        upstream_end, stream_end = upstream_start + sample_count, stream_start + sample_count
        previous = self._spans[-1] if self._spans else None
        if previous:
            if upstream_start != previous.upstream_end:
                raise TimelineError('noncontiguous upstream samples')
            if stream_start < previous.stream_end:
                raise TimelineError('overlapping or reordered source samples')
            if stream_start == previous.stream_end:
                self._spans[-1] = _Span(previous.upstream_start, upstream_end, previous.stream_start, stream_end)
                return
        elif upstream_start != 0:
            raise TimelineError('first upstream sample must be zero')
        if len(self._spans) >= self.max_spans:
            raise TimelineError('too many source gaps')
        self._spans.append(_Span(upstream_start, upstream_end, stream_start, stream_end))

    def map_samples(self, *, epoch, connection, start, end):
        """Map explicit integer provider sample positions; missing => None.

        A range touching a source gap, an unknown connection, or samples that
        have not been recorded is rejected, not rounded or bridged.
        """
        self._check_identity(epoch, connection)
        if start is None or end is None:
            return None
        start, end = _uint(start, 'start'), _uint(end, 'end')
        if start >= end:
            raise TimelineError('invalid interval')
        for span in self._spans:
            if span.upstream_start <= start < span.upstream_end:
                if end > span.upstream_end:
                    raise TimelineError('interval crosses source gap or recorded boundary')
                offset = span.stream_start - span.upstream_start
                return SampleRange(self.epoch, start + offset, end + offset)
        raise TimelineError('interval outside recorded samples')

    def map_milliseconds(self, *, epoch, connection, start_ms, end_ms):
        """Map whole milliseconds only when exactly representable in samples."""
        self._check_identity(epoch, connection)
        if start_ms is None or end_ms is None:
            return None
        start_ms, end_ms = _uint(start_ms, 'start milliseconds'), _uint(end_ms, 'end milliseconds')
        if start_ms * self.sample_rate % 1000 or end_ms * self.sample_rate % 1000:
            raise TimelineError('timestamp is not sample-aligned')
        start, end = start_ms * self.sample_rate // 1000, end_ms * self.sample_rate // 1000
        return self.map_samples(epoch=epoch, connection=connection, start=start, end=end)
