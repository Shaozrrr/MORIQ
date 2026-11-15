"""Isolated opt-in experiment; never import in production."""
import re,uuid
from caption_punct_base import SourceUnitCollectorV2

_ABBREV=re.compile(r'(?:\b(?:mr|mrs|ms|dr|prof|st|vs|etc|jr|sr|e\.g|i\.e|u\.s|a\.m|p\.m)|(?:\b[A-Za-z]))\.$',re.I)
def _ascii_word(c):return c.isascii() and c.isalnum()
def _sentence_cut(text):
 for i,c in enumerate(text[:-2]):
  if c not in '.!?' or text[i+1]!=' ' or not _ascii_word(text[i+2]):continue
  if c=='.' and (i>0 and text[i-1]=='.' or _ABBREV.search(text[max(0,i-30):i+1])):continue
  if i>0 and text[i-1].isdigit() and c=='.':continue
  if text[:i+2].strip():return i+2
 return None

class SentenceCollector(SourceUnitCollectorV2):
 def __init__(self,ledger,account,*,with_context=False,experimental_sentence_v1=False,experimental_context_120=False):
  super().__init__(ledger,account,with_context=with_context)
  if type(experimental_sentence_v1) is not bool:raise ValueError('invalid opt-in')
  if type(experimental_context_120) is not bool:raise ValueError('invalid context opt-in')
  self.experimental_sentence_v1=experimental_sentence_v1;self.experimental_context_120=experimental_context_120;self.completed_context=[];self.context_partial='';self.context_truncated=False;self.markers=[];self.failure_reason=None
 def _emit_prefix(self,count,reason):
  text=self.pending[:count]
  if not text.strip():raise ValueError('whitespace-only unit cannot be represented')
  start=self.start_byte;end=start+len(text.encode('utf-8'))
  unit=str(uuid.uuid4())
  if self.with_context:
   if len(self.contexts)>=1000:raise ValueError('context capacity')
   if self.experimental_context_120:
    self.contexts[unit]=''.join(self.completed_context)
    self.context_partial+=text
    if len(self.context_partial)>1024:self.context_partial='';self.context_truncated=True
    tail=text.rstrip()
    complete=bool(tail) and tail[-1] in '.!?' and not (tail[-1]=='.' and (tail.endswith('..') or _ABBREV.search(tail)))
    if complete:
     if not self.context_truncated and len(self.context_partial)<=120:self.completed_context.append(self.context_partial)
     self.context_partial='';self.context_truncated=False
     while sum(map(len,self.completed_context))>120:self.completed_context.pop(0)
   else:self.contexts[unit]=self.history[-512:];self.history=(self.history+text)[-512:]
  digest=self.ledger.put_final(self.account,self.session,self.epoch,unit,1,[{'text':text,'is_final':True,'translation_status':'original'}])
  self.pending=self.pending[count:];self.start_byte=end
  self.markers=[m-count for m in self.markers if m>count]
  return {'type':'source_unit_v2','session':self.session,'epoch':self.epoch,'unit':unit,'revision':1,'original_stream_id':self.original_stream_id,'start_byte':start,'end_byte':end,'source_sha256':digest,'boundary_reason':reason}
 def _drain(self):
  result=[]
  while self.pending:
   cut=_sentence_cut(self.pending)
   if cut is None:break
   result.append(self._emit_prefix(cut,'sentence_v1'))
  return result
 def accept(self,events,batch_seq,finished=False):
  if not self.experimental_sentence_v1:return super().accept(events,batch_seq,finished=finished)
  if not self.enabled:return []
  if type(batch_seq) is not int or batch_seq<=0:self.enabled=False;return []
  result=[]
  try:
   for event in events:
    if event.get('type')=='lane_delta' and event.get('lane')=='original':
     delta=event['confirmed_delta']
     if not isinstance(delta,str) or type(event.get('confirmed_utf8_offset')) is not int or event['confirmed_utf8_offset']!=self.confirmed_bytes:raise ValueError('non-contiguous')
     self.pending+=delta;self.confirmed_bytes+=len(delta.encode())
     if len(self.pending)>4000:raise ValueError('bounded pending exceeded')
     result+=self._drain()
    elif event.get('type')=='stream_marker':
     if self.pending.strip():result.append(self._emit_prefix(len(self.pending),'endpoint'))
   if finished:
    result+=self._drain()
    if self.pending:
     if not self.pending.strip():raise ValueError('whitespace-only final cannot be represented')
     result.append(self._emit_prefix(len(self.pending),'finish'))
   for v in result:v.update(batch_seq=batch_seq,confirmed_through_byte=self.confirmed_bytes)
   return result
  except Exception as exc:
   self.failure_reason='capacity' if isinstance(exc,ValueError) and str(exc) in ('capacity','unit history capacity','session capacity') else 'unavailable'
   self.enabled=False;self.pending='';self.markers=[];return []
 def close(self):
  self.completed_context.clear();self.context_partial='';self.context_truncated=False
  return super().close()
 def flush_due(self,batch_seq):
  if not self.experimental_sentence_v1:return super().flush_due(batch_seq)
  return [] # no provisional or elapsed-time fallback
