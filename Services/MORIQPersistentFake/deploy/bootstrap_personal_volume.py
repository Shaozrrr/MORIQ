"""One-shot private volume seed; hashes only, no provider credentials or listener.

Requires an explicit temporary start command and mounted volume. Never removes or
recreates an existing DB, including an incomplete DB from an interrupted run.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from account_store import AccountStore


def bootstrap(mount, seed, *, require_mount=True):
    mount = Path(mount)
    if not mount.is_absolute() or mount.resolve() != mount or (require_mount and not os.path.ismount(mount)):
        raise ValueError('mounted absolute volume required')
    if set(seed) != {'daily_requests', 'daily_speech_seconds', 'accounts'}:
        raise ValueError('invalid seed')
    def integer(value, maximum):
        if type(value) is not int or not 1 <= value <= maximum: raise ValueError('invalid limit')
    integer(seed['daily_requests'], 1000000)
    integer(seed['daily_speech_seconds'], 86400)
    accounts = seed['accounts']
    if not isinstance(accounts, list) or not 1 <= len(accounts) <= 20: raise ValueError('invalid accounts')
    for a in accounts:
        if not isinstance(a, dict) or set(a) != {'account', 'token_hash', 'daily_requests', 'daily_speech_seconds', 'ttl_seconds'}: raise ValueError('invalid account')
        if not isinstance(a['account'], str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', a['account']): raise ValueError('invalid account')
        if not isinstance(a['token_hash'], str) or not re.fullmatch(r'[0-9a-f]{64}', a['token_hash']): raise ValueError('invalid digest')
        integer(a['daily_requests'], 100000)
        integer(a['daily_speech_seconds'], 86400)
        integer(a['ttl_seconds'], 604800)
        if a['ttl_seconds'] < 60: raise ValueError('invalid lifetime')
    directory = mount / 'moriq'
    try: directory.mkdir(mode=0o700)
    except FileExistsError: pass
    d = os.lstat(directory)
    if not stat.S_ISDIR(d.st_mode) or d.st_uid != os.getuid() or d.st_mode & 0o077: raise ValueError('private directory required')
    dbpath = directory / 'accounts.db'
    lockfd = os.open(str(dbpath)+'.railway.lock', os.O_RDWR|os.O_CREAT|getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        lockinfo = os.fstat(lockfd)
        if not stat.S_ISREG(lockinfo.st_mode) or lockinfo.st_uid != os.getuid() or lockinfo.st_mode & 0o077: raise ValueError('private lock required')
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fd = os.open(dbpath, os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os, 'O_NOFOLLOW', 0), 0o600)
        os.close(fd)
        store = AccountStore(dbpath)
        with store._connection() as db:
            db.execute('BEGIN IMMEDIATE')
            try:
                db.execute('INSERT INTO global_limits(singleton,daily_requests,daily_speech_seconds) VALUES(1,?,?)', (seed['daily_requests'],seed['daily_speech_seconds']))
                now = time.time()
                for a in accounts:
                    db.execute('INSERT INTO accounts(account_id,daily_limit) VALUES(?,?)',(a['account'],a['daily_requests']))
                    db.execute('INSERT INTO speech_limits(account_id,daily_seconds) VALUES(?,?)',(a['account'],a['daily_speech_seconds']))
                    db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)',(a['token_hash'],a['account'],now+a['ttl_seconds']))
                db.execute('COMMIT')
            except BaseException:
                if db.in_transaction: db.execute('ROLLBACK')
                raise
    finally:
        os.close(lockfd)


def main():
    try:
        if os.environ.get('MORIQ_PERSONAL_BOOTSTRAP_ACK') != 'one-time-hashes-only-no-provider': raise ValueError('ack required')
        if any(os.environ.get(k) for k in ('MORIQ_SPEECH_PROVIDER_KEY','MORIQ_DEEPSEEK_PROVIDER_KEY')): raise ValueError('provider credentials forbidden')
        raw = os.environ.get('MORIQ_PERSONAL_BOOTSTRAP_SEED', '')
        if len(raw) > 16000: raise ValueError('seed too large')
        bootstrap(os.environ['RAILWAY_VOLUME_MOUNT_PATH'], json.loads(raw))
    except Exception:
        print('Bootstrap refused; database was not overwritten. Inspect volume and configuration.', file=sys.stderr)
        return 1
    print('Bootstrap completed. No listener or provider connection started; switch to normal start command.', flush=True)
    # Keep deployment alive so the operator can inspect it, with no network listener.
    while True: time.sleep(3600)

if __name__ == '__main__': sys.exit(main())
