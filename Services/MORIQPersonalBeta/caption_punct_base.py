"""Fake-only v2: source spans tied to already-sent native batches."""
import uuid,time
class SourceUnitCollectorV2:
 def __init__(self,ledger,account,*,with_context=False):
  self.ledger=ledger;self.account=account;self.session=str(uuid.uuid4());self.epoch=str(uuid.uuid4());self.original_stream_id=str(uuid.uuid4())
  self.pending='';self.start_byte=0;self.confirmed_bytes=0;self.enabled=True;self.history='';self.contexts={};self.with_context=with_context;self.deadline=None
 def accept(self,events,batch_seq,finished=False):
  if not self.enabled:return []
  if type(batch_seq) is not int or batch_seq<=0:self.enabled=False;return []
  result=[]
  try:
   for event in events:
    if event.get('type')=='lane_delta' and event.get('lane')=='original':
     delta=event['confirmed_delta']
     if not isinstance(delta,str) or type(event.get('confirmed_utf8_offset')) is not int or event['confirmed_utf8_offset']!=self.confirmed_bytes:raise ValueError('non-contiguous source')
     self.pending+=delta;self.confirmed_bytes+=len(delta.encode())
     if len(self.pending)>4000:raise ValueError('source too long')
    elif event.get('type')=='stream_marker':result.extend(self._flush('endpoint'))
   if finished:result.extend(self._flush('finish',force=True))
   for value in result:value.update(batch_seq=batch_seq,confirmed_through_byte=self.confirmed_bytes)
   return result
  except Exception:
   self.enabled=False;self.pending='';return []
 def _flush(self,reason,force=False):
  if self.with_context and not force and self.pending.rstrip().endswith((',', '，')) and len(self.pending)<2000:
   if self.deadline is None:self.deadline=time.monotonic()+.5
   return []
  self.deadline=None
  text=self.pending;self.pending='';start=self.start_byte;self.start_byte=self.confirmed_bytes
  if not text.strip():return []
  unit=str(uuid.uuid4())
  if self.with_context:
   if len(self.contexts)>=1000:raise ValueError('context capacity')
   self.contexts[unit]=self.history[-512:];self.history=(self.history+text)[-512:]
  digest=self.ledger.put_final(self.account,self.session,self.epoch,unit,1,[{'text':text,'is_final':True,'translation_status':'original'}])
  return [{'type':'source_unit_v2','session':self.session,'epoch':self.epoch,'unit':unit,'revision':1,'original_stream_id':self.original_stream_id,
           'start_byte':start,'end_byte':self.confirmed_bytes,'source_sha256':digest,'boundary_reason':reason}]
 def flush_due(self,batch_seq):
  if not self.enabled or self.deadline is None or time.monotonic()<self.deadline:return []
  try:
   result=self._flush('endpoint',force=True)
   for value in result:value.update(batch_seq=batch_seq,confirmed_through_byte=self.confirmed_bytes)
   return result
  except Exception:
   self.enabled=False;self.pending='';return []
 def close(self):
  self.enabled=False;self.pending='';self.history='';self.contexts.clear();self.deadline=None;self.ledger.close_epoch(self.account,self.session,self.epoch)
