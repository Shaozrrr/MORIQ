"""Candidate scope checks: callers must additionally enforce global limits."""
from device_invites import digest
import re

class DeviceScopes:
 def __init__(self,store):self.store=store
 def permits(self,access,scope):
  return self.permits_hash(digest(access),scope)
 def permits_hash(self,ah,scope):
  if not isinstance(ah,str) or not re.fullmatch(r'[0-9a-f]{64}',ah) or scope not in ('speech','assistant'):return False
  now=self.store.clock()
  with self.store._connection() as db:
   return db.execute('''SELECT 1 FROM device_sessions_v2 d
    JOIN device_scopes_v1 p ON p.device_hash=d.device_hash
    JOIN sessions s ON s.token_hash=d.session_hash AND s.account_id=d.account_id
    WHERE d.session_hash=? AND p.scope=? AND d.revoked=0 AND d.expires_at>?
    AND s.revoked=0 AND s.expires_at>?''',(ah,scope,now,now)).fetchone() is not None

class ScopedAccountStore:
 """Fail-closed adapter for one gateway; existing legacy sessions are not accepted."""
 def __init__(self,store,scope,allow_legacy=False):
  if scope not in ('speech','assistant'):raise ValueError('invalid scope')
  if type(allow_legacy) is not bool:raise ValueError('invalid legacy policy')
  self.store=store;self.scope=scope;self.scopes=DeviceScopes(store);self.allow_legacy=allow_legacy
 def authenticate(self,token_hash):
  if self.scopes.permits_hash(token_hash,self.scope):return self.store.authenticate(token_hash)
  if not self.allow_legacy:return None
  account=self.store.authenticate(token_hash)
  if account is None:return None
  with self.store._connection() as db:
   device=db.execute('SELECT 1 FROM device_sessions_v2 WHERE session_hash=?',(token_hash,)).fetchone()
  return account if device is None else None
 def __getattr__(self,name):return getattr(self.store,name)
