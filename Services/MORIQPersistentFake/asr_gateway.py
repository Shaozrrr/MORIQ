"""Loopback development gateway for Volcengine streaming ASR 2.0.

Production still requires an authenticated TLS reverse proxy and account service.
Audio, transcripts and credentials are never logged. Explicitly select this
backend; it is not a replacement for the existing interpretation gateway.
"""
import asyncio
import gzip
import hashlib
import hmac
import ipaddress
import json
import os
import struct
import urllib.parse
import uuid
import zlib
from websockets.asyncio.server import serve
from speech_gateway import NoRedirect, provider_tls_context
from unanchored_preview import UnanchoredPreview
from audio_timeline import AudioTimeline, TimelineError

PROVIDER = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async'
RESOURCE = 'volc.seedasr.sauc.duration'
MAX_PAYLOAD = 131072


def packet(kind, raw, *, last=False, json_payload=False):
    compressed = gzip.compress(raw)
    return bytes((0x11, (kind << 4) | (2 if last else 0), (0x10 if json_payload else 0) | 1, 0)) + struct.pack('>I', len(compressed)) + compressed


def start_packet(*, enable_lid=False):
    body = {'audio': {'format': 'pcm', 'rate': 16000, 'bits': 16, 'channel': 1},
            'request': {'model_name': 'bigmodel', 'enable_nonstream': True,
                        'show_utterances': True, 'result_type': 'full',
                        'enable_itn': True, 'enable_punc': True}}
    if enable_lid:
        body['request']['enable_lid'] = True
    return packet(1, json.dumps(body).encode(), json_payload=True)


def parse_packet(raw):
    if not isinstance(raw, bytes) or len(raw) < 8 or len(raw) > MAX_PAYLOAD: raise ValueError('invalid frame')
    version, header_size = raw[0] >> 4, (raw[0] & 15) * 4
    kind, flags, serialization, compression = raw[1] >> 4, raw[1] & 15, raw[2] >> 4, raw[2] & 15
    if version != 1 or header_size < 4 or header_size > len(raw) - 4 or flags not in (0, 1, 2, 3): raise ValueError('invalid header')
    offset = header_size
    if kind == 15: raise ValueError('provider error')
    if kind != 9 or serialization != 1 or compression not in (0, 1): raise ValueError('invalid response')
    if flags in (1, 3): offset += 4
    if offset + 4 > len(raw): raise ValueError('truncated size')
    size = struct.unpack_from('>I', raw, offset)[0]; offset += 4
    if size != len(raw) - offset: raise ValueError('invalid size')
    payload = raw[offset:]
    if compression == 1:
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        payload = decoder.decompress(payload, MAX_PAYLOAD + 1)
        if len(payload) > MAX_PAYLOAD or decoder.unconsumed_tail or not decoder.eof: raise ValueError('invalid compressed payload')
    result = json.loads(payload)
    if not isinstance(result, dict): raise ValueError('invalid result')
    return result, flags in (2, 3)


class UnanchoredUtterance(ValueError):
    """Provider omitted the key needed to identify a snapshot safely."""


