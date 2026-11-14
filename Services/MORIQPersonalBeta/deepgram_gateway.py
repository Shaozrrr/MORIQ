"""Loopback-only Deepgram Nova-3 development gateway, not production deployment.

Never store provider credentials or record audio/transcripts in this service. A
public deployment needs independently authenticated TLS, account issuance,
privacy controls, monitoring and an audited spending limit.
"""
import asyncio
from contextlib import asynccontextmanager
import hashlib
import hmac
import ipaddress
import json
import math
import uuid
from decimal import Decimal, InvalidOperation
import os
import urllib.parse

from websockets.asyncio.server import serve
from speech_gateway import NoRedirect, provider_tls_context
from audio_timeline import AudioTimeline, TimelineError
from asr_gateway import decode_audio_frame

PROVIDER = 'wss://api.deepgram.com/v1/listen'
PARAMS = {'model': 'nova-3', 'language': 'en-US', 'encoding': 'linear16',
          'sample_rate': '16000', 'channels': '1', 'interim_results': 'true',
          'endpointing': '300', 'punctuate': 'true', 'mip_opt_out': 'true'}
MAX_PAYLOAD = 131072


@asynccontextmanager
async def guarded_upstream(connector, client, accounts, digest, account):
    """Abort an in-flight handshake when the client disconnects or is revoked."""
    entering = asyncio.create_task(connector.__aenter__())
    disconnected = asyncio.create_task(client.wait_closed())
    async def check_revocation():
        while True:
            await asyncio.sleep(1)
            if await asyncio.to_thread(accounts.authenticate, digest) != account:
                raise PermissionError('session ended')
    revoked = asyncio.create_task(check_revocation()) if account is not None else None
    pending = {entering, disconnected} | ({revoked} if revoked else set())
    opened = False
    try:
        done, _ = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
        # If multiple events happen together, disconnection/revocation wins.
        if disconnected in done or (revoked and revoked in done):
            if revoked and revoked in done: revoked.result()
            raise ConnectionError('client disconnected during handshake')
        upstream = entering.result(); opened = True
        if account is not None and await asyncio.to_thread(accounts.authenticate, digest) != account:
            raise PermissionError('session ended')
        yield upstream
    finally:
        for task in pending:
            if not task.done(): task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        # A completed handshake needs closing even if a concurrent disconnect
        # won the race before its result was consumed.
        if not opened and entering.done() and not entering.cancelled():
            try: entering.result(); opened = True
            except Exception: pass
        if opened: await connector.__aexit__(None, None, None)


class ResultSnapshots:
    """Map Deepgram partial/final snapshots to monotonically numbered segments."""
    def __init__(self, *, include_languages=False, allow_unknown_time=False):
        self.segment = 1
        self.previous = None
        self.finalized = set()
        self.include_languages = include_languages
        self.allow_unknown_time = allow_unknown_time

    def accept(self, msg):
        if not isinstance(msg, dict): raise ValueError('invalid provider response')
        if msg.get('type') != 'Results': return []
        channel = msg.get('channel')
        if not isinstance(channel, dict): raise ValueError('invalid channel')
        alternatives = channel.get('alternatives')
        if not isinstance(alternatives, list) or not alternatives or not isinstance(alternatives[0], dict): raise ValueError('invalid alternatives')
        text = alternatives[0].get('transcript')
        final = msg.get('is_final')
        if not isinstance(text, str) or len(text.encode('utf-8')) > 16000 or not isinstance(final, bool): raise ValueError('invalid transcript')
        if not text: return []
        if final:
            start, duration = msg.get('start'), msg.get('duration')
            timing_valid = (type(start) in (int, float) and type(duration) in (int, float)
                            and 0 <= start <= 1800 and 0 <= duration <= 1800
                            and math.isfinite(start) and math.isfinite(duration))
            if not timing_valid and not self.allow_unknown_time: raise ValueError('invalid timing')
            if timing_valid:
                identity = (start, duration, text)
                if identity in self.finalized: return []
                self.finalized.add(identity)
        if not final and text == self.previous: return []
        event = {'type':'source', 'segment':self.segment, 'text':text, 'final':final}
        if final and timing_valid:
            # Deepgram reports seconds relative to this WebSocket session;
            # they are not yet the application's continuous audio clock.
            if self.allow_unknown_time:
                # V2 must not round a finer-grained provider timestamp into
                # an apparently exact millisecond value.
                start_dec, end_dec = Decimal(str(start)) * 1000, (Decimal(str(start)) + Decimal(str(duration))) * 1000
                if (start_dec == start_dec.to_integral_value() and end_dec == end_dec.to_integral_value()
                        and end_dec <= 2_147_483_647):
                    event.update(start_ms=int(start_dec), end_ms=int(end_dec))
            else:
                start_ms = round(start * 1000)
                end_ms = round((start + duration) * 1000)
                if end_ms <= 2_147_483_647:
                    event.update(start_ms=start_ms, end_ms=end_ms)
        if self.include_languages and final:
            # Hints and confidence are not proof of the spoken language.
            # Preserve observed provider labels only, without transcript text.
            alternative = alternatives[0]
            labels = alternative.get('languages', [])
            if isinstance(labels, list) and len(labels) <= 55 and all(
                isinstance(x, str) and 0 < len(x) <= 35 and x.isascii()
                and all(c.isalnum() or c == '-' for c in x) for x in labels
            ):
                if labels: event['language_labels'] = labels
        if final:
            self.segment += 1
            self.previous = None
        else:
            self.previous = text
        return [event]


