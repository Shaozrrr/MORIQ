import asyncio,hashlib,json,pathlib,sys,tempfile,unittest
from aiohttp import web
from aiohttp.test_utils import TestServer
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/DeviceActivationCandidate'));sys.path.insert(0,str(ROOT/'Services/ManagedGatewayCandidate'))
from account_store import AccountStore
from activation import Activation
from activation_http import make_app
from device_scopes import ScopedAccountStore

class Tests(unittest.IsolatedAsyncioTestCase):
 async def test_speech_then_waiting_assistant(self):
  with tempfile.TemporaryDirectory() as tmp:
   store=AccountStore(str(pathlib.Path(tmp)/'db'));store.put_global_limits(20,120);store.put_account('friend',10);store.put_speech_limit('friend',60)
   activation=Activation(store);invite=activation.issue('friend',scopes=('speech','assistant'));app=make_app(activation)
   def authorize(req,scope):
    token=req.headers.get('Authorization','').removeprefix('Bearer ')
    return ScopedAccountStore(store,scope).authenticate(hashlib.sha256(token.encode()).hexdigest())
   async def speech(req):
    if not authorize(req,'speech'):return web.Response(status=401)
    ws=web.WebSocketResponse();await ws.prepare(req);await ws.receive();await ws.send_json({'type':'ready','mode':'transcription'})
    async for _ in ws:pass
    return ws
   async def chat(req):
    if not authorize(req,'assistant'):return web.Response(status=401)
    await req.read();return web.Response(body=b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n',content_type='text/event-stream')
   app.router.add_get('/v1/speech/stream',speech);app.router.add_post('/v1/chat/completions',chat)
   server=TestServer(app);await server.start_server()
   try:
    binary=str(pathlib.Path(tmp)/'dual')
    files=['MORIQ/LocalDiagnostics.swift','MORIQ/DeepSeek.swift','MORIQ/ManagedSpeechStream.swift','MORIQ/DeviceRenewalCandidate.swift','MORIQ/ManagedAIClient.swift','Tests/ManagedAI/dual_lease_client.swift']
    build=await asyncio.create_subprocess_exec('swiftc','-DDEBUG',*[str(ROOT/f) for f in files],'-o',binary)
    self.assertEqual(await build.wait(),0)
    speechurl=str(server.make_url('/v1/speech/stream')).replace('http://','ws://',1)
    process=await asyncio.create_subprocess_exec(binary,str(server.make_url('/v1/devices/renew')),invite,speechurl,str(server.make_url('/v1/chat/completions')))
    self.assertEqual(await asyncio.wait_for(process.wait(),20),0)
   finally:await server.close()

if __name__=='__main__':unittest.main()
