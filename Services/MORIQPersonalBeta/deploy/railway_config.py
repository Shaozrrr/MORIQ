"""Pure Railway configuration validation; this module does not start a server.

This is a staging building block, not a production readiness check. Callers
must separately implement user authentication, secure secret delivery,
persistent account provisioning and abuse protection before exposing a port.
"""
from pathlib import PurePosixPath

def parse_network(env):
    raw = env.get('PORT', '')
    if not isinstance(raw, str) or not raw.isascii() or not raw.isdecimal() or not 1 <= int(raw) <= 65535:
        raise ValueError('Railway PORT must be a valid TCP port')
    return '0.0.0.0', int(raw)

def database_under_volume(env):
    """Check lexical paths only; actual mounted volume must be verified separately."""
    mount = env.get('RAILWAY_VOLUME_MOUNT_PATH', '')
    db = env.get('MORIQ_ACCOUNT_DB', '')
    if not isinstance(mount, str) or not isinstance(db, str): raise ValueError('invalid storage configuration')
    base, path = PurePosixPath(mount), PurePosixPath(db)
    if not base.is_absolute() or base == PurePosixPath('/') or not path.is_absolute() or '..' in path.parts or '..' in base.parts:
        raise ValueError('absolute volume and database paths required')
    if path == base or not path.is_relative_to(base): raise ValueError('database must be inside volume')
    return str(path)
