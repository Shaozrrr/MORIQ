"""Synthetic test only: create private volume directory as root, drop to nobody.

Never changes an existing directory, database or lock. Accepts only fixed fake
commands, and never starts a provider-backed service.
"""
import os
from pathlib import Path
import stat
import sys

UID=65534
GID=65534
COMMANDS={'bootstrap':'/app/deploy/bootstrap_personal_volume.py',
          'fake':'/app/deploy/start_railway_persistent_fake.py',
          'diagnose':'/app/deploy/diagnose_fake_volume.py'}

def prepare(mount):
    p=Path(mount)
    if not p.is_absolute() or p.resolve()!=p or not os.path.ismount(p):raise ValueError('mount required')
    if os.geteuid()!=0:raise ValueError('root startup required')
    directory=p/'moriq'
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        info=directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=UID or info.st_gid!=GID or info.st_mode&0o077:
            raise ValueError('existing directory must already be private and owned by service user')
    else:
        os.chown(directory,UID,GID,follow_symlinks=False)
    return directory

def main():
    try:
        if len(sys.argv)!=2 or sys.argv[1] not in COMMANDS:raise ValueError('invalid fixed test mode')
        if os.environ.get('MORIQ_FAKE_DROP_ROOT_ACK')!='synthetic-test-volume-only':raise ValueError('test ack required')
        if any(v and ('PROVIDER_KEY' in k or k in ('SONIOX_API_KEY','DEEPSEEK_API_KEY','DEEPL_API_KEY')) for k,v in os.environ.items()):raise ValueError('provider credentials forbidden')
        os.umask(0o077)
        prepare(os.environ['RAILWAY_VOLUME_MOUNT_PATH'])
        os.setgroups([]);os.setgid(GID);os.setuid(UID)
        if os.geteuid()!=UID or os.getegid()!=GID or os.getgroups():raise ValueError('privilege drop failed')
        print('Synthetic test directory ready; running as unprivileged service user.',flush=True)
        os.execv(sys.executable,[sys.executable,COMMANDS[sys.argv[1]]])
    except Exception:
        print('Synthetic test privilege setup refused; inspect volume configuration.',file=sys.stderr)
        return 1

if __name__=='__main__':sys.exit(main())
