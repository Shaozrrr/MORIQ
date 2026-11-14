"""Experimental volatile SourceUnit store with persistent non-content budget claims.

Dropping Python references is not a physical memory wipe. No production entry
deployment, swap/core-dump protection or cross-instance routing.
"""
import asyncio,datetime,hashlib,threading,time,uuid
from account_store import AccountSession

def ident(value):
 try:return isinstance(value,str) and str(uuid.UUID(value))==value.lower()
 except (ValueError,AttributeError):return False

class MemorySourceLedger:
 def __init__(self,accounts,*,fake_only=False,ttl=120,max_units=200,max_bytes=512000,clock=time.monotonic):
  if fake_only is not True or not 0<ttl<=600 or type(max_units) is not int or not 1<=max_units<=1000 or type(max_bytes) is not int or not 1<=max_bytes<=2000000:raise ValueError('disabled or invalid limits')
  self.accounts=accounts;self.ttl=ttl;self.max_units=max_units;self.max_bytes=max_bytes;self.clock=clock
  self.lock=threading.RLock();self.units={};self.used_units=set();self.closed=set();self.sessions={};self.generation=0
  self._stop=threading.Event()
  self._cleaner=threading.Thread(target=self._cleanup_loop,daemon=True,name='caption-source-expiry')
  with self.accounts._connection() as db:
   db.executescript('''CREATE TABLE IF NOT EXISTS volatile_source_claims (session TEXT NOT NULL,epoch TEXT NOT NULL,unit TEXT NOT NULL,revision INTEGER NOT NULL,target TEXT NOT NULL,PRIMARY KEY(session,epoch,unit,revision));
   CREATE TABLE IF NOT EXISTS volatile_source_chars (account_id TEXT NOT NULL,day TEXT NOT NULL,characters INTEGER NOT NULL,PRIMARY KEY(account_id,day));
   CREATE TABLE IF NOT EXISTS volatile_source_global_chars (day TEXT PRIMARY KEY,characters INTEGER NOT NULL);''')
  self._cleaner.start()
 def _cleanup_loop(self):
  while not self._stop.wait(min(1.0,self.ttl)):
   with self.lock:self._purge()
 def shutdown(self):
  self._stop.set();self._cleaner.join(timeout=2)
  with self.lock:
   self.units.clear();self.used_units.clear();self.sessions.clear();self.closed.clear();self.generation+=1
 def _auth(self,db,account):
  return isinstance(account,AccountSession) and bool(db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND account_id=? AND revoked=0 AND expires_at>?',(account.token_hash,account.account,self.accounts.clock())).fetchone())
 def _purge(self):
  now=self.clock()
  for key,value in list(self.units.items()):
   if value[2]<=now:del self.units[key]
 def put_final(self,account,session,epoch,unit,revision,tokens):
  if not all(ident(x) for x in (session,epoch,unit)) or type(revision) is not int or not 0<revision<=2**53-1 or not isinstance(tokens,list) or not 1<=len(tokens)<=1000:raise ValueError('invalid')
  if any(not isinstance(t,dict) or set(t)!={'text','is_final','translation_status'} or t['is_final'] is not True or t['translation_status'] not in ('original','none') or not isinstance(t['text'],str) for t in tokens):raise ValueError('final source only')
  text=''.join(t['text'] for t in tokens)
  if not text.strip() or len(text)>4000 or any(x in text for x in ('<end>','<fin>')):raise ValueError('invalid')
  key=(session,epoch,unit,revision)
  with self.lock:
   self._purge()
   with self.accounts._connection() as db:
    if not self._auth(db,account):raise PermissionError('unauthorized')
   if (session,epoch) in self.closed:raise ValueError('closed')
   if session not in self.sessions and len(self.sessions)>=1000:raise ValueError('session capacity')
   if self.sessions.get(session,account.account)!=account.account:raise PermissionError('owner')
   if key in self.used_units:raise ValueError('duplicate')
   if len(self.used_units)>=50000:raise ValueError('unit history capacity')
   if len(self.units)>=self.max_units or sum(len(v[1].encode()) for v in self.units.values())+len(text.encode())>self.max_bytes:raise ValueError('capacity')
   self.sessions[session]=account.account;self.units[key]=(account.account,text,self.clock()+self.ttl);self.used_units.add(key)
   return hashlib.sha256(text.encode()).hexdigest()
 def close_epoch(self,account,session,epoch):
  if not isinstance(account,AccountSession) or not all(ident(x) for x in (session,epoch)):raise ValueError('invalid')
  with self.lock:
   if self.sessions.get(session,account.account)!=account.account:raise PermissionError('owner')
   if (session,epoch) not in self.closed and len(self.closed)>=1000:raise ValueError('epoch capacity')
   self.closed.add((session,epoch));self.generation+=1
   for key in list(self.units):
    if key[:2]==(session,epoch):del self.units[key]
 def _claim(self,account,session,epoch,unit,revision,target,context_cost=0):
  if not all(ident(x) for x in (session,epoch,unit)) or type(revision) is not int or not 0<revision<=2**53-1 or target not in ('en-US','zh-Hans') or type(context_cost) is not int or not 0<=context_cost<=512:raise ValueError('invalid')
  key=(session,epoch,unit,revision)
  with self.lock:
   self._purge();value=self.units.get(key)
   if value is None or value[0]!=account.account or (session,epoch) in self.closed:raise PermissionError('unavailable')
   versions=[k[3] for k in self.units if k[:3]==key[:3]]
   if not versions or revision!=max(versions):raise ValueError('stale')
   text=value[1];now=self.accounts.clock();day=datetime.datetime.fromtimestamp(now,datetime.timezone.utc).date().isoformat()
   with self.accounts._connection() as db:
    try:
     db.execute('BEGIN IMMEDIATE')
     if not self._auth(db,account):raise PermissionError('unauthorized')
     guest=db.execute('SELECT lifetime_seconds,used_seconds,lifetime_requests,used_requests FROM guest_accounts WHERE account_id=?',(account.account,)).fetchone()
     if guest and (guest[1]>=guest[0] or guest[3]>=guest[2]):raise PermissionError('quota')
     lim=db.execute('SELECT daily_limit FROM accounts WHERE account_id=?',(account.account,)).fetchone()
     gl=db.execute('SELECT daily_requests FROM global_limits WHERE singleton=1').fetchone()
     used=db.execute('SELECT requests FROM daily_usage WHERE account_id=? AND day=?',(account.account,day)).fetchone()
     gu=db.execute('SELECT requests FROM global_usage WHERE day=?',(day,)).fetchone()
     chars=db.execute('SELECT characters FROM volatile_source_chars WHERE account_id=? AND day=?',(account.account,day)).fetchone()
     gc=db.execute('SELECT characters FROM volatile_source_global_chars WHERE day=?',(day,)).fetchone()
     count=len(text)+context_cost
     if not lim or not gl or (used[0] if used else 0)>=lim[0] or (gu[0] if gu else 0)>=gl[0] or (chars[0] if chars else 0)+count>20000 or (gc[0] if gc else 0)+count>100000:raise PermissionError('quota')
     if self.accounts.requests_per_minute is not None:
      minute=int(now//60);rate=db.execute('SELECT requests FROM minute_usage WHERE account_id=? AND minute=?',(account.account,minute)).fetchone()
      if rate and rate[0]>=self.accounts.requests_per_minute:raise PermissionError('quota')
      db.execute('DELETE FROM minute_usage WHERE account_id=? AND minute<?',(account.account,minute-1))
      db.execute('INSERT INTO minute_usage VALUES(?,?,1) ON CONFLICT(account_id,minute) DO UPDATE SET requests=requests+1',(account.account,minute))
     db.execute('INSERT INTO volatile_source_claims VALUES(?,?,?,?,?)',(session,epoch,unit,revision,target))
     if guest:db.execute('UPDATE guest_accounts SET used_requests=used_requests+1 WHERE account_id=?',(account.account,))
     db.execute('INSERT INTO daily_usage VALUES(?,?,1) ON CONFLICT(account_id,day) DO UPDATE SET requests=requests+1',(account.account,day))
     db.execute('INSERT INTO global_usage VALUES(?,1,0) ON CONFLICT(day) DO UPDATE SET requests=requests+1',(day,))
     db.execute('INSERT INTO volatile_source_chars VALUES(?,?,?) ON CONFLICT(account_id,day) DO UPDATE SET characters=characters+excluded.characters',(account.account,day,count))
     db.execute('INSERT INTO volatile_source_global_chars VALUES(?,?) ON CONFLICT(day) DO UPDATE SET characters=characters+excluded.characters',(day,count))
     db.execute('COMMIT')
    except BaseException:
     if db.in_transaction:db.execute('ROLLBACK')
     raise
   return text,hashlib.sha256(text.encode()).hexdigest(),value[2]
 def is_live(self,account,request):
  key=tuple(request[k] for k in ('session','epoch','unit','revision'))
  with self.lock:
   self._purge();value=self.units.get(key)
   if not value or value[0]!=account.account or key[:2] in self.closed:return False
   if max((k[3] for k in self.units if k[:3]==key[:3]),default=0)!=key[3]:return False
   with self.accounts._connection() as db:return self._auth(db,account)
 async def review(self,account,request,provider,*,context_cost=0):
  if not isinstance(request,dict) or set(request)!={'session','epoch','unit','revision','target'}:raise ValueError('only references allowed')
  source,digest,expires=await asyncio.to_thread(self._claim,account,*(request[k] for k in ('session','epoch','unit','revision','target')),context_cost)
  try:candidate=await asyncio.wait_for(provider(source,request['target']),3)
  except Exception:return {'status':'unavailable','auto_apply':False}
  with self.lock:
   self._purge();key=tuple(request[k] for k in ('session','epoch','unit','revision'))
   valid=key in self.units and self.units[key][0]==account.account and self.clock()<expires and max((k[3] for k in self.units if k[:3]==key[:3]),default=0)==request['revision']
   with self.accounts._connection() as db:valid=valid and self._auth(db,account)
  if not valid or not isinstance(candidate,str) or not candidate.strip() or len(candidate)>4000:return {'status':'unavailable','auto_apply':False}
  return {'status':'candidate','candidate':candidate,'source_sha256':digest,'association_verified':False,'auto_apply':False,**request}
