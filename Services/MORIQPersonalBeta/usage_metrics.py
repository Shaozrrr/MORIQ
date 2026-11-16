"""Opt-in local metadata-only usage records; never stores prompt, response or IDs of users."""
import datetime,decimal,json,os,pathlib,re,sqlite3,stat,time,uuid,threading,fcntl,logging
from urllib.parse import quote
D=decimal.Decimal
_ID=re.compile(r'^[A-Za-z0-9._-]{1,80}$')

def load_rate_file(path,*,allowed_models,allowed_providers):
 p=pathlib.Path(path)
 if not p.is_absolute() or p.is_symlink() or p.parent.resolve()!=p.parent:raise ValueError('invalid rate path')
 fd=os.open(p,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0))
 try:
  st=os.fstat(fd)
  if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077 or st.st_size>65536:raise ValueError('private rate file required')
  raw=os.read(fd,65537)
 finally:os.close(fd)
 rates=json.loads(raw)
 if not isinstance(rates,dict) or len(rates)>100:raise ValueError('invalid rates')
 allowed={'provider','model','currency','effective_from','effective_to','other_fees_included','cached_input_per_million','uncached_input_per_million','output_per_million','audio_per_second'}
 required={'provider','model','currency','effective_from','effective_to','other_fees_included'}
 for version,rate in rates.items():
  if not isinstance(version,str) or not _ID.fullmatch(version) or not isinstance(rate,dict) or not required<=set(rate) or not set(rate)<=allowed:raise ValueError('invalid rate')
  if rate['provider'] not in allowed_providers or rate['model'] not in allowed_models or rate['currency'] not in ('USD','CNY') or type(rate['other_fees_included']) is not bool:raise ValueError('invalid rate')
  try:
   a=datetime.datetime.fromisoformat(rate['effective_from']);b=datetime.datetime.fromisoformat(rate['effective_to'])
   if a.tzinfo is None or b.tzinfo is None or a>=b:raise ValueError('invalid window')
   for key in ('cached_input_per_million','uncached_input_per_million','output_per_million','audio_per_second'):
    if key in rate:
     if not isinstance(rate[key],str):raise ValueError('decimal string required')
     v=D(rate[key])
     if not v.is_finite() or v<0:raise ValueError('invalid price')
  except (KeyError,TypeError,decimal.InvalidOperation):raise ValueError('invalid rate') from None
 windows={}
 for version,rate in rates.items():
  key=(rate['provider'],rate['model']);windows.setdefault(key,[]).append((datetime.datetime.fromisoformat(rate['effective_from']),datetime.datetime.fromisoformat(rate['effective_to'])))
 for intervals in windows.values():
  intervals.sort()
  if any(right[0]<left[1] for left,right in zip(intervals,intervals[1:])):raise ValueError('overlapping rate windows')
 return rates
