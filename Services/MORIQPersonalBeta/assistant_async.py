"""Bounded loopback candidate; not a public production service."""
import asyncio,hashlib,ipaddress,json,re,ssl,sys,urllib.parse
from aiohttp import web,ClientSession,ClientTimeout,TCPConnector,ClientConnectorCertificateError,ClientConnectorDNSError,ClientConnectorError
from assistant_server import VisionUnavailable,MAX_BODY

def verified_tls_context():
 # Python.org macOS runtimes may have no default trust store. Use macOS's
 # system CA bundle while retaining certificate and hostname verification.
 return ssl.create_default_context(cafile='/etc/ssl/cert.pem') if sys.platform=='darwin' else ssl.create_default_context()

def transport_error_code(error):
 if isinstance(error,(ClientConnectorCertificateError,ssl.SSLCertVerificationError)):return 'TLS_VERIFY_FAILED'
 if isinstance(error,ClientConnectorDNSError):return 'DNS_ERROR'
 if isinstance(error,asyncio.TimeoutError):return 'TIMEOUT'
 if isinstance(error,ClientConnectorError):return 'CONNECT_ERROR'
 return 'TRANSPORT_UNKNOWN'

def validate_upstream(upstream,*,testing=False):
 u=urllib.parse.urlsplit(upstream)
 if u.username is not None or u.password is not None or u.query or u.fragment or u.path!='/v1/chat/completions' or not u.hostname:raise ValueError('invalid upstream')
 if u.scheme=='https' and u.hostname=='api.example-provider.invalid' and u.port in (None,443):return
 if testing and u.scheme=='https' and u.hostname=='api.deepseek.com' and u.port in (None,443):return
 if testing and u.scheme=='http' and u.hostname=='127.0.0.1' and u.port:return
 raise ValueError('upstream not allowed')

