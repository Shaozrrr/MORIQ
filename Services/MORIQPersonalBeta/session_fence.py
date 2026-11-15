"""Per-connection admission fence. Previously admitted calls may incur fees."""
import threading
class SessionFence:
 def __init__(self,account,session,epoch):
  self.account=account;self.session=session;self.epoch=epoch;self._lock=threading.RLock();self._open=True
 def claim(self,ledger,account,request,context_cost):
  with self._lock:
   if not self._open or account!=self.account or request['session']!=self.session or request['epoch']!=self.epoch:raise PermissionError('session closed')
   return ledger._claim(account,*(request[k] for k in ('session','epoch','unit','revision','target')),context_cost)
 def valid(self,account,request):
  with self._lock:return self._open and account==self.account and request['session']==self.session and request['epoch']==self.epoch
 def close(self):
  with self._lock:self._open=False
