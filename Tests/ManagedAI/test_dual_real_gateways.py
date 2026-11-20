import asyncio,pathlib,sys,tempfile,unittest
from aiohttp import web
from aiohttp.test_utils import TestServer
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/DeviceActivationCandidate'));sys.path.insert(0,str(ROOT/'Services/ManagedGatewayCandidate'))
from account_store import AccountStore
from activation import Activation
from activation_http import make_app as activation_app
from device_scopes import ScopedAccountStore
from soniox_gateway import SonioxGateway
from assistant_server import Gateway
from assistant_async import make_app as assistant_app

class Tests(unittest.IsolatedAsyncioTestCase):
 async def test_two_real_gateways(self):
  with tempfile.TemporaryDirectory() as tmp:
   store=AccountStore(str(pathlib.Path(tmp)/'db'));store.put_global_limits(20,120);store.put_account('friend',10);store.put_speech_limit('friend',60)
   activation=Activation(store);invite=activation.issue('friend',scopes=('speech','assistant'))
   activation_server=TestServer(activation_app(activation));await activation_server.start_server()
   async def chat(req):
    await req.read();return web.Response(body=b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n',content_type='text/event-stream')
   upstream_app=web.Application();upstream_app.router.add_post('/v1/chat/completions',chat);upstream=TestServer(upstream_app);await upstream.start_server()
   upstream_url=str(upstream.make_url('/v1/chat/completions'))
   assistant=Gateway(upstream_url,'fake','fake',account_store=ScopedAccountStore(store,'assistant'),test_mode=True)
   assistant_server=TestServer(assistant_app(assistant,upstream_url,testing=True));await assistant_server.start_server()
   async def speech_upstream(ws):
    try:
     async for _ in ws:pass
    except ConnectionClosed:pass
   try:
    async with serve(speech_upstream,'127.0.0.1',0) as speech_provider:
     gateway=SonioxGateway('fake',account_store=ScopedAccountStore(store,'speech'),upstream=f'ws://127.0.0.1:{speech_provider.sockets[0].getsockname()[1]}/transcribe-websocket',testing=True)
     async with serve(gateway.handle,'127.0.0.1',0) as speech_server:
      binary=str(pathlib.Path(tmp)/'dual')
      files=['MORIQ/LocalDiagnostics.swift','MORIQ/DeepSeek.swift','MORIQ/ManagedSpeechStream.swift','MORIQ/DeviceRenewalCandidate.swift','MORIQ/ManagedAIClient.swift','Tests/ManagedAI/dual_lease_client.swift']
      build=await asyncio.create_subprocess_exec('swiftc','-DDEBUG',*[str(ROOT/f) for f in files],'-o',binary);self.assertEqual(await build.wait(),0)
      speech_url=f'ws://127.0.0.1:{speech_server.sockets[0].getsockname()[1]}/v1/speech/stream'
      proc=await asyncio.create_subprocess_exec(binary,str(activation_server.make_url('/v1/devices/renew')),invite,speech_url,str(assistant_server.make_url('/v1/chat/completions')))
      self.assertEqual(await asyncio.wait_for(proc.wait(),20),0)
   finally:await assistant_server.close();await upstream.close();await activation_server.close()

if __name__=='__main__':unittest.main()
