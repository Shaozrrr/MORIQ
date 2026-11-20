"""Isolated activation HTTP candidate; never expose without durable rate limiting."""
import asyncio
import time
import sqlite3
import threading
import hashlib
import ipaddress
from device_invites import digest
from aiohttp import web

class LocalWindowLimit:
 def __init__(self,limit=12,seconds=60,clock=time.monotonic):
  self.limit=limit;self.seconds=seconds;self.clock=clock;self.events=[];self.lock=threading.Lock()
 def admit(self):
  with self.lock:
   now=self.clock();self.events=[t for t in self.events if now-t<self.seconds]
   if len(self.events)>=self.limit:return False
   self.events.append(now);return True

def make_app(activation, limiter=None, trusted_proxies=()):
 limiter=limiter or LocalWindowLimit()
 trusted={str(ipaddress.ip_address(value)) for value in trusted_proxies}
 app=web.Application(client_max_size=2048)
 async def handle(request):
  try:
   body=None
   try:
    if request.content_type!='application/json':raise ValueError()
    body=await request.json()
    required={'device','access','invite'} if request.path.endswith('/activate') else {'device','access','operation_id','generation'}
    if not isinstance(body,dict) or set(body)!=required or not all(isinstance(body[k],str) for k in required-{'generation'}) or ('generation' in body and type(body['generation']) is not int):raise ValueError()
    if len(body['invite'] if request.path.endswith('/activate') else body['device'])>256:raise ValueError()
   except (ValueError,TypeError,web.HTTPRequestEntityTooLarge):body=None
   if isinstance(limiter,IdentityWindowLimit):
    allowed=await asyncio.to_thread(limiter.admit,request.path.endswith('/activate'),body)
   elif isinstance(limiter,FairWindowLimit):
    peer=str(ipaddress.ip_address(request.remote))
    if peer in trusted:
     forwarded=request.headers.get('X-Forwarded-For','')
     # A trusted edge must supply one sanitized client address, never a chain.
     if ',' in forwarded:raise ValueError()
     peer=str(ipaddress.ip_address(forwarded))
    credential=(body['invite'] if request.path.endswith('/activate') else body['device']) if body else 'invalid:'+peer
    allowed=await asyncio.to_thread(limiter.admit,peer,credential)
   else:allowed=await asyncio.to_thread(limiter.admit)
   if not allowed:return web.json_response({'ok':False},status=429,headers={'Cache-Control':'no-store','Retry-After':str(limiter.seconds)})
   if body is None:raise ValueError()
   if request.path.endswith('/activate'):
    result=await asyncio.to_thread(activation.activate,body['invite'],body['device'],body['access'])
   else:result=await asyncio.to_thread(activation.devices.renew_versioned,body['device'],body['access'],body['operation_id'],body['generation'])
  except sqlite3.Error:return web.json_response({'ok':False},status=503,headers={'Cache-Control':'no-store'})
  except (ValueError,TypeError,web.HTTPRequestEntityTooLarge):result=False
  if result:
   with activation.store._connection() as db:
    row=db.execute('SELECT expires_at FROM sessions WHERE token_hash=? AND revoked=0',(digest(body['access']),)).fetchone()
   remaining=int(row[0]-activation.store.clock()) if row else 0
   if remaining<=0:return web.json_response({'ok':False},status=400,headers={'Cache-Control':'no-store'})
   return web.json_response({'ok':True,'expires_in':remaining},headers={'Cache-Control':'no-store'})
  return web.json_response({'ok':False},status=400,headers={'Cache-Control':'no-store'})
 app.router.add_post('/v1/devices/activate',handle);app.router.add_post('/v1/devices/renew',handle)
 return app

