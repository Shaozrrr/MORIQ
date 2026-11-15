"""Isolated protocol contract model; never imported by production."""
import hashlib
ASCII_SPACE=set(b' \t\r\n')
FLAG='source_units_punct_v1'
class SourceCapacity(Exception):pass
def negotiated(request,ready):
 return request.get(FLAG) is True and ready.get(FLAG) is True and request.get('source_units_atomic_v1') is True and ready.get('source_units_atomic_v1') is True

def make_batch(collector,events,seq,finished,request,ready):
 if not negotiated(request,ready):raise ValueError('not negotiated')
 units=collector.accept(events,seq,finished=False)
 if not collector.enabled:
  if collector.failure_reason=='capacity':raise SourceCapacity('source capacity')
  raise ValueError('collector disabled')
 ranges=[]
 if finished and collector.pending:
  if collector.pending.strip():
   units+=collector.accept([],seq,finished=True)
  else:
   data=collector.pending.encode()
   if not data or any(b not in ASCII_SPACE for b in data):raise ValueError('unsupported whitespace')
   ranges.append({'start_byte':collector.start_byte,'end_byte':collector.confirmed_bytes})
   collector.pending='';collector.start_byte=collector.confirmed_bytes
 if not collector.enabled:
  if collector.failure_reason=='capacity':raise SourceCapacity('source capacity')
  raise ValueError('collector disabled')
 return {'source_units':units,'nonbillable_ranges':ranges,'source_coverage':{'confirmed_through_byte':collector.confirmed_bytes,'covered_through_byte':collector.start_byte,'state':'complete' if finished else 'open'}}

class CoverageVerifier:
 def __init__(self,request,ready):
  if not negotiated(request,ready):raise ValueError('not negotiated')
  self.cursor=0;self.complete=False
 def accept(self,batch,confirmed,finished):
  if self.complete:raise ValueError('after completion')
  data=confirmed.encode();c=batch['source_coverage'];limit=c['confirmed_through_byte']
  if type(limit)!=int or limit!=len(data) or c['state'] not in ('open','complete') or (c['state']=='complete')!=finished:raise ValueError('invalid coverage')
  if batch['nonbillable_ranges'] and not finished:raise ValueError('skip only at finish')
  for group in (batch['source_units'],batch['nonbillable_ranges']):
   if [x['start_byte'] for x in group]!=sorted(x['start_byte'] for x in group):raise ValueError('unordered')
  entries=[(x['start_byte'],x['end_byte'],False,x) for x in batch['source_units']]+[(x['start_byte'],x['end_byte'],True,x) for x in batch['nonbillable_ranges']]
  pos=self.cursor;seen_skip=False
  for start,end,skip,item in sorted(entries,key=lambda x:x[0]):
   if type(start)!=int or type(end)!=int or start!=pos or not start<end<=limit:raise ValueError('gap/overlap')
   piece=data[start:end]
   if seen_skip and not skip:raise ValueError('skip must be trailing')
   seen_skip=seen_skip or skip
   if skip and any(b not in ASCII_SPACE for b in piece):raise ValueError('non-whitespace skip')
   if not skip and item['source_sha256']!=hashlib.sha256(piece).hexdigest():raise ValueError('unit hash')
   pos=end
  if c['covered_through_byte']!=pos or (finished and pos!=limit):raise ValueError('incomplete coverage')
  self.cursor=pos;self.complete=finished
