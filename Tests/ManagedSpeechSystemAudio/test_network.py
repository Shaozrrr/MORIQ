import asyncio, hashlib, importlib.util, pathlib, sys
from websockets.asyncio.server import serve
ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('speech_gateway', ROOT/'Services/ManagedAI/speech_gateway.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
async def provider(ws):
    assert g.parse(await ws.recv())[2] == 100
    await ws.send(g.field(2,150))
    count = 0
    async for message in ws:
        obj = g.parse(message)
        if obj[2] == 200:
            audio = g.parse(obj[4])[14]; assert len(audio) == 2560
            count += 1
            if count == 3:
                await ws.send(g.field(2,650)); await ws.send(g.field(2,652)+g.field(4,'Synthetic test.'))
                await ws.send(g.field(2,653)); await ws.send(g.field(2,655)+g.field(4,'合成测试。'))
async def run(binary):
    async with serve(provider,'127.0.0.1',0,compression=None) as upstream:
        gateway = g.SpeechGateway('synthetic-provider-key',[hashlib.sha256(('a'*32).encode()).hexdigest()],upstream=f'ws://127.0.0.1:{upstream.sockets[0].getsockname()[1]}',testing=True)
        async with serve(gateway.handle,'127.0.0.1',0,compression=None) as server:
            proc = await asyncio.create_subprocess_exec(binary,str(server.sockets[0].getsockname()[1]),stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
            try: out,err = await asyncio.wait_for(proc.communicate(),25)
            except asyncio.TimeoutError:
                proc.terminate(); await proc.wait(); raise RuntimeError('test timed out; test process stopped')
            print(out.decode().strip())
            if proc.returncode: print(err.decode()[-1000:]); raise SystemExit(proc.returncode)
asyncio.run(run(sys.argv[1]))
