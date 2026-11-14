"""Synthetic-only personal/friends deployment smoke; never real audio or keys.

This temporary in-memory database deliberately resets on process restart. It
does not implement production cost controls and cannot connect to providers.
"""
import asyncio
from http import HTTPStatus
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT))
from account_store import AccountStore
from caption_memory_ledger import MemorySourceLedger
from railway_config import parse_network
from soniox_gateway import SonioxGateway
from websockets.asyncio.server import serve

HASH=re.compile(r'^[0-9a-f]{64}$')

def fake_routes(connection,request):
    if request.path=='/healthz' and request.headers.get('Upgrade','').lower()!='websocket':
        response=connection.respond(HTTPStatus.OK,'ok\n')
        response.headers['Cache-Control']='no-store'
        return response
    if request.path!='/v1/speech/stream':return connection.respond(HTTPStatus.NOT_FOUND,'not found\n')
    return None

def validate(env, *, now=None):
    if env.get('MORIQ_FAKE_BETA_ACK')!='synthetic-no-provider-data':
        raise ValueError('explicit synthetic acknowledgement required')
    if any(env.get(k) for k in ('MORIQ_SPEECH_PROVIDER_KEY','MORIQ_DEEPSEEK_PROVIDER_KEY','MORIQ_DEEPL_PROVIDER_KEY')):
        raise ValueError('provider credentials prohibited')
    raw=env.get('MORIQ_FAKE_SESSION_HASHES','')
    hashes=raw.split(',') if isinstance(raw,str) else []
    if not 1<=len(hashes)<=10 or len(set(hashes))!=len(hashes) or any(not HASH.fullmatch(h) for h in hashes):
        raise ValueError('one to ten separate session hashes required')
    expiry=env.get('MORIQ_FAKE_SESSION_EXPIRY_UNIX','')
    if not isinstance(expiry,str) or not expiry.isascii() or not expiry.isdecimal():
        raise ValueError('explicit expiry required')
    expiry=int(expiry);now=time.time() if now is None else now
    if not now+60<=expiry<=now+7*86400:raise ValueError('invalid session expiry')
    host,port=parse_network(env)
    return hashes,expiry,host,port

async def run(env):
    hashes,expiry,host,port=validate(env)
    with tempfile.TemporaryDirectory(prefix='moriq-fake-beta-') as folder:
        accounts=AccountStore(Path(folder)/'db',requests_per_minute=6)
        accounts.put_global_limits(40,120)
        for i,digest in enumerate(hashes):
            account='friend-'+str(i)
            accounts.put_account(account,10);accounts.put_speech_limit(account,30)
            accounts.add_session(account,digest,expiry)
        ledger=MemorySourceLedger(accounts,fake_only=True)
        async def synthetic(ws):
            await ws.recv() # provider configuration; never logged
            while True:
                pcm=await ws.recv()
                if not isinstance(pcm,bytes) or not pcm or any(pcm):
                    await ws.close(1008,'synthetic input required');return
                await ws.send(json.dumps({'tokens':[{'text':'Hello.','is_final':True,'translation_status':'original'},
                                                    {'text':'<end>','is_final':True}]}))
                await ws.wait_closed();return
        async def fake_translation(source,target): return '你好。'
        try:
            async with serve(synthetic,'127.0.0.1',0) as upstream:
                address='ws://127.0.0.1:'+str(upstream.sockets[0].getsockname()[1])+'/transcribe-websocket'
                gateway=SonioxGateway('fake',account_store=accounts,upstream=address,testing=True,
                                      source_ledger=ledger,enable_trusted_source=True,auto_provider=fake_translation)
                async with serve(gateway.handle,host,port,max_size=8192,compression=None,process_request=fake_routes):
                    await asyncio.Future()
        finally:ledger.shutdown()

if __name__=='__main__':
    try:asyncio.run(run(os.environ))
    except Exception:
        print('Synthetic beta failed to start; review configuration.',file=sys.stderr)
        sys.exit(1)
