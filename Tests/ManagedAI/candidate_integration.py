"""Local synthetic Swift client -> candidate gateway -> fake provider."""
import asyncio, hashlib, json, os, pathlib, socket, sqlite3, sys, tempfile, time
from aiohttp import web
from websockets.asyncio.server import serve
from websockets.asyncio.client import connect

root = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'Services/ManagedGatewayCandidate'))
from account_store import AccountStore
from assistant_server import Gateway
from assistant_async import make_app
from usage_metrics import UsageRecorder
sys.path.insert(0,str(root / 'Services/ManagedGatewayCandidate/deploy'))
from unified_candidate import caddyfile

async def main():
    seen = []
    async def fake(request):
        seen.append(await request.json())
        return web.Response(body=b'data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}\n\ndata: [DONE]\n\n',content_type='text/event-stream')
    up=web.AppRunner(web.Application(),access_log=None);up.app.router.add_post('/v1/chat/completions',fake);await up.setup();site=web.TCPSite(up,'127.0.0.1',0);await site.start()
    upstream=f'http://127.0.0.1:{site._server.sockets[0].getsockname()[1]}/v1/chat/completions'
    try:
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory).resolve();store=AccountStore(path/'accounts.db');store.put_global_limits(10,10);store.put_account('synthetic',10);store.put_token_limits('synthetic',1000,1000)
            token='x'*40;store.add_session('synthetic',hashlib.sha256(token.encode()).hexdigest(),time.time()+60)
            recorder=UsageRecorder(path/'usage.db',allowed_models={'fake'},allowed_providers={'fake'},rates={})
            gateway=Gateway(upstream,'fake','fake-key',account_store=store,test_mode=True,supports_images=True)
            app=make_app(gateway,upstream,testing=True,recorder=recorder,metric_provider='fake',require_operation_id=True,reserved_tokens=100)
            @web.middleware
            async def diagnostics(request,handler):
                response=await handler(request)
                if response.status>=400:print('candidate_status',response.status,'content_length_present',request.content_length is not None,'operation_id_present',bool(request.headers.get('MORIQ-Operation-ID')),flush=True)
                return response
            app.middlewares.append(diagnostics)
            runner=web.AppRunner(app,access_log=None);await runner.setup();site=web.TCPSite(runner,'127.0.0.1',0);await site.start()
            try:
                async def speech(ws):
                    await ws.send(await ws.recv())
                async with serve(speech,'127.0.0.1',0) as speech_server:
                    with socket.socket() as sock:
                        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
                    config=path/'Caddyfile';config.write_text(caddyfile(port,speech_server.sockets[0].getsockname()[1],site._server.sockets[0].getsockname()[1]).replace(':'+str(port)+' {','http://127.0.0.1:'+str(port)+' {'))
                    proxy=await asyncio.create_subprocess_exec(os.environ['MORIQ_TEST_CADDY'],'run','--config',str(config),stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL,env={'PATH':'/usr/bin:/bin','HOME':directory})
                    try:
                        for _ in range(50):
                            if proxy.returncode is not None:raise RuntimeError('caddy stopped')
                            try:
                                reader,writer=await asyncio.open_connection('127.0.0.1',port);writer.close();await writer.wait_closed();break
                            except OSError:await asyncio.sleep(.1)
                        else:raise RuntimeError('caddy not ready')
                        env={**os.environ,'TEST_GATEWAY_PORT':str(port),'TEST_ACCOUNT_TOKEN':token}
                        proc=await asyncio.create_subprocess_exec(sys.argv[1],env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
                        out,err=await asyncio.wait_for(proc.communicate(),20)
                        if proc.returncode:raise RuntimeError('client failed: '+err.decode(errors='replace')[-1000:])
                        if os.environ.get('MORIQ_SINGLE_PROBE')=='1':
                            assert b'PASS Swift single probe' in out and len(seen)==1
                            with sqlite3.connect(path/'accounts.db') as db:assert db.execute('select count(*),sum(settled_tokens) from token_reservations').fetchone()==(1,11)
                            print('PASS single Swift request through Caddy to candidate, settled once');return
                        assert b'PASS Swift client' in out
                        assert len(seen)==2 and [m['role'] for m in seen[1]['messages']]==['user','assistant','user']
                        assert len(seen[1]['messages'][0]['content'])==2 and len(seen[1]['messages'][2]['content'])==2
                        with sqlite3.connect(path/'accounts.db') as db:assert db.execute('select count(*),sum(settled_tokens) from token_reservations').fetchone()==(2,22)
                        async with connect(f'ws://127.0.0.1:{port}/v1/speech/stream',proxy=None) as ws:
                            await ws.send('synthetic');assert await ws.recv()=='synthetic'
                        print(out.decode().strip()+' through Caddy; WebSocket routing passed')
                    finally:
                        proxy.terminate();await proxy.wait()
            finally:await runner.cleanup()
    finally:await up.cleanup()

if __name__=='__main__':asyncio.run(main())