class UtteranceSnapshots:
    """Translate provider utterance snapshots into stable segment snapshots."""
    def __init__(self, *, enable_lid=False):
        self.segments = {}; self.finalized = set(); self.previous = {}; self.enable_lid = enable_lid
    def accept(self, payload):
        result = payload.get('result', {})
        if result is None: return []
        if not isinstance(result, dict): raise ValueError('invalid result')
        utterances = result.get('utterances', [])
        if not isinstance(utterances, list) or len(utterances) > 2000: raise ValueError('invalid utterances')
        # A full snapshot may contain several utterances. Validate the entire
        # batch before mutating segment state, so a malformed later item cannot
        # silently finalize or merge an earlier segment. A missing start is not
        # equivalent to an actual zero timestamp; neither position nor text is
        # a reliable replacement for a provider utterance identifier.
        for item in utterances:
            if not isinstance(item, dict): raise ValueError('invalid utterance')
            if 'start_time' not in item or item['start_time'] is None:
                raise UnanchoredUtterance('utterance start unavailable')
            start, text, final = item['start_time'], item.get('text'), item.get('definite', False)
            if type(start) is not int or start < 0 or not isinstance(text, str) or len(text.encode()) > 16000 or not isinstance(final, bool): raise ValueError('invalid utterance')
        out = []
        for item in utterances:
            start, text, final = item['start_time'], item['text'], item.get('definite', False)
            if start in self.finalized: continue
            segment = self.segments.setdefault(start, len(self.segments) + 1)
            if len(self.segments) > 2000: raise ValueError('too many segments')
            label = None
            if self.enable_lid and final:
                additions = item.get('additions')
                if isinstance(additions, dict):
                    candidate = additions.get('lid_lang')
                    if isinstance(candidate, str) and 0 < len(candidate) <= 64 and candidate.isascii() and all(c.isalnum() or c in '_-' for c in candidate):
                        label = candidate
            if text and (self.previous.get(start) != text or final):
                event = {'type': 'source', 'text': text, 'segment': segment, 'final': final}
                # Language is a provider label, not a confidence score. It is
                # only evidence once the utterance is final; missing stays missing.
                if label: event['language_label'] = label
                # Omit absent/invalid timing rather than inventing an audio
                # boundary. Values are relative to this provider session.
                actual_start, actual_end = item.get('start_time'), item.get('end_time')
                if (type(actual_start) is int and type(actual_end) is int
                        and 0 <= actual_start <= actual_end <= 2_147_483_647):
                    event.update(start_ms=actual_start, end_ms=actual_end)
                out.append(event)
                self.previous[start] = text
            elif not text and label:
                # Unsupported languages may have a label but no transcript.
                # Keep this as evidence, never fabricate a subtitle.
                event = {'type': 'language_evidence', 'segment': segment, 'language_label': label}
                actual_start, actual_end = item.get('start_time'), item.get('end_time')
                if (type(actual_start) is int and type(actual_end) is int
                        and 0 <= actual_start <= actual_end <= 2_147_483_647):
                    event.update(start_ms=actual_start, end_ms=actual_end)
                out.append(event)
            if final: self.finalized.add(start)
        return out


def decode_audio_frame(frame, protocol, expected_sample):
    """Return PCM and next sample; V2 frame header is never sent upstream."""
    if not isinstance(frame, bytes): raise ValueError('invalid audio')
    if protocol == 1:
        if not frame or len(frame) > 6400 or len(frame) % 2: raise ValueError('invalid audio')
        return frame, expected_sample + len(frame) // 2
    if protocol != 2 or len(frame) < 16 or frame[:4] != b'AUD2': raise ValueError('invalid audio frame')
    start, count = struct.unpack_from('>QI', frame, 4)
    if not 1 <= count <= 3200 or len(frame) != 16 + count * 2: raise ValueError('invalid audio frame')
    if start != expected_sample or start + count > 2**64 - 1: raise ValueError('noncontiguous audio')
    return frame[16:], start + count