def exact_provider_samples(msg):
    """Convert provider seconds only when exactly sample-aligned; no rounding."""
    start, duration = msg.get('start'), msg.get('duration')
    if type(start) not in (int, float) or type(duration) not in (int, float): return None
    if not 0 <= start <= 1800 or not 0 < duration <= 1800 or not math.isfinite(start) or not math.isfinite(duration): return None
    try:
        a, d = Decimal(str(start)), Decimal(str(duration))
        x, y = a * 16000, (a + d) * 16000
        if x != x.to_integral_value() or y != y.to_integral_value(): return None
        return int(x), int(y)
    except (InvalidOperation, ValueError, OverflowError): return None


class DeepgramGateway:
    def __init__(self, key, token_hashes=(), *, upstream=PROVIDER, testing=False, account_store=None, first_audio_timeout=8, idle_timeout=12, multilingual=False):
        parsed = urllib.parse.urlsplit(upstream)
        try: local = ipaddress.ip_address(parsed.hostname or '').is_loopback
        except ValueError: local = False
        if upstream != PROVIDER and not (testing and parsed.scheme == 'ws' and local and parsed.path == '/v1/listen' and not parsed.query and not parsed.fragment and parsed.username is None):
            raise ValueError('invalid upstream')
        if not key or not isinstance(key, str) or not key.isascii() or any(not 33 <= ord(c) <= 126 for c in key): raise ValueError('invalid provider credential')
        if (not token_hashes and account_store is None) or (token_hashes and account_store is not None): raise ValueError('credentials required')
        if any(len(h) != 64 or any(c not in '0123456789abcdef' for c in h) for h in token_hashes): raise ValueError('invalid token hashes')
        if not testing and (first_audio_timeout != 8 or idle_timeout != 12): raise ValueError('timeouts are fixed outside tests')
        if not 0 < first_audio_timeout <= 8 or not 0 < idle_timeout <= 12: raise ValueError('invalid timeouts')
        self.key, self.hashes, self.upstream, self.accounts = key, tuple(token_hashes), upstream, account_store
        self.first_audio_timeout, self.idle_timeout = first_audio_timeout, idle_timeout
        if type(multilingual) is not bool: raise ValueError('invalid multilingual setting')
        self.multilingual = multilingual
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
                required = {'type','source','target'}
                if (not isinstance(config, dict) or set(config) not in (required, required | {'protocol'}) or config['type'] != 'start' or config['target'] not in ('en','zh','ja','ko')):
                    await client.close(1008, 'invalid configuration'); return
                protocol = config.get('protocol', 1)
                if type(protocol) is not int or protocol not in (1, 2):
                    await client.close(1008, 'unsupported protocol'); return
                if config['source'] != 'en' and not (self.multilingual and config['source'] == 'auto'):
                    await client.send(json.dumps({'type':'error','code':'unsupported_source_language_english_only'}))
                    await client.close(1008, 'unsupported source language'); return
                reserved_initial = 0
                if account is not None:
                    if not await asyncio.to_thread(self.accounts.consume, account): raise PermissionError('session unavailable')
                    # Opening a provider session can have minimum billing even
                    # without audio. Reserve conservatively before connecting;
                    # a failure never silently refunds a potentially billed call.
                    if not await asyncio.to_thread(self.accounts.consume_speech, account, 1): raise PermissionError('speech quota unavailable')
                    reserved_initial = 1
                tls = provider_tls_context() if self.upstream.startswith('wss://') else None
                params = dict(PARAMS)
                using_auto = self.multilingual and config['source'] == 'auto'
                if using_auto: params['language'] = 'multi'
                connector = NoRedirect(self.upstream + '?' + urllib.parse.urlencode(params), additional_headers={'Authorization':'Token ' + self.key}, proxy=None, ssl=tls, max_size=MAX_PAYLOAD, open_timeout=10, close_timeout=2, compression=None)
                async with guarded_upstream(connector, client, self.accounts, digest, account) as upstream:
                    ready = {'type':'ready','mode':'transcription','supports_keepalive':True}
                    if protocol == 2: ready['protocol'] = 2
                    await client.send(json.dumps(ready))
                    epoch, connection = str(uuid.uuid4()), str(uuid.uuid4())
                    timeline = AudioTimeline(epoch, connection) if protocol == 2 else None
                    timeline_lock = asyncio.Lock()
                    forwarded_samples = 0
                    async def upload():
                        nonlocal forwarded_samples
                        total, reserved, next_sample = 0, reserved_initial, 0
                        while True:
                            # Heartbeats are accepted only after real audio has
                            # started. No audio nor heartbeat from an alive
                            # client can hold a billable session indefinitely.
                            msg = await asyncio.wait_for(client.recv(), self.idle_timeout if total else self.first_audio_timeout)
                            if isinstance(msg, bytes):
                                pcm, next_sample = decode_audio_frame(msg, protocol, next_sample)
                                total += len(pcm)
                                if total > 32000 * 60 * 30: raise ValueError('session limit')
                                needed = (total + 31999) // 32000
                                if account is not None and needed > reserved:
                                    if not await asyncio.to_thread(self.accounts.consume_speech, account, needed-reserved): raise PermissionError('quota unavailable')
                                    reserved = needed
                                if timeline is None:
                                    await upstream.send(pcm)
                                else:
                                    async with timeline_lock:
                                        await upstream.send(pcm)
                                        count = len(pcm) // 2
                                        timeline.record_forwarded(epoch=epoch, connection=connection, upstream_start=forwarded_samples, stream_start=next_sample-count, sample_count=count)
                                        forwarded_samples += count
                            elif msg == '{"type":"keepalive"}' and total:
                                # Text frame required by the provider. This is
                                # not audio and does not consume audio seconds.
                                await upstream.send('{"type":"KeepAlive"}')
                            elif msg == '{"type":"finish"}':
                                await upstream.send(json.dumps({'type':'CloseStream'})); return
                            else: raise ValueError('invalid client message')
                    async def download():
                        snapshots = ResultSnapshots(include_languages=using_auto, allow_unknown_time=protocol == 2)
                        async for raw in upstream:
                            if not isinstance(raw, str) or len(raw.encode()) > MAX_PAYLOAD: raise ValueError('invalid response')
                            msg = json.loads(raw)
                            if not isinstance(msg, dict): raise ValueError('invalid response')
                            if msg.get('type') == 'Error': raise ValueError('provider error')
                            for event in snapshots.accept(msg):
                                if timeline is not None and event.get('final') is True:
                                    samples = exact_provider_samples(msg)
                                    if samples is not None:
                                        try:
                                            async with timeline_lock:
                                                mapped = timeline.map_samples(epoch=epoch, connection=connection, start=samples[0], end=samples[1])
                                            if mapped is not None: event.update(sample_epoch=mapped.epoch, sample_start=mapped.start, sample_end=mapped.end)
                                        except TimelineError: pass
                                await client.send(json.dumps(event, ensure_ascii=False))
                            if msg.get('type') == 'Metadata':
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
                        if not done: raise TimeoutError('session limit')
                        for task in done: task.result()
                        if sender in done and receiver not in done:
                            done, _ = await asyncio.wait({receiver} | ({watcher} if watcher else set()), timeout=15, return_when=asyncio.FIRST_COMPLETED)
                            if not done: raise TimeoutError('provider did not finish')
                            for task in done: task.result()
                    finally:
                        for task in tasks: task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)
            except Exception:
                try: await client.send(json.dumps({'type':'error','message':'语音服务暂不可用'})); await client.close(1011, 'speech unavailable')
                except Exception: pass


def build_local_gateway(env):
    key = env.get('MORIQ_SPEECH_PROVIDER_KEY', '')
    hashes = [x for x in env.get('MORIQ_SPEECH_TOKEN_HASHES', '').split(',') if x]
    db = env.get('MORIQ_ACCOUNT_DB')
    auto = env.get('MORIQ_DEEPGRAM_AUTO', '0')
    if auto not in ('0', '1'): raise ValueError('invalid auto mode')
    # Enabling automatic multi-language locally requires persistent account
    # and global request/audio limits, not the test-only static hash list.
    if auto == '1' and (not db or hashes): raise ValueError('automatic mode requires account database')
    if db:
        from account_store import AccountStore
        return DeepgramGateway(key, hashes, account_store=AccountStore(db), multilingual=auto == '1')
    return DeepgramGateway(key, hashes)


async def run_local():
    gateway = build_local_gateway(os.environ)
    async with serve(gateway.handle, '127.0.0.1', int(os.environ.get('MORIQ_SPEECH_PORT', '8777')), max_size=8192, compression=None):
        await asyncio.Future()

if __name__ == '__main__': asyncio.run(run_local())
