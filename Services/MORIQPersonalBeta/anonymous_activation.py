"""Isolated anonymous device issuance; not connected to a public endpoint.

Caller must provide durable admission control before exposing this operation.
No provider credentials or screen/audio content are accepted or stored here.
"""
import secrets
from device_invites import digest
from device_sessions import DeviceSessions


class AnonymousActivation:
 def __init__(self, store):
  self.store = store
  self.devices = DeviceSessions(store)
  with store._connection() as db:
   db.execute('CREATE TABLE IF NOT EXISTS anonymous_accounts_v1 (account_id TEXT PRIMARY KEY REFERENCES accounts(account_id), device_hash TEXT UNIQUE NOT NULL REFERENCES device_sessions_v2(device_hash))')

 def activate(self, device, access, *, device_ttl=7776000, session_ttl=604800):
  dh, ah = digest(device), digest(access)
  if not dh or not ah or dh == ah: return False
  if type(device_ttl) is not int or not 60 <= device_ttl <= 7776000 or type(session_ttl) is not int or not 60 <= session_ttl <= 604800:
   raise ValueError('invalid duration')
  now = self.store.clock()
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    if db.execute('SELECT mode FROM device_issuance_control_v1 WHERE singleton=1').fetchone() != ('active',):
     db.execute('ROLLBACK'); return False
    prior = db.execute('SELECT d.account_id,d.session_hash,d.expires_at,d.revoked FROM device_sessions_v2 d JOIN anonymous_accounts_v1 a ON a.device_hash=d.device_hash WHERE d.device_hash=?', (dh,)).fetchone()
    if prior:
     account, session_hash, expires, revoked = prior
     active = db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND account_id=? AND revoked=0 AND expires_at>?', (ah, account, now)).fetchone()
     db.execute('ROLLBACK')
     return not revoked and expires > now and session_hash == ah and active is not None
    if db.execute('SELECT 1 FROM device_sessions_v2 WHERE device_hash IN (?,?)', (dh,ah)).fetchone() or db.execute('SELECT 1 FROM sessions WHERE token_hash IN (?,?)', (dh,ah)).fetchone():
     db.execute('ROLLBACK'); return False
    account = 'anon_' + secrets.token_hex(16)
    # Compatibility values satisfy the old schema; anonymous policy must
    # explicitly bypass personal limits before this candidate is exposed.
    db.execute('INSERT INTO accounts(account_id,daily_limit) VALUES(?,1)', (account,))
    db.execute('INSERT INTO speech_limits(account_id,daily_seconds) VALUES(?,1)', (account,))
    db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)', (ah,account,now+min(session_ttl,device_ttl)))
    db.execute('INSERT INTO device_sessions_v2(device_hash,account_id,expires_at,session_hash) VALUES(?,?,?,?)', (dh,account,now+device_ttl,ah))
    db.execute('INSERT INTO anonymous_accounts_v1(account_id,device_hash) VALUES(?,?)', (account,dh))
    db.executemany('INSERT INTO device_scopes_v1(device_hash,scope) VALUES(?,?)', [(dh,'speech'),(dh,'assistant')])
    db.execute('COMMIT'); return True
   except BaseException:
    if db.in_transaction: db.execute('ROLLBACK')
    raise
