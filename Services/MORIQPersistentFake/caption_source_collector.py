"""Experimental bridge from native Soniox validated final lane deltas only."""
import uuid
class SourceUnitCollector:
 def __init__(self,ledger,account):
  self.ledger=ledger;self.account=account;self.session=str(uuid.uuid4());self.epoch=str(uuid.uuid4());self.pending='';self.enabled=True
 def accept(self,events,finished=False):
  if not self.enabled:return []
  published=[]
  try:
   for event in events:
    if event.get('type')=='lane_delta' and event.get('lane')=='original':
     # Only confirmed_delta was sourced from validated is_final tokens.
     self.pending+=event['confirmed_delta']
     if len(self.pending)>4000:raise ValueError('source too long')
    elif event.get('type')=='stream_marker':
     published.extend(self.flush())
   if finished:published.extend(self.flush())
   return published
  except Exception:
   self.enabled=False;self.pending='';return []
 def flush(self):
  if not self.pending.strip():self.pending='';return []
  unit=str(uuid.uuid4());text=self.pending;self.pending=''
  digest=self.ledger.put_final(self.account,self.session,self.epoch,unit,1,[{'text':text,'is_final':True,'translation_status':'original'}])
  return [{'type':'source_unit','session':self.session,'epoch':self.epoch,'unit':unit,'revision':1,'source_sha256':digest}]
 def close(self):
  self.enabled=False;self.pending=''
  self.ledger.close_epoch(self.account,self.session,self.epoch)
