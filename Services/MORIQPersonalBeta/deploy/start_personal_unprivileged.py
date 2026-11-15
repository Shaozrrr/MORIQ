"""Fixed, fail-closed entrypoint for the personal service; no network as root."""
import os
from pathlib import Path
import stat
import sys

UID = GID = 65534
MOUNT = Path('/data')
DIRECTORY = MOUNT / 'moriq'
DATABASE = DIRECTORY / 'accounts.db'
SCRIPTS = {'bootstrap': '/app/deploy/bootstrap_personal_volume.py',
           'serve': '/app/deploy/start_railway_staging.py'}


def private(path, *, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if not kind or info.st_uid != UID or info.st_gid != GID or info.st_mode & 0o077:
        raise ValueError('invalid private path')


def prepare(mode):
    if os.geteuid() != 0 or MOUNT.resolve() != MOUNT or not os.path.ismount(MOUNT):
        raise ValueError('expected root and mounted volume')
    if os.environ.get('RAILWAY_VOLUME_MOUNT_PATH') != str(MOUNT):
        raise ValueError('unexpected mount')
    if mode == 'bootstrap':
        if os.environ.get('MORIQ_PERSONAL_BOOTSTRAP_ACK') != 'one-time-hashes-only-no-provider':
            raise ValueError('bootstrap not enabled')
        if any(value and ('PROVIDER_KEY' in key or key in ('SONIOX_API_KEY', 'DEEPSEEK_API_KEY', 'DEEPL_API_KEY')) for key, value in os.environ.items()):
            raise ValueError('provider credentials forbidden')
        try:
            DIRECTORY.mkdir(mode=0o700)
        except FileExistsError:
            private(DIRECTORY, directory=True)
        else:
            os.chown(DIRECTORY, UID, GID, follow_symlinks=False)
        if DATABASE.exists() or DATABASE.is_symlink():
            raise ValueError('database already exists')
    elif mode == 'serve':
        if os.environ.get('MORIQ_PERSONAL_BOOTSTRAP_ACK') or os.environ.get('MORIQ_PERSONAL_BOOTSTRAP_SEED'):
            raise ValueError('bootstrap configuration must be removed')
        if os.environ.get('MORIQ_ACCOUNT_DB') != str(DATABASE):
            raise ValueError('unexpected database')
        private(DIRECTORY, directory=True)
        private(DATABASE)
        for suffix in ('-wal', '-shm', '.railway.lock'):
            path = Path(str(DATABASE) + suffix)
            if path.exists() or path.is_symlink():
                private(path)
    else:
        raise ValueError('invalid mode')


def run():
    mode = os.environ.get('MORIQ_PERSONAL_MODE', '')
    if len(sys.argv) == 2 and sys.argv[1] == '--dropped':
        if mode not in SCRIPTS or os.getuid() != UID or os.geteuid() != UID or os.getgid() != GID or os.getegid() != GID or os.getgroups():
            raise ValueError('invalid runtime identity')
        status = Path('/proc/self/status').read_text()
        fields = dict(line.split(':', 1) for line in status.splitlines() if ':' in line)
        if int(fields['CapEff'].strip(), 16) or int(fields['CapPrm'].strip(), 16) or fields['NoNewPrivs'].strip() != '1':
            raise ValueError('capabilities or privilege escalation permitted')
        os.execv(sys.executable, [sys.executable, SCRIPTS[mode]])
    if len(sys.argv) != 1:
        raise ValueError('unexpected arguments')
    os.umask(0o077)
    prepare(mode)
    os.execv('/usr/bin/setpriv', ['/usr/bin/setpriv', '--reuid=65534', '--regid=65534',
             '--clear-groups', '--inh-caps=-all', '--bounding-set=-all', '--no-new-privs',
             sys.executable, __file__, '--dropped'])


if __name__ == '__main__':
    try:
        run()
    except Exception:
        print('Personal service startup refused; inspect private volume and configuration.', file=sys.stderr)
        sys.exit(1)
