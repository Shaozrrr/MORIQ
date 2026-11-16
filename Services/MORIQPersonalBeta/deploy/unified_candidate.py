"""Opt-in single-port supervisor candidate. Never run without review."""
import asyncio, os, pathlib, re, signal, subprocess, sys, tempfile
from contextlib import asynccontextmanager
from aiohttp import web
from websockets.asyncio.server import serve
ROOT=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT))
from assistant_async import make_app
from assistant_server import Gateway
from start_railway_staging import locked_configure,build_router,readiness_routes,main as speech_main

# No arbitrary URL: this candidate cannot currently reach a real vendor.
ASSISTANT_UPSTREAM='https://api.example-provider.invalid/v1/chat/completions'

def enabled(env):
 value=env.get('MORIQ_UNIFIED_ASSISTANT','0')
 if value not in ('0','1'):raise ValueError('invalid unified setting')
 if value=='1' and env.get('MORIQ_UNIFIED_ACK')!='reviewed-single-instance':raise ValueError('missing unified acknowledgement')
 return value=='1'

def proxy_only(env):
 value=env.get('MORIQ_UNIFIED_PROXY_ONLY','0')
 if value not in ('0','1'):raise ValueError('invalid proxy setting')
 if value=='1' and (env.get('MORIQ_UNIFIED_ACK')!='reviewed-single-instance' or enabled(env)):
  raise ValueError('invalid proxy-only configuration')
 return value=='1'

def validate(env):
 if not enabled(env):return False
 if env.get('MORIQ_METRICS_ACK')!='private-metadata-fail-closed' or not env.get('MORIQ_METRICS_DB'):raise ValueError('metrics required')
 key=env.get('MORIQ_ASSISTANT_PROVIDER_KEY','')
 if not isinstance(key,str) or not 1<=len(key)<=512 or not key.isascii() or any(ord(c)<33 or ord(c)>126 for c in key):raise ValueError('assistant credential missing or invalid')
 if env.get('MORIQ_ASSISTANT_MODEL')!='deepseek-flash':raise ValueError('unsupported assistant model')
 raw=env.get('MORIQ_ASSISTANT_TOKEN_RESERVATION','')
 if not raw.isascii() or not raw.isdecimal() or not 1<=int(raw)<=100_000_000:raise ValueError('token reservation missing or invalid')
 return True

def caddyfile(port,speech_port,chat_port):
 if any(type(x) is not int or not 1<=x<=65535 for x in (port,speech_port)) or (chat_port is not None and (type(chat_port) is not int or not 1<=chat_port<=65535)):raise ValueError('invalid port')
 chat='  respond 404\n' if chat_port is None else '  request_body {\n   max_size 48MB\n  }\n  reverse_proxy 127.0.0.1:'+str(chat_port)+'\n'
 return ('{\n auto_https off\n admin off\n servers {\n  timeouts {\n   read_header 5s\n   read_body 10s\n  }\n }\n}\n:'+str(port)+' {\n handle /v1/chat/completions {\n'+chat+' }\n handle {\n  reverse_proxy 127.0.0.1:'+str(speech_port)+'\n }\n}\n')

@asynccontextmanager
async def backends(gateway,env,assistant_enabled=True):
 # Both handlers share the same authenticated account and recorder instances.
 speech=await serve(build_router(gateway),'127.0.0.1',0,max_size=8192,compression=None,process_request=readiness_routes(gateway.metrics))
 runner=None
 try:
  if not assistant_enabled:
   yield speech.sockets[0].getsockname()[1],None
   return
  assistant=Gateway(ASSISTANT_UPSTREAM,env['MORIQ_ASSISTANT_MODEL'],env['MORIQ_ASSISTANT_PROVIDER_KEY'],account_store=gateway.accounts,supports_images=True)
  app=make_app(assistant,ASSISTANT_UPSTREAM,recorder=gateway.metrics,metric_provider='deepseek',require_operation_id=True,reserved_tokens=int(env['MORIQ_ASSISTANT_TOKEN_RESERVATION']))
  runner=web.AppRunner(app,access_log=None,handler_cancellation=True);await runner.setup();site=web.TCPSite(runner,'127.0.0.1',0);await site.start()
  yield speech.sockets[0].getsockname()[1],site._server.sockets[0].getsockname()[1]
 finally:
  if runner is not None:await runner.cleanup()
  speech.close();await speech.wait_closed()

async def run_unified(gateway,port,env,stop):
 manager=backends(gateway,env,assistant_enabled=False) if proxy_only(env) else backends(gateway,env)
 async with manager as (sp,ap):
  with tempfile.TemporaryDirectory(prefix='moriq-caddy-') as temp:
   conf=pathlib.Path(temp)/'Caddyfile';conf.write_text(caddyfile(port,sp,ap));os.chmod(conf,0o600)
   process=await asyncio.create_subprocess_exec('caddy','run','--config',str(conf),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'HOME':temp})
   stopper=asyncio.create_task(stop.wait());waiter=asyncio.create_task(process.wait())
   try:
    done,_=await asyncio.wait({stopper,waiter},return_when=asyncio.FIRST_COMPLETED)
    if waiter in done and not stop.is_set():raise RuntimeError('proxy stopped')
   finally:
    stopper.cancel();waiter.cancel();await asyncio.gather(stopper,waiter,return_exceptions=True)
    if process.returncode is None:
     process.terminate()
     try:await asyncio.wait_for(process.wait(),5)
     except asyncio.TimeoutError:process.kill();await process.wait()

def main():
 assistant_on=validate(os.environ);proxy_on=proxy_only(os.environ)
 if not assistant_on and not proxy_on:return speech_main()
 with locked_configure(os.environ) as (gateway,host,port,db):
  async def serve_until_signal():
   loop=asyncio.get_running_loop();stop=asyncio.Event()
   for sig in (signal.SIGINT,signal.SIGTERM):loop.add_signal_handler(sig,stop.set)
   try:await run_unified(gateway,port,os.environ,stop)
   finally:
    for sig in (signal.SIGINT,signal.SIGTERM):loop.remove_signal_handler(sig)
  asyncio.run(serve_until_signal())
if __name__=='__main__':
 try:main()
 except Exception:print('MORIQ unified startup failed; review configuration.',file=sys.stderr);sys.exit(1)