class UsageRecorder:
 def __init__(self,path,*,allowed_models,rates,allowed_providers):
  p=pathlib.Path(path)
  if not p.is_absolute() or p.is_symlink() or p.parent.resolve()!=p.parent:raise ValueError('private path required')
  st=p.parent.stat()
  if st.st_uid!=os.getuid() or st.st_mode&0o077:raise ValueError('private directory required')
  try:fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY|getattr(os,'O_NOFOLLOW',0),0o600);os.close(fd)
  except FileExistsError:pass
  st=p.lstat()
  if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077:raise ValueError('private regular file required')
  if not isinstance(allowed_models,set) or not allowed_models or any(not isinstance(m,str) or not _ID.fullmatch(m) for m in allowed_models):raise ValueError('invalid model allowlist')
  if not isinstance(allowed_providers,set) or not allowed_providers or any(not isinstance(v,str) or not _ID.fullmatch(v) for v in allowed_providers):raise ValueError('invalid provider allowlist')
  self.path=str(p);self.models=allowed_models.copy();self.providers=allowed_providers.copy();self.rates=rates.copy();self._lock=threading.Lock();self._healthy=True
  with self.connect() as db:
   db.execute('CREATE TABLE IF NOT EXISTS events(request_id TEXT PRIMARY KEY,state TEXT NOT NULL,record TEXT NOT NULL)')
   if db.execute("SELECT 1 FROM events WHERE state='pending' LIMIT 1").fetchone():
    self._healthy=False;logging.getLogger('moriq.metrics').error('metrics_reconciliation_required')
 def connect(self):
  st=os.lstat(self.path)
  if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077:raise ValueError('private regular file required')
  return sqlite3.connect('file:'+quote(self.path,safe='/')+'?mode=rw',uri=True,timeout=2)
 def poison(self):
  with self._lock:
   if self._healthy:
    self._healthy=False;logging.getLogger('moriq.metrics').error('metrics_unavailable')
 def check_health(self):
  with self._lock:
   if not self._healthy:raise RuntimeError('metrics unavailable; reconciliation required')
 def accept_unknown_offline(self,ack):
  if ack!='offline-accept-unknown-usage':raise ValueError('offline acknowledgement required')
  lock_path=str(pathlib.Path(self.path).parent/'accounts.db.railway.lock')
  fd=os.open(lock_path,os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0),0o600)
  try:
   st=os.fstat(fd)
   if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077:raise ValueError('private service lock required')
   fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
   with self.connect() as db:db.execute("UPDATE events SET state='accepted_unknown' WHERE state='pending'")
   with self._lock:self._healthy=True
  finally:os.close(fd)
 def start(self,*,kind,model,provider,rate_version=None):
  self.check_health()
  if kind not in ('speech','translation','assistant') or model not in self.models or provider not in self.providers:raise ValueError('invalid request metadata')
  if rate_version is not None and (not isinstance(rate_version,str) or not _ID.fullmatch(rate_version) or rate_version not in self.rates):raise ValueError('invalid rate version')
  if rate_version is None:
   now=datetime.datetime.now(datetime.timezone.utc);choices=[]
   for version,rate in self.rates.items():
    if rate.get('provider')==provider and rate.get('model')==model and datetime.datetime.fromisoformat(rate['effective_from'])<=now<datetime.datetime.fromisoformat(rate['effective_to']):choices.append(version)
   if len(choices)>1:raise ValueError('overlapping rate windows')
   if choices:rate_version=choices[0]
  return Event(self,kind,model,provider,rate_version)
 def persist(self,record,*,initial=False):
  self.check_health()
  try:
   with self.connect() as db:
    if initial:db.execute('INSERT INTO events VALUES (?,?,?)',(record['request_id'],'pending',json.dumps(record,separators=(',',':'))))
    else:
     cur=db.execute('UPDATE events SET state=?,record=? WHERE request_id=? AND state=?',('finished',json.dumps(record,separators=(',',':')),record['request_id'],'pending'))
     if cur.rowcount!=1:raise ValueError('already finalized or unknown event')
  except Exception:
   self.poison();raise
