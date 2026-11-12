import asyncio
import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import tempfile

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('speech_gateway', ROOT / 'Services/ManagedAI/speech_gateway.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
TOKEN = 'a' * 32

async def provider(ws):
    assert ws.request.headers['X-Api-Key'] == 'synthetic-provider-key'
    start = g.parse(await ws.recv()); assert start[2] == 100
    assert g.parse(start[6])[1] == b's2t'
    assert g.parse(start[4])[7] == 16000
    await ws.send(g.field(2,150))
    audio = g.parse(await ws.recv()); assert audio[2] == 200 and len(g.parse(audio[4])[14]) == 2560 and any(g.parse(audio[4])[14])
    await ws.send(g.field(2,650))
    await ws.send(g.field(2,651) + g.field(4,'Hello'))
    await ws.send(g.field(2,652) + g.field(4,'Hello world.'))
    await ws.send(g.field(2,653))
    await ws.send(g.field(2,654) + g.field(4,'你好'))
    await ws.send(g.field(2,655) + g.field(4,'你好，世界。'))
    assert g.parse(await ws.recv())[2] == 102
    await ws.send(g.field(2,152))

async def test(binary):
    async with serve(provider, '127.0.0.1', 0, compression=None) as upstream:
        upstream_port = upstream.sockets[0].getsockname()[1]
        gateway = g.SpeechGateway('synthetic-provider-key', [hashlib.sha256(TOKEN.encode()).hexdigest()], upstream=f'ws://127.0.0.1:{upstream_port}', testing=True)
        async with serve(gateway.handle, '127.0.0.1', 0, compression=None) as server:
            port = server.sockets[0].getsockname()[1]
            async with connect(f'ws://127.0.0.1:{port}/v1/speech/stream', additional_headers={'Authorization':'Bearer '+('b'*32)}, proxy=None) as ws:
                try: await ws.recv(); raise AssertionError('bad token accepted')
                except Exception as e: assert getattr(e, 'code', None) == 1008
            proc = await asyncio.create_subprocess_exec(binary, str(port), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            out, err = await asyncio.wait_for(proc.communicate(), 20)
            assert proc.returncode == 0, (out,err)
            print(out.decode().strip())
            print('PASS invalid account rejected')
    # Closing a user session must close upstream promptly rather than continue
    # streaming/charging after capture stops.
    closed = asyncio.Event()
    async def cancelled_provider(ws):
        try:
            assert g.parse(await ws.recv())[2] == 100
            await ws.send(g.field(2,150))
            async for message in ws:
                assert g.parse(message)[2] == 200
        finally:
            closed.set()
    async with serve(cancelled_provider, '127.0.0.1', 0, compression=None) as upstream:
        gateway = g.SpeechGateway('synthetic-provider-key', [hashlib.sha256(TOKEN.encode()).hexdigest()], upstream=f"ws://127.0.0.1:{upstream.sockets[0].getsockname()[1]}", testing=True)
        async with serve(gateway.handle, '127.0.0.1', 0, compression=None) as server:
            port = server.sockets[0].getsockname()[1]
            async with connect(f'ws://127.0.0.1:{port}/v1/speech/stream', additional_headers={'Authorization':'Bearer '+TOKEN}, proxy=None) as ws:
                await ws.send(json.dumps({'type':'start','source':'en','target':'zh'}))
                assert json.loads(await ws.recv())['type'] == 'ready'
                await ws.send(b'\x01\x02' * 1280)
            await asyncio.wait_for(closed.wait(), 5)
            print('PASS client disconnect closes upstream')

if __name__ == '__main__': asyncio.run(test(sys.argv[1]))
