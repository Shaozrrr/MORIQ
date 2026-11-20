import asyncio,pathlib,socket,tempfile,unittest,uuid
ROOT=pathlib.Path(__file__).resolve().parents[2]

class Tests(unittest.IsolatedAsyncioTestCase):
 async def test_swift_through_caddy(self):
  with tempfile.TemporaryDirectory() as tmp:
   binary=str(pathlib.Path(tmp)/'client')
   files=['MORIQ/LocalDiagnostics.swift','MORIQ/DeepSeek.swift','MORIQ/ManagedSpeechStream.swift','MORIQ/DeviceRenewalCandidate.swift','MORIQ/ManagedAIClient.swift','Tests/ManagedAI/dual_lease_client.swift']
   build=await asyncio.create_subprocess_exec('swiftc','-DDEBUG',*[str(ROOT/f) for f in files],'-o',binary);self.assertEqual(await build.wait(),0)
   with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
   name='moriq-caddy-test-'+uuid.uuid4().hex[:12]
   proc=await asyncio.create_subprocess_exec('docker','run','--rm','--name',name,'-p',f'127.0.0.1:{port}:18080','--mount',f'type=bind,src={ROOT}/Services/DeviceActivationCandidate/test_caddy_stack.py,dst=/app/test_caddy_stack.py,readonly','--entrypoint','python','moriq-device-candidate:local','/app/test_caddy_stack.py','--external',stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
   try:
    line=(await asyncio.wait_for(proc.stdout.readline(),15)).decode().strip()
    self.assertTrue(line.startswith('READY '),'container failed before readiness')
    invite=line.split(' ',1)[1];base=f'127.0.0.1:{port}'
    client=await asyncio.create_subprocess_exec(binary,f'http://{base}/v1/devices/renew',invite,f'ws://{base}/v1/speech/stream',f'http://{base}/v1/chat/completions')
    self.assertEqual(await asyncio.wait_for(client.wait(),20),0)
   finally:
    remove=await asyncio.create_subprocess_exec('docker','rm','-f',name,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL);await remove.wait()
    try:await asyncio.wait_for(proc.wait(),5)
    except asyncio.TimeoutError:proc.kill();await proc.wait()

if __name__=='__main__':unittest.main()