class Event:
 def __init__(self,rec,kind,model,provider,rate):
  self.rec=rec;self.request_id=uuid.uuid4().hex;self.claim_id=None;self.kind=kind;self.model=model;self.provider=provider;self.rate=rate;self.start_ns=time.monotonic_ns();self.started_at=datetime.datetime.now(datetime.timezone.utc).isoformat();self.usage=None;self.audio_ms=None;self.reserved_ms=None;self.attempted_samples=None;self.sent_samples=None;self.sample_rate=None;self.dispatched=False;self.provider_responded=False;self.usage_final=False;self.finalized=False
  rec.persist({'request_id':self.request_id,'kind':kind,'model':model,'provider':provider,'started_at':self.started_at,'outcome':'incomplete_unknown','inbound_attempts':1,'upstream_attempts':0,'provider_response_received':None,'retries':None,'provider_usage':None,'reserved_audio_ms':None,'send_attempt_samples_upper_bound':None,'sent_samples_lower_bound':None,'sample_rate':None,'rate_version':rate,'estimated_cost':None,'billed_cost':None},initial=True)
 def observe_usage(self,usage,*,final=False):
  if not isinstance(usage,dict):return
  values=tuple(usage.get(k) for k in ('prompt_tokens','completion_tokens'))
  if any(type(v) is not int or v<0 or v>10**9 for v in values):return
  if self.usage is not None and (values[0]<self.usage[0] or values[1]<self.usage[1]):return
  hit=usage.get('prompt_cache_hit_tokens');miss=usage.get('prompt_cache_miss_tokens')
  if type(hit) is not int or type(miss) is not int or hit<0 or miss<0 or hit+miss!=values[0]:hit=miss=None
  self.usage=(values[0],values[1],hit,miss)
  if final is True:self.usage_final=True
 def mark_usage_final(self):
  if self.usage is not None:self.usage_final=True
 def attach_claim(self,claim_id):
  if self.claim_id is not None or not isinstance(claim_id,str) or not re.fullmatch(r'[0-9a-f]{32}',claim_id):raise ValueError('invalid claim')
  self.claim_id=claim_id;self.checkpoint()
 def mark_dispatch(self):
  if self.dispatched:raise ValueError('duplicate dispatch')
  self.dispatched=True
  self.checkpoint()
 def mark_provider_response(self):
  if not self.dispatched:raise ValueError('response without attempt')
  if not self.provider_responded:
   self.provider_responded=True;self.checkpoint()
 def set_provider_audio_ms(self,value):
  if type(value) is not int or not 0<=value<=86400000:raise ValueError('invalid duration')
  self.audio_ms=value
 def set_audio_observation(self,*,reserved_ms,sent_samples,sample_rate,attempted_samples=None):
  if any(type(v) is not int or v<0 for v in (reserved_ms,sent_samples)) or type(sample_rate) is not int or not 1<=sample_rate<=192000:raise ValueError('invalid audio observation')
  if attempted_samples is not None and (type(attempted_samples) is not int or attempted_samples<sent_samples):raise ValueError('invalid attempted samples')
  self.reserved_ms=reserved_ms;self.attempted_samples=attempted_samples;self.sent_samples=sent_samples;self.sample_rate=sample_rate
 def checkpoint(self):
  record={'request_id':self.request_id,'kind':self.kind,'model':self.model,'provider':self.provider,'started_at':self.started_at,'outcome':'incomplete_unknown','inbound_attempts':1,'upstream_attempts':int(self.dispatched),'provider_response_received':True if self.provider_responded else None,'retries':None,'provider_usage':None,'reserved_audio_ms':self.reserved_ms,'send_attempt_samples_upper_bound':self.attempted_samples,'sent_samples_lower_bound':self.sent_samples,'sample_rate':self.sample_rate,'rate_version':self.rate,'estimated_cost':None,'billed_cost':None}
  if self.claim_id is not None:record['claim_id']=self.claim_id
  self.rec.check_health()
  try:
   with self.rec.connect() as db:
    cur=db.execute('UPDATE events SET record=? WHERE request_id=? AND state=?',(json.dumps(record,separators=(',',':')),self.request_id,'pending'))
    if cur.rowcount!=1:raise ValueError('unknown pending event')
  except Exception:
   self.rec.poison();raise
 def finish(self,outcome,*,retries=0):
  if self.finalized:raise ValueError('already finalized')
  if outcome not in ('success','failure','cancelled') or type(retries) is not int or not 0<=retries<=100:raise ValueError('invalid outcome')
  rate=self.rec.rates.get(self.rate);estimate=None;currency=None
  if rate is not None:
   currency=rate.get('currency')
   if currency not in ('USD','CNY'):raise ValueError('invalid currency')
   required={'audio_per_second'} if self.kind=='speech' else {'cached_input_per_million','uncached_input_per_million','output_per_million'}
   value=D('0');known=outcome=='success' and self.dispatched and self.usage_final and rate.get('other_fees_included') is True and required.issubset(rate)
   now=datetime.datetime.now(datetime.timezone.utc)
   try:
    lo=datetime.datetime.fromisoformat(rate['effective_from']);hi=datetime.datetime.fromisoformat(rate['effective_to'])
    known=known and lo.tzinfo is not None and hi.tzinfo is not None and lo<=now<hi and rate.get('provider')==self.provider and rate.get('model')==self.model
   except (KeyError,TypeError,ValueError):known=False
   for k,raw,divisor in [('cached_input_per_million',None if self.usage is None else self.usage[2],1000000),('uncached_input_per_million',None if self.usage is None else self.usage[3],1000000),('output_per_million',None if self.usage is None else self.usage[1],1000000),('audio_per_second',self.audio_ms,1000)]:
    if k in rate:
     price=D(str(rate[k]));
     if not price.is_finite() or price<0:raise ValueError('invalid rate')
     if raw is None:known=False
     else:value+=D(raw)*price/D(divisor)
   if known and any(k in rate for k in ('cached_input_per_million','uncached_input_per_million','output_per_million','audio_per_second')):estimate=str(value)
  record={'request_id':self.request_id,'kind':self.kind,'model':self.model,'provider':self.provider,'started_at':self.started_at,'duration_ms':max(0,(time.monotonic_ns()-self.start_ns)//1000000),'outcome':outcome,'usage_final':self.usage_final,'provider_usage':{'input_tokens':None if self.usage is None else self.usage[0],'output_tokens':None if self.usage is None else self.usage[1],'cached_input_tokens':None if self.usage is None else self.usage[2],'uncached_input_tokens':None if self.usage is None else self.usage[3],'audio_ms':self.audio_ms},'reserved_audio_ms':self.reserved_ms,'send_attempt_samples_upper_bound':self.attempted_samples,'sent_samples_lower_bound':self.sent_samples,'sample_rate':self.sample_rate,'inbound_attempts':1,'upstream_attempts':int(self.dispatched),'provider_response_received':True if self.provider_responded else None,'retries':retries,'rate_version':self.rate,'currency':currency,'estimated_cost':estimate,'billed_cost':None}
  if self.claim_id is not None:record['claim_id']=self.claim_id
  self.rec.persist(record);self.finalized=True
  return record
