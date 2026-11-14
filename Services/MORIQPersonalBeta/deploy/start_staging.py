"""Single-host, explicitly enabled Soniox staging launcher; not production ready."""
import asyncio
import fcntl
import os
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def private_file(path):
    p = Path(path)
    if not p.is_absolute() or p.is_symlink():
        raise ValueError('an absolute private file is required')
    st = p.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise ValueError('file must belong to service user and have mode 0600 or stricter')
    return p


def configure(env):
    if env.get('MORIQ_STAGING_ACK') != 'single-host-not-production':
        raise ValueError('explicit staging acknowledgement required')
    if env.get('MORIQ_SPEECH_PROVIDER_KEY') or env.get('MORIQ_SPEECH_TOKEN_HASHES'):
        raise ValueError('credentials and sessions must not be supplied in environment')
    db = private_file(env.get('MORIQ_ACCOUNT_DB', ''))
    key_path = private_file(env.get('MORIQ_SPEECH_KEY_FILE', ''))
    key = key_path.read_text(encoding='utf-8').strip()
    if not key or not key.isascii() or any(not 33 <= ord(c) <= 126 for c in key):
        raise ValueError('invalid credential file')
    port = env.get('MORIQ_SPEECH_PORT', '8777')
    if not port.isascii() or not port.isdigit() or not 1024 <= int(port) <= 65535:
        raise ValueError('invalid loopback port')
    from account_store import AccountStore
    store = AccountStore(db)
    with store._connection() as conn:
        limits = conn.execute('SELECT daily_requests, daily_speech_seconds FROM global_limits WHERE singleton=1').fetchone()
    if not limits or any(type(n) is not int or n <= 0 for n in limits):
        raise ValueError('global request and audio limits must be configured')
    from soniox_gateway import SonioxGateway
    return SonioxGateway(key, account_store=store), int(port), db


def main():
    gateway, port, db = configure(os.environ)
    lockpath = str(db) + '.staging.lock'
    fd = os.open(lockpath, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise ValueError('invalid lock file')
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    from websockets.asyncio.server import serve
    async def run():
        async with serve(gateway.handle, '127.0.0.1', port, max_size=8192, compression=None):
            await asyncio.Future()
    try:
        asyncio.run(run())
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never emit exception contents: paths or provider data may contain secrets.
        print('MORIQ staging startup failed; check configuration and permissions.', file=sys.stderr)
        sys.exit(1)
