"""Bounded direct TLS transport for the isolated DeepL experiment.

No proxy, redirects, retries or request/response logging. Injected connection
factory is for local tests; use the default TLS-verifying factory in real use.
"""
import asyncio
import http.client
import ssl
import threading
import time
from deepl_experiment import DeepLExperiment

_HOSTS={DeepLExperiment.FREE:'api-free.deepl.com',DeepLExperiment.PRO:'api.deepl.com'}
SYSTEM_CA='/etc/ssl/cert.pem'
_LIVE_SEND_SLOTS=threading.BoundedSemaphore(2)

def verified_system_context():
    # Fail closed if the configured system CA bundle is missing or unusable.
    context=ssl.create_default_context(cafile=SYSTEM_CA)
    if context.verify_mode != ssl.CERT_REQUIRED or not context.check_hostname:
        raise ssl.SSLError('TLS verification unavailable')
    return context

class DirectDeepLTransport:
    def __init__(self, connection_factory=None, *, diagnostic=None):
        self._factory=connection_factory or (lambda host,timeout: http.client.HTTPSConnection(host,timeout=timeout,context=verified_system_context()))
        self._diagnostic=diagnostic
    async def __call__(self, *, url, headers, body, timeout, allow_redirects, max_response_bytes):
        if url not in _HOSTS or allow_redirects is not False or type(max_response_bytes) is not int or not 1<=max_response_bytes<=32768 or not 0<timeout<=10 or not isinstance(body,bytes) or len(body)>131072:
            raise ValueError('invalid transport request')
        cancelled=threading.Event()
        queued=time.monotonic()
        def send():
            with _LIVE_SEND_SLOTS:
                if cancelled.is_set():raise TimeoutError('cancelled before send')
                if self._diagnostic:
                    try:self._diagnostic({'stage':'http_queue','outcome':'started','status':None,'elapsed_ms':round((time.monotonic()-queued)*1000)})
                    except Exception:pass
                conn=self._factory(_HOSTS[url],timeout)
                started=time.monotonic();outcome='error';status=None
                try:
                    if cancelled.is_set():raise TimeoutError('cancelled before send')
                    conn.request('POST','/v2/translate',body=body,headers=headers)
                    response=conn.getresponse()
                    status=response.status
                    if response.status != 200:outcome='http_error';return response.status,b''
                    raw=response.read(max_response_bytes+1)
                    if len(raw)>max_response_bytes:raise ValueError('response too large')
                    outcome='ok'
                    return response.status,raw
                finally:
                    conn.close()
                    if self._diagnostic:
                        try:self._diagnostic({'stage':'http','outcome':outcome,'status':status if type(status) is int and 100<=status<=599 else None,'elapsed_ms':round((time.monotonic()-started)*1000)})
                        except Exception:pass
        try:return await asyncio.to_thread(send)
        except asyncio.CancelledError:
            cancelled.set();raise
