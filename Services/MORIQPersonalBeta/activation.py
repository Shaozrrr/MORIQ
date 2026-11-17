"""Transactional invitation activation for the isolated candidate only."""
import secrets
from device_invites import digest
from device_sessions import DeviceSessions

class Activation:
 def __init__(self,store):
  self.store=store;self.devices=DeviceSessions(store)
  with store._connection() as db:
   db.execute('''CREATE TABLE IF NOT EXISTS device_scopes_v1 (device_hash TEXT NOT NULL REFERENCES device_sessions_v2(device_hash), scope TEXT NOT NULL CHECK(scope IN ('speech','assistant')), PRIMARY KEY(device_hash,scope))''')
   db.execute('''CREATE TABLE IF NOT EXISTS activation_invites_v2 (
    invite_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id),
    expires_at REAL NOT NULL, device_hash TEXT, cancelled INTEGER NOT NULL DEFAULT 0
   )''')
   db.execute('''CREATE TABLE IF NOT EXISTS activation_invite_scopes_v1 (
    invite_hash TEXT NOT NULL REFERENCES activation_invites_v2(invite_hash),
    scope TEXT NOT NULL CHECK(scope IN ('speech','assistant')), PRIMARY KEY(invite_hash,scope)
   )''')
 def issue(self,account,ttl=172800,scopes=('speech',)):
  if type(ttl) is not int or not 60<=ttl<=604800:raise ValueError('invalid invite duration')
  if not isinstance(scopes,(tuple,list)) or not scopes or len(scopes)!=len(set(scopes)) or any(x not in ('speech','assistant') for x in scopes):raise ValueError('invalid scopes')
  if 'speech' not in scopes:raise ValueError('speech scope required for legacy-compatible sessions')
  invite=secrets.token_urlsafe(32)
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    if not db.execute('SELECT 1 FROM accounts a JOIN speech_limits s ON a.account_id=s.account_id WHERE a.account_id=?',(account,)).fetchone():raise ValueError('account not provisioned')
    db.execute('INSERT INTO activation_invites_v2(invite_hash,account_id,expires_at) VALUES(?,?,?)',(digest(invite),account,self.store.clock()+ttl))
    for scope in scopes:db.execute('INSERT INTO activation_invite_scopes_v1 VALUES(?,?)',(digest(invite),scope))
    db.execute('COMMIT')
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise
  return invite
 def activate(self,invite,device,access,device_ttl=7776000,session_ttl=604800):
  ih,dh,ah=digest(invite),digest(device),digest(access)
  if not ih or not dh or not ah or len({ih,dh,ah})!=3:return False
  if type(device_ttl) is not int or not 60<=device_ttl<=7776000 or type(session_ttl) is not int or not 60<=session_ttl<=604800:raise ValueError('invalid duration')
  now=self.store.clock()
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    if db.execute('SELECT mode FROM device_issuance_control_v1 WHERE singleton=1').fetchone()!=('active',):db.execute('ROLLBACK');return False
    row=db.execute('SELECT account_id,device_hash FROM activation_invites_v2 WHERE invite_hash=? AND cancelled=0 AND expires_at>?',(ih,now)).fetchone()
    if row is None:db.execute('ROLLBACK');return False
    account,bound=row
    if bound is not None:
     valid=db.execute('''SELECT 1 FROM device_sessions_v2 d JOIN sessions s ON s.token_hash=d.session_hash
      WHERE d.device_hash=? AND d.account_id=? AND d.revoked=0 AND d.expires_at>? AND d.session_hash=?
      AND s.account_id=? AND s.revoked=0 AND s.expires_at>?''',(dh,account,now,ah,account,now)).fetchone()
     db.execute('ROLLBACK');return bound==dh and valid is not None
    if (db.execute('SELECT 1 FROM device_sessions_v2 WHERE device_hash IN (?,?)',(dh,ah)).fetchone() or db.execute('SELECT 1 FROM sessions WHERE token_hash IN (?,?)',(dh,ah)).fetchone()):db.execute('ROLLBACK');return False
    scopes=db.execute('SELECT scope FROM activation_invite_scopes_v1 WHERE invite_hash=?',(ih,)).fetchall()
    if ('speech',) not in scopes:db.execute('ROLLBACK');return False
    db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)',(ah,account,now+min(session_ttl,device_ttl)))
    db.execute('INSERT INTO device_sessions_v2(device_hash,account_id,expires_at,session_hash) VALUES(?,?,?,?)',(dh,account,now+device_ttl,ah))
    for scope, in scopes:db.execute('INSERT INTO device_scopes_v1(device_hash,scope) VALUES(?,?)',(dh,scope))
    db.execute('UPDATE activation_invites_v2 SET device_hash=? WHERE invite_hash=?',(dh,ih))
    db.execute('COMMIT');return True
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise
