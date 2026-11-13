import asyncio
import hashlib
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import time

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('speech_gateway', ROOT / 'Services/ManagedAI/speech_gateway.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
sys.path.insert(0, str(ROOT / 'Services/ManagedAI'))
from account_store import AccountStore
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

    # Real SQLite account state must gate upstream sessions and a revocation
    # must terminate an active stream without waiting for another audio packet.
    with tempfile.TemporaryDirectory() as tmp:
        store = AccountStore(pathlib.Path(tmp) / 'accounts.sqlite')
        store.put_global_limits(100, 100)
        digest = hashlib.sha256(TOKEN.encode()).hexdigest()
        store.put_account('caption-user', 1)
        store.add_session('caption-user', digest, time.time() + 60)
        closed = asyncio.Event()
        provider_sessions = 0
        async def tracked_provider(ws):
            nonlocal provider_sessions
            provider_sessions += 1
            try:
                assert g.parse(await ws.recv())[2] == 100
                await ws.send(g.field(2,150))
                async for _ in ws: pass
            finally: closed.set()
        async with serve(tracked_provider, '127.0.0.1', 0, compression=None) as upstream:
            gateway = g.SpeechGateway('synthetic-provider-key', account_store=store, upstream=f"ws://127.0.0.1:{upstream.sockets[0].getsockname()[1]}", testing=True, session_check_interval=0.1)
            async with serve(gateway.handle, '127.0.0.1', 0, compression=None) as server:
                address = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/v1/speech/stream"
                async with connect(address, additional_headers={'Authorization':'Bearer '+TOKEN}, proxy=None) as ws:
                    await ws.send(json.dumps({'type':'start','source':'en','target':'zh'}))
                    assert json.loads(await ws.recv())['type'] == 'ready'
                    # Daily quota is enforced before creating another upstream.
                    async with connect(address, additional_headers={'Authorization':'Bearer '+TOKEN}, proxy=None) as second:
                        await second.send(json.dumps({'type':'start','source':'en','target':'zh'}))
                        try: await second.recv(); raise AssertionError('quota bypassed')
                        except Exception as e: assert getattr(e, 'code', None) == 1008
                    assert provider_sessions == 1
                    assert store.revoke(digest)
                    await asyncio.wait_for(closed.wait(), 3)
                    assert json.loads(await asyncio.wait_for(ws.recv(), 3))['type'] == 'error'
                async with connect(address, additional_headers={'Authorization':'Bearer '+TOKEN}, proxy=None) as revoked:
                    try: await revoked.recv(); raise AssertionError('revoked session accepted')
                    except Exception as e: assert getattr(e, 'code', None) == 1008
        print('PASS account quota gates upstream and revocation closes active stream')

    with tempfile.TemporaryDirectory() as tmp:
        clock = [time.time()]
        store = AccountStore(pathlib.Path(tmp) / 'accounts.sqlite', clock=lambda: clock[0])
        store.put_global_limits(100, 100)
        digest = hashlib.sha256(TOKEN.encode()).hexdigest()
        store.put_account('expiring-user', 2)
        store.add_session('expiring-user', digest, clock[0] + 10)
        closed = asyncio.Event()
        async def expiring_provider(ws):
            try:
                await ws.recv(); await ws.send(g.field(2,150))
                async for _ in ws: pass
            finally: closed.set()
        async with serve(expiring_provider, '127.0.0.1', 0, compression=None) as upstream:
            gateway = g.SpeechGateway('synthetic-provider-key', account_store=store, upstream=f"ws://127.0.0.1:{upstream.sockets[0].getsockname()[1]}", testing=True, session_check_interval=0.1)
            async with serve(gateway.handle, '127.0.0.1', 0, compression=None) as server:
                address = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/v1/speech/stream"
                async with connect(address, additional_headers={'Authorization':'Bearer '+TOKEN}, proxy=None) as ws:
                    await ws.send(json.dumps({'type':'start','source':'en','target':'zh'}))
                    assert json.loads(await ws.recv())['type'] == 'ready'
                    clock[0] += 11
                    await asyncio.wait_for(closed.wait(), 3)
                    assert json.loads(await asyncio.wait_for(ws.recv(), 3))['type'] == 'error'
        print('PASS expired session closes active stream')

    with tempfile.TemporaryDirectory() as tmp:
        store = AccountStore(pathlib.Path(tmp) / 'accounts.sqlite')
        store.put_global_limits(100, 100)
        digest = hashlib.sha256(TOKEN.encode()).hexdigest()
        store.put_account('limited-user', 2)
        store.put_speech_limit('limited-user', 1)
        store.add_session('limited-user', digest, time.time() + 60)
        received = []
        closed = asyncio.Event()
        async def limited_provider(ws):
            try:
                await ws.recv(); await ws.send(g.field(2,150))
                async for message in ws: received.append(g.parse(message))
            finally: closed.set()
        async with serve(limited_provider, '127.0.0.1', 0, compression=None) as upstream:
            gateway = g.SpeechGateway('synthetic-provider-key', account_store=store, upstream=f"ws://127.0.0.1:{upstream.sockets[0].getsockname()[1]}", testing=True, session_check_interval=0.1)
            async with serve(gateway.handle, '127.0.0.1', 0, compression=None) as server:
                address = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/v1/speech/stream"
                async with connect(address, additional_headers={'Authorization':'Bearer '+TOKEN}, proxy=None) as ws:
                    await ws.send(json.dumps({'type':'start','source':'en','target':'zh'}))
                    assert json.loads(await ws.recv())['type'] == 'ready'
                    for _ in range(5): await ws.send(b'\x01\x02' * 3200)
                    await ws.send(b'\x01\x02')
                    await asyncio.wait_for(closed.wait(), 3)
                    assert json.loads(await asyncio.wait_for(ws.recv(), 3))['type'] == 'error'
                    assert len(received) == 5, len(received)
        assert not store.consume_speech(store.authenticate(digest), 1)
        print('PASS per-account audio quota blocks excess before upstream')

    with tempfile.TemporaryDirectory() as tmp:
        db_path = pathlib.Path(tmp) / 'accounts.sqlite'
        store = AccountStore(db_path)
        store.put_global_limits(100, 100)
        digest = hashlib.sha256(TOKEN.encode()).hexdigest()
        store.put_account('concurrent-user', 3)
        store.put_speech_limit('concurrent-user', 1)
        store.add_session('concurrent-user', digest, time.time() + 60)
        session = store.authenticate(digest)
        # Different store instances model multiple workers sharing SQLite.
        def reserve(): return AccountStore(db_path).consume_speech(session, 1)
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(lambda _: reserve(), range(2)))
        assert sorted(results) == [False, True], results
        print('PASS concurrent workers cannot exceed shared audio quota')

if __name__ == '__main__': asyncio.run(test(sys.argv[1]))
