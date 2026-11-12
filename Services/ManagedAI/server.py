"""Local reference gateway; intentionally loopback-only, not production deployment."""
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 48 * 1024 * 1024
MAX_STREAM = 8 * 1024 * 1024

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class Gateway:
    def __init__(self, upstream, model, provider_key, token_hashes=None, *, account_store=None, test_mode=False):
        parsed = urllib.parse.urlsplit(upstream)
        if parsed.username or parsed.password or parsed.fragment or not parsed.hostname:
            raise ValueError('invalid upstream')
        if parsed.scheme != 'https':
            try: loopback = ipaddress.ip_address(parsed.hostname).is_loopback
            except ValueError: loopback = False
            if not (test_mode and parsed.scheme == 'http' and loopback):
                raise ValueError('upstream must use HTTPS')
        if not provider_key or not model:
            raise ValueError('server credentials and account token hashes required')
        if account_store is None:
            if not isinstance(token_hashes, dict) or not 1 <= len(token_hashes) <= 10000 or any(not isinstance(v, str) or not v for v in token_hashes.values()):
                raise ValueError('server credentials and account token hashes required')
            if any(len(h) != 64 or any(c not in '0123456789abcdef' for c in h) for h in token_hashes):
                raise ValueError('account token hashes must be lowercase SHA256')
        elif token_hashes is not None:
            raise ValueError('choose one account source')
        self.upstream, self.model, self.key, self.accounts, self.account_store = upstream, model, provider_key, token_hashes, account_store
        self.opener = urllib.request.build_opener(NoRedirect())
        self.lock, self.history = threading.Lock(), defaultdict(deque)

    def authorize(self, header):
        if not header.startswith('Bearer '): return None
        token = header[7:]
        if not 32 <= len(token) <= 256 or any(ord(c) < 33 or ord(c) > 126 for c in token): return None
        digest = hashlib.sha256(token.encode('ascii')).hexdigest()
        if self.account_store is not None:
            return self.account_store.authenticate(digest)
        account = None
        for expected, identity in self.accounts.items():
            if hmac.compare_digest(expected, digest): account = identity
        return account

    def allow(self, account):
        now = time.monotonic()
        identity = account.account if self.account_store is not None else account
        with self.lock:
            q = self.history[identity]
            while q and q[0] <= now - 60: q.popleft()
            if len(q) >= 12: return False
            q.append(now)
        return self.account_store.consume(account) if self.account_store is not None else True

    def payload(self, data):
        try: obj = json.loads(data)
        except (ValueError, UnicodeDecodeError): raise ValueError('invalid JSON')
        if not isinstance(obj, dict) or not isinstance(obj.get('messages'), list): raise ValueError('invalid messages')
        messages = obj['messages']
        if not 1 <= len(messages) <= 200: raise ValueError('invalid message count')
        image_count = 0
        for m in messages:
            if not isinstance(m, dict) or set(m) != {'role', 'content'} or m.get('role') not in ('user','assistant','system'): raise ValueError('invalid role')
            c = m.get('content')
            if isinstance(c, str):
                if len(c.encode()) > 250_000: raise ValueError('text too large')
            elif isinstance(c, list) and m['role'] == 'user' and 1 <= len(c) <= 12:
                for part in c:
                    if not isinstance(part, dict): raise ValueError('invalid part')
                    if set(part) == {'type', 'text'} and part.get('type') == 'text' and isinstance(part.get('text'), str) and len(part['text'].encode()) <= 250_000: continue
                    image = part.get('image_url')
                    uri = image.get('url') if isinstance(image, dict) else None
                    if set(part) != {'type', 'image_url'} or not isinstance(image, dict) or set(image) != {'url'} or part.get('type') != 'image_url' or not isinstance(uri, str) or not uri.startswith('data:image/jpeg;base64,'): raise ValueError('invalid image')
                    try: decoded = base64.b64decode(uri[len('data:image/jpeg;base64,'):], validate=True)
                    except (ValueError, TypeError): raise ValueError('invalid image')
                    if len(decoded) > 32 * 1024 * 1024 or not decoded.startswith(b'\xff\xd8\xff'): raise ValueError('invalid image')
                    image_count += 1
                    if image_count > 22: raise ValueError('too many images')
            else: raise ValueError('invalid content')
        return json.dumps({'model': self.model, 'stream': True, 'messages': messages}, ensure_ascii=False, separators=(',', ':')).encode()

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, addr, gateway):
        if not ipaddress.ip_address(addr[0]).is_loopback: raise ValueError('reference server must bind loopback')
        self.gateway = gateway
        # Full-screen histories can approach 48 MiB; bound concurrent memory.
        self.slots = threading.BoundedSemaphore(2)
        super().__init__(addr, Handler)
    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            request.close(); return
        try: super().process_request(request, address)
        except BaseException:
            self.slots.release(); raise
    def process_request_thread(self, request, address):
        try: super().process_request_thread(request, address)
        finally: self.slots.release()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def reply(self, status, message):
        data = json.dumps({'error': message}).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.send_header('Cache-Control','no-store'); self.send_header('Connection','close'); self.end_headers(); self.close_connection = True; self.wfile.write(data)
    def do_POST(self):
        if self.path != '/v1/chat/completions': self.reply(404, 'not found'); return
        gateway = self.server.gateway
        try:
            account = gateway.authorize(self.headers.get('Authorization', ''))
            if not account: self.reply(401, 'unauthorized'); return
            if not gateway.allow(account): self.reply(429, 'rate limited'); return
        except (sqlite3.Error, OSError, ValueError):
            self.reply(503, 'service unavailable'); return
        if self.headers.get('Transfer-Encoding'): self.reply(400, 'unsupported transfer'); return
        try: length = int(self.headers.get('Content-Length', ''))
        except ValueError: self.reply(411, 'length required'); return
        if length < 1 or length > MAX_BODY: self.reply(413, 'request too large'); return
        self.connection.settimeout(20)
        try:
            body = self.rfile.read(length)
            if len(body) != length: raise ValueError('truncated request')
            payload = gateway.payload(body)
        except (ValueError, TimeoutError): self.reply(400, 'invalid request'); return
        req = urllib.request.Request(gateway.upstream, data=payload, headers={'Authorization': 'Bearer ' + gateway.key, 'Content-Type':'application/json', 'Accept':'text/event-stream'}, method='POST')
        started = False
        try:
            with gateway.opener.open(req, timeout=90) as response:
                if response.status != 200 or 'text/event-stream' not in response.headers.get('Content-Type','').lower(): self.reply(502, 'upstream unavailable'); return
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Cache-Control','no-store'); self.send_header('Connection','close'); self.end_headers()
                started = True
                self.close_connection = True
                read = 0
                while True:
                    block = response.read1(4096)
                    if not block: break
                    read += len(block)
                    if read > MAX_STREAM: break
                    self.wfile.write(block); self.wfile.flush()
        except (urllib.error.URLError, OSError, TimeoutError):
            if not started:
                try: self.reply(502, 'upstream unavailable')
                except OSError: pass
            self.close_connection = True

def main():
    database = os.environ.get('MORIQ_ACCOUNT_DB')
    if database:
        from account_store import AccountStore
        gateway = Gateway(os.environ['MORIQ_UPSTREAM_URL'], os.environ['MORIQ_UPSTREAM_MODEL'], os.environ['MORIQ_PROVIDER_SECRET'], account_store=AccountStore(database))
    else:
        accounts = json.loads(os.environ['MORIQ_ACCOUNT_TOKEN_HASHES'])
        gateway = Gateway(os.environ['MORIQ_UPSTREAM_URL'], os.environ['MORIQ_UPSTREAM_MODEL'], os.environ['MORIQ_PROVIDER_SECRET'], accounts)
    Server(('127.0.0.1', int(os.environ.get('MORIQ_PORT','8080'))), gateway).serve_forever()
if __name__ == '__main__': main()