class IdentityWindowLimit:
 """Bound unknown requests separately; valid invite/device secrets share no origin bucket."""
 def __init__(self,store,*,known_limit=120,unknown_limit=12,credential_limit=6,seconds=60):
  if any(type(x) is not int or x<1 or x>100000 for x in (known_limit,unknown_limit,credential_limit,seconds)) or seconds>3600:raise ValueError('invalid limits')
  self.store=store;self.seconds=seconds;self.limits=(known_limit,unknown_limit,credential_limit)
  with store._connection() as db:db.execute('CREATE TABLE IF NOT EXISTS identity_activation_limits_v1 (bucket INTEGER NOT NULL, category TEXT NOT NULL, key_hash TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(bucket,category,key_hash))')
 def admit(self,is_activation,body):
  key=digest(body.get('invite' if is_activation else 'device')) if body else None
  bucket=int(self.store.clock()//self.seconds)
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    now=self.store.clock()
    recovery=False
    if is_activation:
     row=db.execute('SELECT device_hash FROM activation_invites_v2 WHERE invite_hash=? AND cancelled=0 AND expires_at>?',(key,now)).fetchone() if key else None
     known=row is not None and row[0] is None
     if row is not None and row[0] is not None and body:
      device_hash=digest(body.get('device'));access_hash=digest(body.get('access'))
      recovery=device_hash is not None and access_hash is not None and db.execute('''SELECT 1 FROM device_sessions_v2 d JOIN sessions s ON s.token_hash=d.session_hash WHERE d.device_hash=? AND d.device_hash=? AND d.session_hash=? AND d.revoked=0 AND d.expires_at>? AND s.revoked=0 AND s.expires_at>?''',(row[0],device_hash,access_hash,now,now)).fetchone() is not None
      if recovery:key=device_hash
    else:
     known=key is not None and db.execute('SELECT 1 FROM device_sessions_v2 WHERE device_hash=? AND revoked=0 AND expires_at>?',(key,now)).fetchone() is not None
     if not known and key is not None and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='anonymous_accounts_v1'").fetchone():
      known=db.execute('SELECT 1 FROM device_sessions_v2 d JOIN anonymous_accounts_v1 a ON a.device_hash=d.device_hash WHERE d.device_hash=? AND d.revoked=0',(key,)).fetchone() is not None
    category='recovery' if recovery else ('known' if known else 'unknown')
    entries=[(category,'*',self.limits[0] if known or recovery else self.limits[1])]
    if known or recovery:entries.append((category+':credential',key,self.limits[2]))
    for category,k,limit in entries:
     row=db.execute('SELECT count FROM identity_activation_limits_v1 WHERE bucket=? AND category=? AND key_hash=?',(bucket,category,k)).fetchone()
     if row and row[0]>=limit:db.execute('ROLLBACK');return False
    for category,k,_ in entries:
     db.execute('INSERT INTO identity_activation_limits_v1 VALUES(?,?,?,1) ON CONFLICT(bucket,category,key_hash) DO UPDATE SET count=count+1',(bucket,category,k))
    db.execute('DELETE FROM identity_activation_limits_v1 WHERE bucket<?',(bucket-1,))
    db.execute('COMMIT');return True
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise

class PersistentWindowLimit:
 """Global fail-closed window for a single SQLite volume; not per-user fairness."""
 def __init__(self,store,limit=12,seconds=60):
  if type(limit) is not int or not 1<=limit<=10000 or type(seconds) is not int or not 1<=seconds<=3600:raise ValueError('invalid limit')
  self.store=store;self.limit=limit;self.seconds=seconds
  with store._connection() as db:
   db.execute('CREATE TABLE IF NOT EXISTS activation_limit_v1 (bucket INTEGER PRIMARY KEY, count INTEGER NOT NULL CHECK(count>=0))')
 def admit(self):
  bucket=int(self.store.clock()//self.seconds)
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    row=db.execute('SELECT count FROM activation_limit_v1 WHERE bucket=?',(bucket,)).fetchone()
    if row is not None and row[0]>=self.limit:db.execute('ROLLBACK');return False
    db.execute('INSERT INTO activation_limit_v1(bucket,count) VALUES(?,1) ON CONFLICT(bucket) DO UPDATE SET count=count+1',(bucket,))
    db.execute('DELETE FROM activation_limit_v1 WHERE bucket<?',(bucket-1,))
    db.execute('COMMIT');return True
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise

class FairWindowLimit:
 """SQLite, single instance; never store plaintext IP or submitted credential."""
 def __init__(self,store,*,global_limit=120,origin_limit=12,credential_limit=6,seconds=60):
  if any(type(x) is not int or x<1 or x>100000 for x in (global_limit,origin_limit,credential_limit,seconds)) or seconds>3600:raise ValueError('invalid limits')
  self.store=store;self.seconds=seconds;self.limits=(global_limit,origin_limit,credential_limit)
  with store._connection() as db:db.execute('CREATE TABLE IF NOT EXISTS fair_activation_limits_v1 (bucket INTEGER NOT NULL, category TEXT NOT NULL, key_hash TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(bucket,category,key_hash))')
 def admit(self,origin,credential):
  ipaddress.ip_address(origin)
  if not isinstance(credential,str) or len(credential)>256:raise ValueError('invalid credential')
  key=lambda value:hashlib.sha256(value.encode('utf-8')).hexdigest()
  entries=(('global','*'),('origin',key(origin)),('credential',key(credential)))
  bucket=int(self.store.clock()//self.seconds)
  with self.store._connection() as db:
   try:
    db.execute('BEGIN IMMEDIATE')
    for (category,k),limit in zip(entries,self.limits):
     row=db.execute('SELECT count FROM fair_activation_limits_v1 WHERE bucket=? AND category=? AND key_hash=?',(bucket,category,k)).fetchone()
     if row and row[0]>=limit:db.execute('ROLLBACK');return False
    for category,k in entries:
     db.execute('INSERT INTO fair_activation_limits_v1 VALUES(?,?,?,1) ON CONFLICT(bucket,category,key_hash) DO UPDATE SET count=count+1',(bucket,category,k))
    db.execute('DELETE FROM fair_activation_limits_v1 WHERE bucket<?',(bucket-1,))
    db.execute('COMMIT');return True
   except BaseException:
    if db.in_transaction:db.execute('ROLLBACK')
    raise
