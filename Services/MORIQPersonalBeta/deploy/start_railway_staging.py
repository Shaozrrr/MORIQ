"""Explicit single-instance Railway staging only, not an identity service."""
import asyncio, fcntl, os, stat, sys
from http import HTTPStatus
from contextlib import contextmanager
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT))
from railway_config import parse_network,database_under_volume
from start_staging import private_file

def public_routes(connection, request):
    """Railway liveness only; never reports provider or account readiness."""
    if request.path == '/healthz' and request.headers.get('Upgrade', '').lower() != 'websocket':
        response = connection.respond(HTTPStatus.OK, 'ok\n')
        response.headers['Cache-Control'] = 'no-store'
        return response
    if request.path != '/v1/speech/stream':
        return connection.respond(HTTPStatus.NOT_FOUND, 'not found\n')
    return None

def validated_path(env, *, mount_check=os.path.ismount):
    if env.get('MORIQ_RAILWAY_STAGING_ACK')!='authenticated-single-instance-not-public-release': raise ValueError('staging not enabled')
    if env.get('MORIQ_PROVIDER_SECRET_SEALED_ACK')!='1': raise ValueError('sealed secret acknowledgement required')
    if env.get('MORIQ_SPEECH_TOKEN_HASHES') or env.get('MORIQ_SONIOX_TRUSTED_SOURCE_EXPERIMENTAL'): raise ValueError('unsupported configuration')
    host,port=parse_network(env); db=Path(database_under_volume(env)); mount=Path(env['RAILWAY_VOLUME_MOUNT_PATH'])
    if mount.is_symlink() or mount.resolve()!=mount or not mount_check(str(mount)): raise ValueError('persistent mount required')
    if db.parent.resolve()!=db.parent or db.is_symlink(): raise ValueError('symlink paths prohibited')
    private_file(str(db))
    return host,port,db

def configure(env, *, mount_check=os.path.ismount):
    host,port,db=validated_path(env,mount_check=mount_check)
    key=env.get('MORIQ_SPEECH_PROVIDER_KEY','')
    raw_rate=env.get('MORIQ_ACCOUNT_REQUESTS_PER_MINUTE','')
    if not isinstance(raw_rate,str) or not raw_rate.isascii() or not raw_rate.isdecimal() or not 1<=int(raw_rate)<=60:
        raise ValueError('account request rate required')
    from account_store import AccountStore
    accounts=AccountStore(db,requests_per_minute=int(raw_rate))
    guest=env.get('MORIQ_GUEST_BETA_ENABLED','0')
    if guest != '0':
        raise ValueError('guest sign-up disabled for personal beta')
    with accounts._connection() as conn:
        limits=conn.execute('SELECT daily_requests,daily_speech_seconds FROM global_limits WHERE singleton=1').fetchone()
        valid=conn.execute('SELECT 1 FROM sessions s JOIN speech_limits l ON l.account_id=s.account_id JOIN accounts a ON a.account_id=s.account_id WHERE s.revoked=0 AND s.expires_at>? AND l.daily_seconds>0 AND a.daily_limit>0 LIMIT 1',(accounts.clock(),)).fetchone()
    if not limits or any(type(n) is not int or n<=0 for n in limits) or not valid:
        raise ValueError('provisioned accounts and limits required')
    enabled=env.get('MORIQ_CAPTION_AUTO_TRANSLATION_BETA','0')
    if enabled not in ('0','1') or (enabled=='1' and env.get('MORIQ_CAPTION_AUTO_TRANSLATION_ACK')!='deepseek-server-side-bounded'):
        raise ValueError('invalid translation beta configuration')
    from soniox_gateway import SonioxGateway
    ledger=None
    try:
        provider=None
        if enabled=='1':
            from caption_memory_ledger import MemorySourceLedger
            from deepseek_translation import ControlledDeepSeekProvider
            provider=ControlledDeepSeekProvider(env.get('MORIQ_DEEPSEEK_PROVIDER_KEY',''))
            ledger=MemorySourceLedger(accounts,fake_only=True)
        return SonioxGateway(key,account_store=accounts,source_ledger=ledger,enable_trusted_source=enabled=='1',auto_provider=provider),host,port,db
    except BaseException:
        if ledger:ledger.shutdown()
        raise

@contextmanager
def locked_configure(env, *, mount_check=os.path.ismount):
    _,_,db=validated_path(env,mount_check=mount_check)
    fd=os.open(str(db)+'.railway.lock',os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0),0o600)
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077: raise ValueError('invalid lock')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        config=configure(env,mount_check=mount_check)
        try:yield config
        finally:
            if config[0].source_ledger is not None:config[0].source_ledger.shutdown()
    finally: os.close(fd)

def build_router(gateway, *, guest_enabled=False):
    if guest_enabled:raise ValueError('guest sign-up disabled for personal beta')
    async def router(client):
        await gateway.handle(client)
    return router

def main():
    with locked_configure(os.environ) as (gateway,host,port,db):
        from websockets.asyncio.server import serve
        router=build_router(gateway)
        async def run():
            async with serve(router,host,port,max_size=8192,compression=None,process_request=public_routes): await asyncio.Future()
        asyncio.run(run())

if __name__=='__main__':
    try: main()
    except Exception:
        print('MORIQ Railway staging startup failed; review configuration.',file=sys.stderr)
        sys.exit(1)