class ASRGateway:
    def __init__(self, key, token_hashes=(), *, upstream=PROVIDER, testing=False, account_store=None, enable_lid=False):
        parsed = urllib.parse.urlsplit(upstream)
        try: loopback = ipaddress.ip_address(parsed.hostname or '').is_loopback
        except ValueError: loopback = False
        if upstream != PROVIDER and not (testing and parsed.scheme == 'ws' and loopback): raise ValueError('invalid upstream')
        if not key or (not token_hashes and account_store is None) or (token_hashes and account_store is not None): raise ValueError('credentials required')
        if any(len(h) != 64 or any(c not in '0123456789abcdef' for c in h) for h in token_hashes): raise ValueError('invalid token hashes')
        if not isinstance(enable_lid, bool): raise ValueError('invalid language detection setting')
        self.key, self.hashes, self.upstream, self.accounts = key, tuple(token_hashes), upstream, account_store
        self.enable_lid = enable_lid
        self.slots = asyncio.Semaphore(2)

    async def handle(self, client):
        async with self.slots:
            try:
                auth = client.request.headers.get('Authorization', '')
                token = auth[7:] if auth.startswith('Bearer ') else ''
                if client.request.path != '/v1/speech/stream' or not 32 <= len(token) <= 256 or not token.isascii() or not all(33 <= ord(c) <= 126 for c in token):
                    await client.close(1008, 'unauthorized'); return
                digest = hashlib.sha256(token.encode()).hexdigest()
                account = await asyncio.to_thread(self.accounts.authenticate, digest) if self.accounts else None
                if (self.accounts and account is None) or (not self.accounts and not any(hmac.compare_digest(digest, h) for h in self.hashes)):
                    await client.close(1008, 'unauthorized'); return
                raw = await asyncio.wait_for(client.recv(), 5)
                config = json.loads(raw) if isinstance(raw, str) and len(raw) <= 512 else None
                required = {'type', 'source', 'target'}
                if (not isinstance(config, dict) or not required <= set(config) <= required | {'protocol', 'unanchored_preview'}
                        or config['type'] != 'start' or config['target'] not in ('en', 'zh', 'ja', 'ko')):
                    await client.close(1008, 'invalid configuration'); return
                protocol = config.get('protocol', 1)
                if type(protocol) is not int or protocol not in (1, 2):
                    await client.close(1008, 'unsupported protocol'); return
                preview_enabled = config.get('unanchored_preview', False)
                if type(preview_enabled) is not bool:
                    await client.close(1008, 'invalid configuration'); return
                if config['source'] not in ('en', 'zh'):
                    await client.send(json.dumps({'type': 'error', 'code': 'unsupported_source_language'}))
                    await client.close(1008, 'unsupported source language'); return
                if account is not None and not await asyncio.to_thread(self.accounts.consume, account): raise PermissionError('session unavailable')
                headers = {'X-Api-Key': self.key, 'X-Api-Resource-Id': RESOURCE, 'X-Api-Request-Id': str(uuid.uuid4())}
                tls = provider_tls_context() if self.upstream.startswith('wss://') else None
                async with NoRedirect(self.upstream, additional_headers=headers, proxy=None, ssl=tls, max_size=MAX_PAYLOAD, open_timeout=10, close_timeout=2, compression=None) as upstream:
                    await upstream.send(start_packet(enable_lid=self.enable_lid))
                    # The first response confirms the provider accepted configuration.
                    initial, initial_last = parse_packet(await asyncio.wait_for(upstream.recv(), 15))
                    if initial_last: raise ValueError('provider session ended during setup')
                    snapshots = UtteranceSnapshots(enable_lid=self.enable_lid)
                    preview = UnanchoredPreview() if preview_enabled else None
                    def snapshot_events(payload):
                        if preview is None:
                            return snapshots.accept(payload)
                        # Validate the complete provider snapshot before either
                        # dropping unknown identities or emitting any events.
                        # Their text only enters a separate ephemeral channel.
                        preview_events = preview.accept(payload)
                        result = payload.get('result')
                        if result is None: result = {}
                        anchored = [item for item in result.get('utterances', []) if item.get('start_time') is not None]
                        anchored_events = snapshots.accept({'result': {'utterances': anchored}})
                        return anchored_events + preview_events
                    # Per-connection sample epoch: it must never be joined to another connection.
                    epoch, connection = str(uuid.uuid4()), str(uuid.uuid4())
                    timeline = AudioTimeline(epoch, connection) if protocol == 2 else None
                    timeline_lock = asyncio.Lock()
                    forwarded_samples = 0
                    async def map_event(event):
                        if timeline is None: return event
                        try:
                            async with timeline_lock:
                                mapped = timeline.map_milliseconds(epoch=epoch, connection=connection, start_ms=event.get('start_ms'), end_ms=event.get('end_ms'))
                        except TimelineError:
                            return event
                        if mapped is not None:
                            event = dict(event, sample_epoch=mapped.epoch, sample_start=mapped.start, sample_end=mapped.end)
                        return event
                    ready = {'type': 'ready', 'mode': 'transcription'}
                    if protocol == 2: ready['protocol'] = 2
                    if preview is not None: ready['unanchored_preview'] = True
                    await client.send(json.dumps(ready))
                    for event in snapshot_events(initial):
                        await client.send(json.dumps(await map_event(event), ensure_ascii=False))
                    async def upload():
                        nonlocal forwarded_samples
                        total = reserved = next_sample = 0
                        while True:
                            msg = await asyncio.wait_for(client.recv(), 5)
                            if isinstance(msg, bytes):
                                pcm, next_sample = decode_audio_frame(msg, protocol, next_sample)
                                total += len(pcm)
                                if total > 32000 * 60 * 30: raise ValueError('session limit')
                                needed = (total + 31999) // 32000
                                if account is not None and needed > reserved:
                                    if not await asyncio.to_thread(self.accounts.consume_speech, account, needed - reserved): raise PermissionError('quota unavailable')
                                    reserved = needed
                                if timeline is None:
                                    await upstream.send(packet(2, pcm))
                                else:
                                    # Serialise mapping behind send and ledger update: a
                                    # provider response can arrive while send is suspended.
                                    async with timeline_lock:
                                        await upstream.send(packet(2, pcm))
                                        count = len(pcm) // 2
                                        timeline.record_forwarded(epoch=epoch, connection=connection, upstream_start=forwarded_samples, stream_start=next_sample - count, sample_count=count)
                                        forwarded_samples += count
                            elif msg == '{"type":"finish"}':
                                await upstream.send(packet(2, b'', last=True)); return
                            else: raise ValueError('invalid client message')
                    async def download():
                        async for msg in upstream:
                            data, last = parse_packet(msg)
                            for event in snapshot_events(data): await client.send(json.dumps(await map_event(event), ensure_ascii=False))
                            if last:
                                await client.send(json.dumps({'type':'finished'})); return
                        raise ConnectionError('provider disconnected')
                    async def monitor():
                        while True:
                            await asyncio.sleep(1)
                            if await asyncio.to_thread(self.accounts.authenticate, digest) != account: raise PermissionError('session ended')
                    sender, receiver = asyncio.create_task(upload()), asyncio.create_task(download())
                    watcher = asyncio.create_task(monitor()) if account is not None else None
                    tasks = {sender, receiver} | ({watcher} if watcher else set())
                    try:
                        done, _ = await asyncio.wait(tasks, timeout=1800, return_when=asyncio.FIRST_COMPLETED)
                        if not done: raise TimeoutError('session time limit')
                        for task in done: task.result()
                        if sender in done and receiver not in done:
                            done, _ = await asyncio.wait({receiver} | ({watcher} if watcher else set()), timeout=15, return_when=asyncio.FIRST_COMPLETED)
                            if not done: raise TimeoutError('provider did not finish')
                            for task in done: task.result()
                    finally:
                        for task in tasks: task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)
            except UnanchoredUtterance:
                # No reliable cross-snapshot identity exists; stop instead of
                # pretending this is timestamp zero or silently losing text.
                try: await client.send(json.dumps({'type':'error','code':'unanchored_utterance','message':'语音分句缺少必要时间信息，请重试。'})); await client.close(1011, 'speech timing unavailable')
                except Exception: pass
            except Exception:
                try: await client.send(json.dumps({'type':'error','message':'语音服务暂不可用'})); await client.close(1011, 'speech unavailable')
                except Exception: pass


async def run_local():
    key = os.environ.get('MORIQ_SPEECH_PROVIDER_KEY', '')
    hashes = [x for x in os.environ.get('MORIQ_SPEECH_TOKEN_HASHES', '').split(',') if x]
    db = os.environ.get('MORIQ_ACCOUNT_DB')
    if db:
        from account_store import AccountStore
        gateway = ASRGateway(key, hashes, account_store=AccountStore(db))
    else: gateway = ASRGateway(key, hashes)
    async with serve(gateway.handle, '127.0.0.1', int(os.environ.get('MORIQ_SPEECH_PORT', '8777')), max_size=8192, compression=None):
        await asyncio.Future()

if __name__ == '__main__': asyncio.run(run_local())
