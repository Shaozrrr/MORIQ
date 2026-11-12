"""Loopback-only streaming speech gateway prototype. Not production deployment.

Protobuf field numbers are based on the provider's published AST 2.0 schema.
No audio, tokens or transcript are logged or stored. The upstream key stays here.
"""
import asyncio
import hashlib
import hmac
import ipaddress
import json
import os
import ssl
import urllib.parse
import uuid
from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

PROVIDER = 'wss://openspeech.bytedance.com/api/v4/ast/v2/translate'
LANGUAGES = {'zh', 'en', 'ja', 'ko', 'de', 'fr', 'es', 'pt', 'id', 'ru', 'it', 'ar', 'tr', 'ms', 'vi', 'th', 'nl', 'ro', 'pl', 'cs'}

def provider_tls_context():
    # Some macOS Python distributions have no configured default CA file.
    # Prefer an installed CA bundle, retaining normal certificate validation.
    try:
        import certifi
    except ImportError:
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=certifi.where())

class NoRedirect(connect):
    def process_redirect(self, exc):
        return exc

def varint(n):
    if not 0 <= n < 2**64: raise ValueError('invalid varint')
    out = bytearray()
    while n >= 128: out.append((n & 127) | 128); n >>= 7
    out.append(n)
    return bytes(out)

def field(n, value):
    if isinstance(value, int): return varint(n << 3) + varint(value)
    if isinstance(value, str): value = value.encode('utf-8')
    return varint((n << 3) | 2) + varint(len(value)) + value

def parse(data):
    """Bounded protobuf reader for the documented response fields."""
    if not isinstance(data, bytes) or len(data) > 131072: raise ValueError('invalid provider message')
    idx = 0; result = {}
    def read_var():
        nonlocal idx
        value = 0
        for shift in range(0, 70, 7):
            if idx >= len(data): raise ValueError('truncated protobuf')
            b = data[idx]; idx += 1; value |= (b & 127) << shift
            if not b & 128: return value
        raise ValueError('invalid protobuf varint')
    while idx < len(data):
        tag = read_var(); num, wire = tag >> 3, tag & 7
        if not num: raise ValueError('invalid protobuf field')
        if wire == 0: value = read_var()
        elif wire == 2:
            length = read_var()
            if length > len(data) - idx: raise ValueError('truncated protobuf')
            value = data[idx:idx + length]; idx += length
        elif wire in (1, 5):
            length = 8 if wire == 1 else 4
            if length > len(data) - idx: raise ValueError('truncated protobuf')
            value = data[idx:idx + length]; idx += length
        else: raise ValueError('unsupported protobuf wire type')
        result[num] = value
    return result

def request(event, session, *, source='en', target='zh', pcm=b''):
    data = field(1, field(6, session)) + field(2, event)
    if event == 100:
        audio = field(4, 'wav') + field(5, 'raw') + field(7, 16000) + field(8, 16) + field(9, 1)
        options = field(1, 's2t') + field(2, source) + field(3, target)
        data += field(4, audio) + field(6, options)
    elif event == 200:
        data += field(4, field(14, pcm))
    elif event != 102: raise ValueError('unsupported request')
    return data

