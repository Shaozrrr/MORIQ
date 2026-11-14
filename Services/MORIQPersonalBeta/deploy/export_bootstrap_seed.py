"""Export a private offline account DB as hashes-only one-time volume seed."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import time


def export(database, output):
    database, output = Path(database), Path(output)
    for path in (database, output):
        if not path.is_absolute() or path.parent.resolve()!=path.parent: raise ValueError('absolute private path required')
        parent=path.parent.stat()
        if parent.st_uid != os.getuid() or parent.st_mode & 0o077: raise ValueError('private parent required')
    info=database.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077: raise ValueError('private DB required')
    with sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True) as db:
        limits=db.execute('select daily_requests,daily_speech_seconds from global_limits where singleton=1').fetchone()
        rows=db.execute('select a.account_id,s.token_hash,a.daily_limit,l.daily_seconds,s.expires_at from sessions s join accounts a on a.account_id=s.account_id join speech_limits l on l.account_id=a.account_id where s.revoked=0').fetchall()
    if not limits or not rows or len(rows)>20: raise ValueError('missing limits or sessions')
    now=time.time()
    accounts=[dict(account=a,token_hash=h,daily_requests=r,daily_speech_seconds=s,ttl_seconds=int(expiry-now)) for a,h,r,s,expiry in rows]
    if any(not 60<=a['ttl_seconds']<=604800 for a in accounts): raise ValueError('expired or invalid session')
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
    try:
        with os.fdopen(fd,'w') as f:
            json.dump(dict(daily_requests=limits[0],daily_speech_seconds=limits[1],accounts=accounts),f,separators=(',',':'))
            f.write('\n');f.flush();os.fsync(f.fileno())
    except BaseException:
        try:output.unlink()
        except FileNotFoundError:pass
        raise

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--database',required=True);p.add_argument('--output',required=True);args=p.parse_args()
    try:export(args.database,args.output)
    except Exception:
        print('Seed export failed; check private paths and session expiry.',file=sys.stderr);sys.exit(1)
    print('Hashes-only seed saved to a private file; no credentials printed.')
