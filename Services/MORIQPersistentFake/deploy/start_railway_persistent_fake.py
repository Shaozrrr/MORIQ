"""Independent test-volume acceptance only. No real audio or provider access."""
import asyncio
import fcntl
from http import HTTPStatus
import json
import os
from pathlib import Path
import stat
import sys

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT))
from account_store import AccountStore
from railway_config import parse_network, database_under_volume
from soniox_gateway import SonioxGateway
def private_file(path):
    p=Path(path)
    if not p.is_absolute() or p.is_symlink(): raise ValueError('private file required')
    st=p.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077: raise ValueError('private file required')
    return p

def public_routes(connection, request):
    if request.path == '/healthz' and request.headers.get('Upgrade','').lower() != 'websocket':
        response=connection.respond(HTTPStatus.OK,'ok\n')
        response.headers['Cache-Control']='no-store'
        return response
    if request.path != '/v1/speech/stream': return connection.respond(HTTPStatus.NOT_FOUND,'not found\n')
    return None
from websockets.asyncio.server import serve

class SyntheticClient:
    def __init__(self, client): self.client=client; self.request=client.request; self.first=True
    def __getattr__(self, name): return getattr(self.client,name)
    async def recv(self):
        value=await self.client.recv()
        if self.first:
            self.first=False
            try: config=json.loads(value)
            except Exception: raise ValueError('invalid config')
            if not isinstance(config,dict) or config.get('protocol',1)!=1: raise ValueError('only synthetic PCM protocol 1')
        elif isinstance(value,bytes) and (not value or any(value)):
            await self.client.close(1008,'only zero synthetic PCM')
            raise ValueError('nonzero audio prohibited')
        return value

def validate(env):
    if env.get('MORIQ_PERSISTENT_FAKE_ACK')!='dedicated-test-volume-zero-pcm-only': raise ValueError('test-only acknowledgement required')
    if any(value and ('PROVIDER_KEY' in name or name in ('SONIOX_API_KEY','DEEPSEEK_API_KEY','DEEPL_API_KEY')) for name,value in env.items()): raise ValueError('provider key prohibited')
    if env.get('MORIQ_GUEST_BETA_ENABLED','0')!='0': raise ValueError('guest disabled')
    host,port=parse_network(env); mount=Path(env.get('RAILWAY_VOLUME_MOUNT_PATH','')); db=Path(database_under_volume(env))
    if mount.resolve()!=mount or not os.path.ismount(mount) or db.parent.resolve()!=db.parent or db.is_symlink(): raise ValueError('mount required')
    private_file(str(db))
    return host,port,db

async def run(env):
    host,port,db=validate(env)
    fd=os.open(str(db)+'.railway.lock',os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0),0o600)
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077: raise ValueError('private lock required')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        accounts=AccountStore(db,requests_per_minute=30)
        with accounts._connection() as conn:
            if not conn.execute('select 1 from global_limits where singleton=1').fetchone(): raise ValueError('limits required')
        async def synthetic(ws):
            await ws.recv()
            while True:
                pcm=await ws.recv()
                if not isinstance(pcm,bytes) or not pcm or any(pcm): await ws.close(1008,'zero PCM required');return
                await ws.send(json.dumps({'tokens':[{'text':'Hello.','is_final':True,'translation_status':'original'},{'text':'<end>','is_final':True}]}))
                await ws.wait_closed();return
        async with serve(synthetic,'127.0.0.1',0) as upstream:
            address='ws://127.0.0.1:'+str(upstream.sockets[0].getsockname()[1])+'/transcribe-websocket'
            gateway=SonioxGateway('synthetic',account_store=accounts,upstream=address,testing=True)
            async def route(client): await gateway.handle(SyntheticClient(client))
            async with serve(route,host,port,max_size=8192,compression=None,process_request=public_routes): await asyncio.Future()
    finally: os.close(fd)

if __name__=='__main__':
    try:asyncio.run(run(os.environ))
    except Exception:
        print('Persistent synthetic test refused; inspect test configuration.',file=sys.stderr);sys.exit(1)