def make_app(gateway,upstream,*,testing=False,max_concurrent=2,body_timeout=5,recorder=None,rate_version=None,metric_provider=None,require_operation_id=False,reserved_tokens=None):
 validate_upstream(upstream,testing=testing)
 if type(require_operation_id) is not bool:raise ValueError('invalid operation policy')
 if reserved_tokens is not None and (type(reserved_tokens) is not int or not 1<=reserved_tokens<=100_000_000):raise ValueError('invalid token reservation')
 if type(max_concurrent) is not int or not 1<=max_concurrent<=8 or not 0<body_timeout<=20:raise ValueError('invalid bounds')
 slots=asyncio.Semaphore(max_concurrent)
 async def chat_inner(request,event,state):
  try:await asyncio.wait_for(slots.acquire(),.05)
  except asyncio.TimeoutError:return web.Response(status=503)
  try:
   account=await asyncio.to_thread(gateway.authorize,request.headers.get('Authorization',''))
   if not account:return web.Response(status=401)
   if request.content_length is None:return web.Response(status=411)
   if request.content_length<1 or request.content_length>MAX_BODY:return web.Response(status=413)
   try:
    data=await asyncio.wait_for(request.content.readexactly(request.content_length),body_timeout)
    payload=gateway.payload(data)
   except VisionUnavailable:return web.Response(status=422)
   except asyncio.TimeoutError:return web.Response(status=408)
   except (ValueError,asyncio.IncompleteReadError):return web.Response(status=400)
   if await asyncio.to_thread(gateway.account_store.authenticate,account.token_hash)!=account:return web.Response(status=401)
   # Consume quota only after the full request has been validated. Invalid or
   # stalled bodies must not spend a legitimate user's request allowance.
   operation=request.headers.get('MORIQ-Operation-ID')
   if require_operation_id and operation is None:return web.Response(status=400)
   if operation is not None and not re.fullmatch(r'[0-9a-f]{32}',operation):return web.Response(status=400)
   claim_id=hashlib.sha256((account.account+'\0'+operation).encode()).hexdigest()[:32] if operation is not None else (event.request_id if event is not None else None)
   if not await asyncio.to_thread(gateway.allow,account,claim_id,event.request_id if event is not None else None,reserved_tokens):
    if operation is not None and await asyncio.to_thread(gateway.account_store.has_claim,account,claim_id):return web.Response(status=409)
    return web.Response(status=429)
   if event is not None:await asyncio.to_thread(event.attach_claim,claim_id)
   task=asyncio.current_task()
   async def revocation_watch():
    while True:
     await asyncio.sleep(.1)
     if await asyncio.to_thread(gateway.account_store.authenticate,account.token_hash)!=account:task.cancel();return
   watcher=asyncio.create_task(revocation_watch())
   try:
    if event is not None:await asyncio.to_thread(event.mark_dispatch)
    async with ClientSession(timeout=ClientTimeout(total=30),trust_env=False,connector=TCPConnector(ssl=verified_tls_context())) as session:
     async with session.post(upstream,data=payload,headers={'Content-Type':'application/json','Accept':'text/event-stream','Authorization':'Bearer '+gateway.key},allow_redirects=False) as resp:
      if event is not None:await asyncio.to_thread(event.mark_provider_response)
      if resp.status!=200:return web.Response(status=502,headers={'MORIQ-Error-Code':'UPSTREAM_HTTP_ERROR','MORIQ-Upstream-Status':str(resp.status)})
      if resp.content_type!='text/event-stream':return web.Response(status=502,headers={'MORIQ-Error-Code':'RESPONSE_INVALID'})
      if await asyncio.to_thread(gateway.account_store.authenticate,account.token_hash)!=account:return web.Response(status=401)
      output=web.StreamResponse(status=200,headers={'Content-Type':'text/event-stream','Cache-Control':'no-store'});await output.prepare(request);state['response_started']=True;total=0;pending=b'';done=False
      async for block in resp.content.iter_any():
       if await asyncio.to_thread(gateway.account_store.authenticate,account.token_hash)!=account:break
       total+=len(block)
       if total>8*1024*1024:break
       pending+=block
       while b'\n' in pending:
        line,pending=pending.split(b'\n',1)
        if len(line)>65536:raise ValueError('SSE line too large')
        if event is not None and line.startswith(b'data: {'):
         try:
          event.observe_usage(json.loads(line[6:]).get('usage'))
         except (ValueError,AttributeError):pass
        if line.rstrip(b'\r')==b'data: [DONE]':
         if event is not None:
          event.mark_usage_final();state['finish_attempted']=True
          try:await asyncio.to_thread(event.finish,'success',retries=0)
          except Exception:
           recorder.poison()
           if request.transport:request.transport.abort()
           raise asyncio.CancelledError() from None
          if reserved_tokens is not None and event.usage is not None:
           try:
            settled=await asyncio.to_thread(gateway.account_store.settle_tokens,account,claim_id,event.usage[0]+event.usage[1])
            if not settled:raise ValueError('token settlement failed')
           except Exception:
            recorder.poison()
            if request.transport:request.transport.abort()
            raise asyncio.CancelledError() from None
         await output.write(line+b'\n\n');done=True;break
        await output.write(line+b'\n')
       if done:break
       if len(pending)>65536:break
      if not done:
       if request.transport:request.transport.abort()
       raise asyncio.CancelledError()
      return output
   finally:
    watcher.cancel();await asyncio.gather(watcher,return_exceptions=True)
  finally:slots.release()
 async def chat(request):
  try:event=recorder.start(kind='assistant',model=gateway.model,provider=metric_provider,rate_version=rate_version) if recorder is not None else None
  except Exception:return web.Response(status=503)
  outcome='failure';state={'finish_attempted':False,'response_started':False}
  try:
   response=await chat_inner(request,event,state)
   if response.status<400:outcome='success'
   return response
  except asyncio.CancelledError:
   outcome='cancelled';raise
  except Exception as error:
   if state['response_started']:
    if request.transport:request.transport.abort()
    raise asyncio.CancelledError() from None
   return web.Response(status=502,headers={'MORIQ-Error-Code':transport_error_code(error)})
  finally:
   if event is not None and not state['finish_attempted']:
    try:await asyncio.to_thread(event.finish,outcome,retries=0)
    except Exception:
     recorder.poison()
     if request.transport:request.transport.abort()
 app=web.Application(client_max_size=MAX_BODY);app.router.add_post('/v1/chat/completions',chat);return app
