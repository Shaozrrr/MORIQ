"""Experimental, unnegotiated full-snapshot preview; not wired to a gateway.

Preview is deliberately not a segment or language event and is never final.
Clients must explicitly negotiate and implement this before it can be sent.
"""

class UnanchoredPreview:
    """One connection's transient presentation state, with no identity claims."""

    def __init__(self):
        self._previous = None

    def accept(self, payload):
        if not isinstance(payload, dict):
            raise ValueError('invalid snapshot')
        result = payload.get('result')
        if result is None:
            result = {}
        if not isinstance(result, dict):
            raise ValueError('invalid result')
        utterances = result.get('utterances', [])
        if not isinstance(utterances, list) or len(utterances) > 2000:
            raise ValueError('invalid utterances')

        unknown = []
        anchored_partial = False
        for item in utterances:
            if not isinstance(item, dict):
                raise ValueError('invalid utterance')
            text = item.get('text')
            final = item.get('definite', False)
            if not isinstance(text, str) or len(text.encode('utf-8')) > 16000 or type(final) is not bool:
                raise ValueError('invalid utterance')
            start = item.get('start_time')
            if start is None:
                unknown.append(text)
            elif type(start) is not int or start < 0:
                raise ValueError('invalid start')
            elif not final and text:
                anchored_partial = True

        # Multiple unanchored utterances have unknown ordering/identity. Do not
        # join them, pick a winner, or replace an anchored partial in the UI.
        value = unknown[0] if len(unknown) == 1 and not anchored_partial and unknown[0] else None
        if value == self._previous:
            return []
        self._previous = value
        # Explicit clear applies only to the preview surface, never to normal
        # finalized or anchored captions. No timing, final, segment or label.
        return [{'type': 'unanchored_preview', 'text': value}]
