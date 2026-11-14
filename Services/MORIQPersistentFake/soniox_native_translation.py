"""Opt-in native translation stream: independent confirmed and draft lanes.

Soniox sends each final token once. A token-bearing response is a new complete
non-final snapshot across *both* lanes, including an empty snapshot. Messages
without a tokens field carry no such observation. We do not infer translation
timestamps or sentence-to-sentence alignment.
"""
from dataclasses import dataclass

MAX_TEXT_BYTES = 16000
MAX_OFFSET = (1 << 53) - 1


@dataclass
class _Lane:
    offset: int = 0
    revision: int = 0
    provisional: str = ''


class NativeTranslationLanes:
    """Represent final as UTF-8-offset deltas and provisional as snapshots.

    Lanes live for one upstream connection. The receiver owns the session/epoch
    fence and its own history; marker events carry no invented alignment.
    """
    def __init__(self):
        self.lanes = {'original': _Lane(), 'translation': _Lane()}
        self.finished = False

    def accept(self, message):
        if self.finished or not isinstance(message, dict):
            raise ValueError('invalid provider message')
        if message.get('error_code') is not None or message.get('error_type') is not None:
            raise ValueError('provider error')
        if 'finished' in message and type(message['finished']) is not bool:
            raise ValueError('invalid finish')
        if 'tokens' not in message:
            if message.get('finished') is True:
                self.finished = True
                return self._apply([], True)
            return []
        tokens = message['tokens']
        if not isinstance(tokens, list) or len(tokens) > 2000:
            raise ValueError('invalid tokens')
        # Validate the entire response before advancing either lane.
        for token in tokens:
            if not isinstance(token, dict) or not isinstance(token.get('text'), str) or type(token.get('is_final')) is not bool:
                raise ValueError('invalid token')
            if len(token['text'].encode('utf-8')) > MAX_TEXT_BYTES:
                raise ValueError('token too large')
            if token.get('translation_status', 'none') not in ('none', 'original', 'translation'):
                raise ValueError('invalid translation status')
            if token['text'] in ('<end>', '<fin>') and not token['is_final']:
                raise ValueError('invalid marker')
        result = self._apply(tokens, message.get('finished') is True)
        self.finished = message.get('finished') is True
        return result

    def _apply(self, tokens, finished):
        # First create a response-wide draft, then serialize ordered final
        # deltas and markers. Do not attach a source timestamp to translation.
        pending = {'original': '', 'translation': ''}
        draft = {'original': '', 'translation': ''}
        operations = []
        saw_draft = {'original': False, 'translation': False}
        for token in tokens:
            text = token['text']
            if text in ('<end>', '<fin>'):
                if draft['original'] or draft['translation']:
                    raise ValueError('provisional before marker')
                operations.append(('flush', pending.copy()))
                pending = {'original': '', 'translation': ''}
                operations.append(('marker', text))
                saw_draft = {'original': False, 'translation': False}
                continue
            lane = 'translation' if token.get('translation_status') == 'translation' else 'original'
            if token['is_final']:
                if saw_draft[lane]: raise ValueError('final after provisional token')
                pending[lane] += text
            else:
                saw_draft[lane] = True
                draft[lane] += text
        if finished:
            # Never promote a provisional hypothesis on connection close.
            draft = {'original': '', 'translation': ''}
        if any(len(s.encode('utf-8')) > MAX_TEXT_BYTES for s in list(pending.values()) + list(draft.values())):
            raise ValueError('response too large')
        operations.append(('flush', pending.copy()))
        # Include offsets to allow clients to reject gaps and stale messages.
        out = []
        last_flush = max(i for i, op in enumerate(operations) if op[0] == 'flush')
        totals = {k: sum(len(v[k].encode('utf-8')) for op, v in operations if op == 'flush') for k in self.lanes}
        if any(len(v[k].encode('utf-8')) > MAX_TEXT_BYTES for op, v in operations if op == 'flush' for k in self.lanes):
            raise ValueError('response too large')
        if any(self.lanes[k].offset + totals[k] > MAX_OFFSET for k in self.lanes):
            raise ValueError('offset overflow')
        for index, (op, value) in enumerate(operations):
            if op == 'marker':
                out.append({'type': 'stream_marker', 'marker': value})
                continue
            for lane in ('original', 'translation'):
                track = self.lanes[lane]
                delta = value[lane]
                # Endpoint means prior hypotheses are no longer provisional.
                tail = draft[lane] if index == last_flush else ''
                if delta or tail != track.provisional:
                    track.revision += 1
                    out.append({'type': 'lane_delta', 'lane': lane,
                                'revision': track.revision,
                                'confirmed_utf8_offset': track.offset,
                                'confirmed_delta': delta, 'provisional': tail})
                    track.offset += len(delta.encode('utf-8'))
                    track.provisional = tail
        return out
