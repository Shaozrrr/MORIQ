"""Isolated candidate: private one-time device invitations. Not wired to HTTP."""
import hashlib
import secrets


def digest(value):
    if not isinstance(value, str) or not 32 <= len(value) <= 256 or not value.isascii() or not all(33 <= ord(c) <= 126 for c in value):
        return None
    return hashlib.sha256(value.encode('ascii')).hexdigest()


class DeviceInvites:
    def __init__(self, store):
        self.store = store
        with store._connection() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS device_invites_v1 (
                invite_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id),
                expires_at REAL NOT NULL, device_hash TEXT, cancelled INTEGER NOT NULL DEFAULT 0
            )''')

    def issue(self, account, ttl=172800):
        if type(ttl) is not int or not 60 <= ttl <= 604800:
            raise ValueError('invalid invite duration')
        invite = secrets.token_urlsafe(32)
        with self.store._connection() as db:
            if not db.execute('SELECT 1 FROM accounts a JOIN speech_limits s ON s.account_id=a.account_id WHERE a.account_id=?', (account,)).fetchone():
                raise ValueError('account is not provisioned')
            db.execute('INSERT INTO device_invites_v1(invite_hash,account_id,expires_at) VALUES(?,?,?)', (digest(invite), account, self.store.clock()+ttl))
        return invite

    def activate(self, invite, device, session_ttl=604800):
        ih, dh = digest(invite), digest(device)
        if ih is None or dh is None:
            return False
        if type(session_ttl) is not int or not 60 <= session_ttl <= 604800:
            raise ValueError('invalid session duration')
        now = self.store.clock()
        with self.store._connection() as db:
            try:
                db.execute('BEGIN IMMEDIATE')
                row = db.execute('SELECT account_id,device_hash FROM device_invites_v1 WHERE invite_hash=? AND cancelled=0 AND expires_at>?', (ih, now)).fetchone()
                if row is None:
                    db.execute('ROLLBACK'); return False
                account, bound = row
                if bound is not None:
                    session = db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND account_id=? AND revoked=0 AND expires_at>?', (dh, account, now)).fetchone()
                    db.execute('ROLLBACK')
                    return bound == dh and session is not None
                if db.execute('SELECT 1 FROM sessions WHERE token_hash=?', (dh,)).fetchone():
                    db.execute('ROLLBACK'); return False
                db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)', (dh,account,now+session_ttl))
                db.execute('UPDATE device_invites_v1 SET device_hash=? WHERE invite_hash=?', (dh,ih))
                db.execute('COMMIT'); return True
            except BaseException:
                if db.in_transaction: db.execute('ROLLBACK')
                raise

    def cancel_unredeemed(self, invite):
        ih = digest(invite)
        if ih is None: return False
        with self.store._connection() as db:
            cur = db.execute('UPDATE device_invites_v1 SET cancelled=1 WHERE invite_hash=? AND cancelled=0 AND device_hash IS NULL', (ih,))
            return cur.rowcount == 1

    def revoke_device(self, invite):
        ih = digest(invite)
        if ih is None: return False
        with self.store._connection() as db:
            try:
                db.execute('BEGIN IMMEDIATE')
                row = db.execute('SELECT device_hash FROM device_invites_v1 WHERE invite_hash=? AND device_hash IS NOT NULL', (ih,)).fetchone()
                if row is None:
                    db.execute('ROLLBACK'); return False
                updated = db.execute('UPDATE sessions SET revoked=1 WHERE token_hash=? AND revoked=0', (row[0],)).rowcount
                db.execute('UPDATE device_invites_v1 SET cancelled=1 WHERE invite_hash=?', (ih,))
                db.execute('COMMIT'); return updated == 1
            except BaseException:
                if db.in_transaction: db.execute('ROLLBACK')
                raise
