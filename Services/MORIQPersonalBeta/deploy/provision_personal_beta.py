"""Offline provisioning for a personal/friends-only service. No provider keys.

The service must be stopped: this uses its non-blocking single-instance lock.
Global budget initialization is one-time and cannot overwrite existing limits.
Session credentials are created in a new private file, never printed or passed
on the command line. Deliver each file privately to its intended recipient.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import re
import secrets
import stat
import sys

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT))
from account_store import AccountStore

ACCOUNT=re.compile(r'^[A-Za-z0-9_.-]{1,128}$')

@contextmanager
def offline_store(path):
    path=Path(path)
    if not path.is_absolute() or path.is_symlink() or path.parent.resolve()!=path.parent:
        raise ValueError('absolute private database path required')
    info=path.parent.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:
        raise ValueError('private database directory required')
    fd=os.open(str(path)+'.railway.lock',os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0),0o600)
    try:
        lock=os.fstat(fd)
        if not stat.S_ISREG(lock.st_mode) or lock.st_uid!=os.getuid() or lock.st_mode&0o077:
            raise ValueError('invalid service lock')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        yield AccountStore(path)
    finally:os.close(fd)

def initialize(store, *, daily_requests, daily_speech_seconds):
    values=(daily_requests,daily_speech_seconds)
    if any(type(x) is not int or not 1<=x<=100_000_000 for x in values):raise ValueError('invalid budget')
    with store._connection() as db:
        # INSERT, not UPSERT: reruns cannot reset or expand an existing budget.
        db.execute('INSERT INTO global_limits(singleton,daily_requests,daily_speech_seconds) VALUES(1,?,?)',values)

def issue(store, *, account, daily_requests, daily_speech_seconds, ttl_seconds, output):
    if not isinstance(account,str) or not ACCOUNT.fullmatch(account):raise ValueError('invalid account')
    if type(daily_requests) is not int or not 1<=daily_requests<=100000 or type(daily_speech_seconds) is not int or not 1<=daily_speech_seconds<=86400:
        raise ValueError('invalid account limits')
    if type(ttl_seconds) is not int or not 60<=ttl_seconds<=7*86400:raise ValueError('invalid session duration')
    output=Path(output)
    if not output.is_absolute() or output.parent.resolve()!=output.parent:raise ValueError('private output path required')
    parent=output.parent.stat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid!=os.getuid() or parent.st_mode&0o077:
        raise ValueError('private output directory required')
    # Reserve destination first so an existing credential is never overwritten.
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
    token=secrets.token_urlsafe(32);digest=hashlib.sha256(token.encode('ascii')).hexdigest()
    committed=False
    try:
        with store._connection() as db:
            try:
                db.execute('BEGIN IMMEDIATE')
                if db.execute('SELECT 1 FROM global_limits WHERE singleton=1').fetchone() is None:
                    raise ValueError('global budget required')
                db.execute('INSERT INTO accounts(account_id,daily_limit) VALUES(?,?)',(account,daily_requests))
                db.execute('INSERT INTO speech_limits(account_id,daily_seconds) VALUES(?,?)',(account,daily_speech_seconds))
                db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)',(digest,account,store.clock()+ttl_seconds))
                db.execute('COMMIT');committed=True
            except BaseException:
                if db.in_transaction:db.execute('ROLLBACK')
                raise
        with os.fdopen(fd,'w',encoding='ascii') as handle:
            fd=-1;handle.write(token+'\n');handle.flush();os.fsync(handle.fileno())
    except BaseException:
        if fd>=0:os.close(fd)
        try:
            if committed:store.revoke(digest)
        finally:
            try:os.unlink(output)
            except FileNotFoundError:pass
        raise

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='action',required=True)
    init=sub.add_parser('init');init.add_argument('--database',required=True)
    init.add_argument('--daily-requests',required=True,type=int);init.add_argument('--daily-speech-seconds',required=True,type=int)
    add=sub.add_parser('issue');add.add_argument('--database',required=True);add.add_argument('--account',required=True)
    add.add_argument('--daily-requests',required=True,type=int);add.add_argument('--daily-speech-seconds',required=True,type=int)
    add.add_argument('--ttl-seconds',required=True,type=int);add.add_argument('--output',required=True)
    args=parser.parse_args()
    try:
        with offline_store(args.database) as store:
            if args.action=='init':initialize(store,daily_requests=args.daily_requests,daily_speech_seconds=args.daily_speech_seconds)
            else:issue(store,account=args.account,daily_requests=args.daily_requests,daily_speech_seconds=args.daily_speech_seconds,ttl_seconds=args.ttl_seconds,output=args.output)
    except Exception:
        print('Personal beta provisioning failed; review private paths, limits and service lock.',file=sys.stderr)
        return 1
    print('Personal beta provisioning complete. No provider secret was used.')
    return 0

if __name__=='__main__':sys.exit(main())
