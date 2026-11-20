import asyncio,hashlib,pathlib,sys,tempfile,unittest
from aiohttp import web
from aiohttp.test_utils import TestServer
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/DeviceActivationCandidate'));sys.path.insert(0,str(ROOT/'Services/ManagedGatewayCandidate'))
from account_store import AccountStore
from activation import Activation
from activation_http import make_app
from device_scopes import ScopedAccountStore

class Tests(unittest.IsolatedAsyncioTestCase):
 async def test_client_activation_renew_and_scope(self):
  with tempfile.TemporaryDirectory() as tmp:
   store=AccountStore(str(pathlib.Path(tmp)/'db'));store.put_global_limits(20,120);store.put_account('friend',10);store.put_speech_limit('friend',60)
   activation=Activation(store);invite=activation.issue('friend');observed=[]
   app=make_app(activation)
   async def verify(request):
    token=(await request.read()).decode('ascii');digest=hashlib.sha256(token.encode()).hexdigest()
    observed.append((ScopedAccountStore(store,'speech').authenticate(digest) is not None,ScopedAccountStore(store,'assistant').authenticate(digest) is None))
    return web.Response(status=204)
   app.router.add_post('/test-check',verify)
   server=TestServer(app);await server.start_server()
   try:
    binary=str(pathlib.Path(tmp)/'test')
    build=await asyncio.create_subprocess_exec('swiftc','-DDEBUG',str(ROOT/'MORIQ/DeviceRenewalCandidate.swift'),str(ROOT/'Tests/ManagedAI/device_activation_full.swift'),'-o',binary)
    self.assertEqual(await build.wait(),0)
    proc=await asyncio.create_subprocess_exec(binary,str(server.make_url('/v1/devices/renew')),invite,str(server.make_url('/test-check')))
    self.assertEqual(await asyncio.wait_for(proc.wait(),20),0);self.assertEqual(observed,[(True,True)])
    lease_binary=str(pathlib.Path(tmp)/'lease-test')
    build=await asyncio.create_subprocess_exec('swiftc','-DDEBUG',str(ROOT/'MORIQ/DeviceRenewalCandidate.swift'),str(ROOT/'Tests/ManagedAI/device_lease.swift'),'-o',lease_binary)
    self.assertEqual(await build.wait(),0)
    lease=await asyncio.create_subprocess_exec(lease_binary,str(server.make_url('/v1/devices/renew')),activation.issue('friend'))
    self.assertEqual(await asyncio.wait_for(lease.wait(),20),0)
   finally:await server.close()

if __name__=='__main__':unittest.main()