class SpeechGateway:
    def __init__(self, provider_key, token_hashes=(), *, upstream=PROVIDER, testing=False, account_store=None, session_check_interval=1.0):
        parsed = urllib.parse.urlsplit(upstream)
        if testing:
            try: local = ipaddress.ip_address(parsed.hostname or '').is_loopback
            except ValueError: local = False
            if upstream != PROVIDER and not (parsed.scheme == 'ws' and local): raise ValueError('invalid test upstream')
        elif upstream != PROVIDER: raise ValueError('fixed upstream required')
        if not provider_key or (not token_hashes and account_store is None) or any(len(h) != 64 or any(c not in '0123456789abcdef' for c in h) for h in token_hashes): raise ValueError('credentials required')
        if account_store is not None and token_hashes: raise ValueError('choose one account source')
        if not 0.05 <= session_check_interval <= 60: raise ValueError('invalid session check interval')
        self.provider_key, self.tokens, self.upstream = provider_key, tuple(token_hashes), upstream
        self.account_store, self.session_check_interval = account_store, session_check_interval
        self.slots = asyncio.Semaphore(2)

    async def handle(self, client):
        async with self.slots:
            try:
                header = client.request.headers.get('Authorization', '')
                if client.request.path != '/v1/speech/stream' or not header.startswith('Bearer '):
                    await client.close(1008, 'unauthorized'); return
                token = header[7:]
                if not 32 <= len(token) <= 256 or not token.isascii() or not all(33 <= ord(c) <= 126 for c in token):
                    await client.close(1008, 'unauthorized'); return
                digest = hashlib.sha256(token.encode('ascii')).hexdigest()
                account = None
                if self.account_store is not None:
                    account = await asyncio.to_thread(self.account_store.authenticate, digest)
                    if account is None: await client.close(1008, 'unauthorized'); return
                elif not any(hmac.compare_digest(digest, x) for x in self.tokens):
                    await client.close(1008, 'unauthorized'); return
                first = await asyncio.wait_for(client.recv(), 5)
                config = json.loads(first) if isinstance(first, str) and len(first) <= 512 else None
                if not isinstance(config, dict) or set(config) != {'type','source','target'} or config['type'] != 'start' or config['source'] not in LANGUAGES or config['target'] not in LANGUAGES or config['source'] == config['target'] or not ({config['source'], config['target']} & {'en','zh'}):
                    await client.close(1008, 'invalid configuration'); return
                # Reserve one session request before opening a billable upstream.
                # This is not a duration or monetary spending limit.
                if account is not None and not await asyncio.to_thread(self.account_store.consume, account):
                    await client.close(1008, 'session unavailable'); return
                session = str(uuid.uuid4())
                headers = {'X-Api-Key': self.provider_key, 'X-Api-Resource-Id': 'volc.service_type.10053'}
                tls = provider_tls_context() if self.upstream.startswith('wss://') else None
                async with NoRedirect(self.upstream, additional_headers=headers, proxy=None, ssl=tls, max_size=131072, open_timeout=10, close_timeout=2, compression=None) as upstream:
                    await upstream.send(request(100, session, source=config['source'], target=config['target']))
                    first_response = parse(await asyncio.wait_for(upstream.recv(), 15))
                    if first_response.get(2) != 150: raise ValueError('provider session unavailable')
                    await client.send(json.dumps({'type':'ready'}))
                    async def upload():
                        total = 0; reserved_seconds = 0
                        while True:
                            # A connected but idle client must not keep a
                            # billable upstream open indefinitely.
                            message = await asyncio.wait_for(client.recv(), 5)
                            if isinstance(message, bytes):
                                if not message or len(message) > 6400 or len(message) % 2: raise ValueError('invalid audio')
                                total += len(message)
                                if total > 32000 * 60 * 30: raise ValueError('session limit')
                                required_seconds = (total + 31999) // 32000
                                if account is not None and required_seconds > reserved_seconds:
                                    if not await asyncio.to_thread(self.account_store.consume_speech, account, required_seconds - reserved_seconds):
                                        raise PermissionError('speech quota unavailable')
                                    reserved_seconds = required_seconds
                                await upstream.send(request(200, session, pcm=message))
                            elif message == '{"type":"finish"}':
                                await upstream.send(request(102, session)); return
                            else: raise ValueError('invalid client message')
                    async def download():
                        segments = {'source': 0, 'translation': 0}
                        async for message in upstream:
                            data = parse(message); event = data.get(2)
                            if event in (650, 653):
                                kind = 'source' if event == 650 else 'translation'; segments[kind] += 1
                            elif event in (651, 652, 654, 655):
                                kind = 'source' if event in (651, 652) else 'translation'
                                raw = data.get(4, b'')
                                if not isinstance(raw, bytes) or len(raw) > 16000: raise ValueError('invalid text')
                                await client.send(json.dumps({'type':kind, 'text':raw.decode('utf-8'), 'final': event in (652,655), 'segment':segments[kind]}, ensure_ascii=False))
                            elif event == 152:
                                await client.send(json.dumps({'type':'finished'})); return
                            elif event in (151,153): raise ValueError('provider failed')
                        raise ConnectionError('provider disconnected')
                    async def check_session():
                        while True:
                            await asyncio.sleep(self.session_check_interval)
                            current = await asyncio.to_thread(self.account_store.authenticate, digest)
                            if current != account: raise PermissionError('session ended')
                    sender = asyncio.create_task(upload()); receiver = asyncio.create_task(download())
                    monitor = asyncio.create_task(check_session()) if account is not None else None
                    try:
                        tasks = {sender, receiver} | ({monitor} if monitor is not None else set())
                        done, _ = await asyncio.wait(tasks, timeout=1800, return_when=asyncio.FIRST_COMPLETED)
                        if not done: raise TimeoutError('session time limit')
                        for task in done: task.result()
                        if sender in done and receiver not in done:
                            remaining = {receiver} | ({monitor} if monitor is not None else set())
                            finished, _ = await asyncio.wait(remaining, timeout=15, return_when=asyncio.FIRST_COMPLETED)
                            if not finished: raise TimeoutError('provider did not finish')
                            for task in finished: task.result()
                    finally:
                        for task in tasks: task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)
            except Exception:
                try: await client.send(json.dumps({'type':'error','message':'语音服务暂不可用'})); await client.close(1011, 'speech unavailable')
                except Exception: pass

async def run_local():
    key = os.environ.get('MORIQ_SPEECH_PROVIDER_KEY', '')
    hashes = [x for x in os.environ.get('MORIQ_SPEECH_TOKEN_HASHES','').split(',') if x]
    db_path = os.environ.get('MORIQ_ACCOUNT_DB')
    if db_path and hashes: raise ValueError('choose one account source')
    if db_path:
        from account_store import AccountStore
        gateway = SpeechGateway(key, account_store=AccountStore(db_path))
    else: gateway = SpeechGateway(key, hashes)
    async with serve(gateway.handle, '127.0.0.1', int(os.environ.get('MORIQ_SPEECH_PORT','8777')), max_size=8192, compression=None):
        await asyncio.Future()

if __name__ == '__main__': asyncio.run(run_local())
