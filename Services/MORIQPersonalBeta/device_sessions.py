"""Isolated device/session candidate. Not exposed as a network service."""
from device_invites import digest
import re

class DeviceSessions:
 def __init__(self,store):
  self.store=store
  with store._connection() as db:
   db.execute('''CREATE TABLE IF NOT EXISTS device_sessions_v2 (
    device_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id),
    expires_at REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
    session_hash TEXT
   )''')
   db.execute('CREATE TABLE IF NOT EXISTS device_generations_v1 (device_hash TEXT PRIMARY KEY, generation INTEGER NOT NULL CHECK(generation>=0))')
   db.execute("CREATE TABLE IF NOT EXISTS device_scopes_v1 (device_hash TEXT NOT NULL REFERENCES device_sessions_v2(device_hash), scope TEXT NOT NULL CHECK(scope IN ('speech','assistant')), PRIMARY KEY(device_hash,scope))")
   db.execute('CREATE TABLE IF NOT EXISTS device_renewals_v1 (device_hash TEXT NOT NULL, operation_id TEXT NOT NULL, expected_generation INTEGER NOT NULL, session_hash TEXT NOT NULL, PRIMARY KEY(device_hash,operation_id))')
   db.execute("CREATE TABLE IF NOT EXISTS device_issuance_control_v1 (singleton INTEGER PRIMARY KEY CHECK(singleton=1), mode TEXT NOT NULL CHECK(mode IN ('active','rollback_ready')))")
   db.execute("INSERT OR IGNORE INTO device_issuance_control_v1 VALUES(1,'active')")

 def prepare_rollback(self):
  """Freeze issuance and revoke device sessions unsafe for the speech-only legacy service."""
  now=self.store.clock()
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    db.execute("UPDATE device_issuance_control_v1 SET mode='rollback_ready' WHERE singleton=1")
    db.execute('''UPDATE sessions SET revoked=1 WHERE token_hash IN (
      SELECT d.session_hash FROM device_sessions_v2 d WHERE d.session_hash IS NOT NULL
      AND (d.revoked!=0 OR d.expires_at<=? OR NOT EXISTS (
       SELECT 1 FROM device_scopes_v1 s WHERE s.device_hash=d.device_hash AND s.scope='speech'))
    )''',(now,))
    db.execute('COMMIT')
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise

 def resume_issuance(self):
  with self.store._connection() as db:
   db.execute("UPDATE device_issuance_control_v1 SET mode='active' WHERE singleton=1 AND mode='rollback_ready'")

 def provision(self,account,device,ttl=7776000):
  dh=digest(device)
  if dh is None or type(ttl) is not int or not 60 <= ttl <= 7776000: raise ValueError('invalid device')
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    if not db.execute('SELECT 1 FROM accounts WHERE account_id=?',(account,)).fetchone(): raise ValueError('unknown account')
    db.execute('INSERT INTO device_sessions_v2(device_hash,account_id,expires_at) VALUES(?,?,?)',(dh,account,self.store.clock()+ttl))
    db.execute("INSERT INTO device_scopes_v1 VALUES(?,'speech')",(dh,));db.execute('COMMIT')
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise

 def renew(self,device,access,ttl=604800):
  dh,ah=digest(device),digest(access)
  if dh is None or ah is None or dh==ah:return False
  if type(ttl) is not int or not 60<=ttl<=604800:raise ValueError('invalid session duration')
  now=self.store.clock()
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    if db.execute('SELECT mode FROM device_issuance_control_v1 WHERE singleton=1').fetchone()!=('active',):db.execute('ROLLBACK');return False
    row=db.execute("SELECT account_id,session_hash,expires_at FROM device_sessions_v2 d WHERE device_hash=? AND revoked=0 AND expires_at>? AND EXISTS (SELECT 1 FROM device_scopes_v1 s WHERE s.device_hash=d.device_hash AND s.scope='speech')",(dh,now)).fetchone()
    if row is None:db.execute('ROLLBACK');return False
    account,previous,device_expiry=row
    if previous==ah:
     active=db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND account_id=? AND revoked=0 AND expires_at>?',(ah,account,now)).fetchone()
     db.execute('ROLLBACK');return active is not None
    if db.execute('SELECT 1 FROM sessions WHERE token_hash=?',(ah,)).fetchone() or db.execute('SELECT 1 FROM device_sessions_v2 WHERE device_hash=?',(ah,)).fetchone():db.execute('ROLLBACK');return False
    if previous is not None:db.execute('UPDATE sessions SET revoked=1 WHERE token_hash=?',(previous,))
    db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)',(ah,account,min(now+ttl,device_expiry)))
    db.execute('UPDATE device_sessions_v2 SET session_hash=? WHERE device_hash=?',(ah,dh))
    db.execute('COMMIT');return True
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise

 def revoke(self,device):
  dh=digest(device)
  if dh is None:return False
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    row=db.execute('SELECT session_hash FROM device_sessions_v2 WHERE device_hash=? AND revoked=0',(dh,)).fetchone()
    if row is None:db.execute('ROLLBACK');return False
    if row[0] is not None:db.execute('UPDATE sessions SET revoked=1 WHERE token_hash=?',(row[0],))
    db.execute('UPDATE device_sessions_v2 SET revoked=1 WHERE device_hash=?',(dh,))
    db.execute('COMMIT');return True
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise

 def renew_versioned(self,device,access,operation_id,expected_generation,ttl=604800):
  """One committed rotation per generation; retries reuse the same operation and secret."""
  dh,ah=digest(device),digest(access)
  if dh is None or ah is None or dh==ah or not isinstance(operation_id,str) or not re.fullmatch(r'[0-9a-f]{32}',operation_id):return False
  if type(expected_generation) is not int or not 0<=expected_generation<2**53:return False
  if type(ttl) is not int or not 60<=ttl<=604800:raise ValueError('invalid session duration')
  now=self.store.clock()
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    if db.execute('SELECT mode FROM device_issuance_control_v1 WHERE singleton=1').fetchone()!=('active',):db.execute('ROLLBACK');return False
    row=db.execute("SELECT account_id,session_hash,expires_at FROM device_sessions_v2 d WHERE device_hash=? AND revoked=0 AND expires_at>? AND EXISTS (SELECT 1 FROM device_scopes_v1 s WHERE s.device_hash=d.device_hash AND s.scope='speech')",(dh,now)).fetchone()
    if row is None:db.execute('ROLLBACK');return False
    account,previous,device_expiry=row
    prior=db.execute('SELECT expected_generation,session_hash FROM device_renewals_v1 WHERE device_hash=? AND operation_id=?',(dh,operation_id)).fetchone()
    if prior is not None:
     active=prior==(expected_generation,ah) and previous==ah and db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND account_id=? AND revoked=0 AND expires_at>?',(ah,account,now)).fetchone() is not None
     db.execute('ROLLBACK');return active
    db.execute('INSERT OR IGNORE INTO device_generations_v1(device_hash,generation) VALUES(?,0)',(dh,))
    generation=db.execute('SELECT generation FROM device_generations_v1 WHERE device_hash=?',(dh,)).fetchone()[0]
    if generation!=expected_generation or db.execute('SELECT 1 FROM sessions WHERE token_hash=?',(ah,)).fetchone() or db.execute('SELECT 1 FROM device_sessions_v2 WHERE device_hash=?',(ah,)).fetchone():db.execute('ROLLBACK');return False
    if previous is not None:db.execute('UPDATE sessions SET revoked=1 WHERE token_hash=?',(previous,))
    db.execute('INSERT INTO sessions(token_hash,account_id,expires_at) VALUES(?,?,?)',(ah,account,min(now+ttl,device_expiry)))
    db.execute('UPDATE device_sessions_v2 SET session_hash=? WHERE device_hash=?',(ah,dh))
    db.execute('UPDATE device_generations_v1 SET generation=generation+1 WHERE device_hash=?',(dh,))
    db.execute('INSERT INTO device_renewals_v1 VALUES(?,?,?,?)',(dh,operation_id,expected_generation,ah))
    db.execute('COMMIT');return True
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise
