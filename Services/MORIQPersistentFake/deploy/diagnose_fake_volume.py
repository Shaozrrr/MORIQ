"""Read-only startup diagnosis for an isolated synthetic Railway test volume.

Does not print environment values, account identifiers, hashes, or credentials.
Never creates paths, opens the database, or contacts a provider.
"""
import json
import os
from pathlib import Path
import re
import stat
import sys
import time


def inspect(env):
    result={}
    result['ack_ok']=env.get('MORIQ_PERSONAL_BOOTSTRAP_ACK')=='one-time-hashes-only-no-provider'
    result['provider_variable_present']=any(bool(v) and ('PROVIDER_KEY' in k or k in ('SONIOX_API_KEY','DEEPSEEK_API_KEY','DEEPL_API_KEY')) for k,v in env.items())
    mount=Path(env.get('RAILWAY_VOLUME_MOUNT_PATH',''))
    result['mount_absolute']=mount.is_absolute()
    result['mount_canonical']=result['mount_absolute'] and mount.resolve()==mount
    result['mounted']=result['mount_canonical'] and os.path.ismount(mount)
    result['uid_is_root']=os.getuid()==0
    result['mount_exists']=mount.exists()
    result['mount_writable']=os.access(mount,os.W_OK|os.X_OK) if result['mount_exists'] else False
    directory=mount/'moriq';db=directory/'accounts.db'
    try:
        d=directory.lstat()
        result['directory_state']='private_owned' if stat.S_ISDIR(d.st_mode) and d.st_uid==os.getuid() and not d.st_mode&0o077 else 'invalid_type_owner_or_mode'
    except FileNotFoundError:result['directory_state']='absent'
    except OSError:result['directory_state']='unreadable'
    try:
        db.lstat();result['database_exists']=True
    except FileNotFoundError:result['database_exists']=False
    except OSError:result['database_exists']='unknown'
    lock=directory/'accounts.db.railway.lock'
    try:
        st=lock.lstat()
        result['lock_state']='private_owned' if stat.S_ISREG(st.st_mode) and st.st_uid==os.getuid() and not st.st_mode&0o077 else 'invalid_type_owner_or_mode'
    except FileNotFoundError:result['lock_state']='absent'
    except OSError:result['lock_state']='unreadable'
    raw=env.get('MORIQ_PERSONAL_BOOTSTRAP_SEED','')
    result['seed_state']='invalid'
    try:
        if len(raw)>16000:raise ValueError()
        seed=json.loads(raw)
        if not isinstance(seed,dict) or set(seed)!={'daily_requests','daily_speech_seconds','accounts'}:raise ValueError()
        def bounded(n,maxi):return type(n) is int and 1<=n<=maxi
        if not bounded(seed['daily_requests'],1000000) or not bounded(seed['daily_speech_seconds'],86400):raise ValueError()
        accounts=seed['accounts']
        if not isinstance(accounts,list) or not 1<=len(accounts)<=20:raise ValueError()
        names=set();digests=set()
        for a in accounts:
            if not isinstance(a,dict) or set(a)!={'account','token_hash','daily_requests','daily_speech_seconds','ttl_seconds'}:raise ValueError()
            if not isinstance(a['account'],str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}',a['account']):raise ValueError()
            if not isinstance(a['token_hash'],str) or not re.fullmatch(r'[0-9a-f]{64}',a['token_hash']):raise ValueError()
            if not bounded(a['daily_requests'],100000) or not bounded(a['daily_speech_seconds'],86400) or not bounded(a['ttl_seconds'],604800) or a['ttl_seconds']<60:raise ValueError()
            if a['account'] in names or a['token_hash'] in digests:raise ValueError()
            names.add(a['account']);digests.add(a['token_hash'])
        result['seed_state']='valid_shape'
    except (ValueError,TypeError):pass
    return result

if __name__=='__main__':
    print(json.dumps(inspect(os.environ),sort_keys=True),flush=True)
    if os.environ.get('MORIQ_FAKE_DIAGNOSTIC_HOLD')=='1':
        while True:time.sleep(3600)
