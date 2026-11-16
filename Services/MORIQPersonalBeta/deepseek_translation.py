"""Opt-in server-side text translation, fixed official endpoint and no retries."""
import asyncio,http.client,json,ssl,sys,threading,time
from deepl_experiment import DeepLExperimentError
_SLOTS=threading.BoundedSemaphore(2)

def _verified_tls_context():
 # Some python.org macOS builds ship without configured default CA paths.
 # Use the macOS system CA bundle explicitly; never weaken verification or
 # silently fall back to an unverified connection. Linux retains its defaults.
 try:
  context = ssl.create_default_context(cafile='/etc/ssl/cert.pem') if sys.platform == 'darwin' else ssl.create_default_context()
 except OSError:
  raise ssl.SSLError('trust bundle unavailable') from None
 if context.verify_mode != ssl.CERT_REQUIRED or not context.check_hostname: raise ssl.SSLError('verification unavailable')
 return context

class ControlledDeepSeekProvider:
 def __init__(self,key,*,metrics=None):
  if not isinstance(key,str) or not key or not key.isascii() or any(not 33<=ord(c)<=126 for c in key):raise ValueError('invalid credential')
  self._key=key;self._metrics=metrics
 async def __call__(self,source,target):return await self.translate_with_context(source,target,'')
 async def translate_with_context(self,source,target,context,*,diagnostic=None):
  if not isinstance(source,str) or not source.strip() or len(source)>4000 or not isinstance(context,str) or len(context)>512 or target not in ('zh-Hans','en-US'):raise DeepLExperimentError('invalid_response')
  language={'zh-Hans':'简体中文','en-US':'英文'}[target]
  body=json.dumps({'model':'deepseek-flash','thinking':{'type':'disabled'},'stream':False,'max_tokens':500,
   'messages':[{'role':'system','content':f'准确翻译为{language}，保留数字、单位和上下文关系，只输出译文。'},
               {'role':'user','content':('前文：'+context+'\n' if context else '')+'待翻译：'+source}]},ensure_ascii=False).encode()
  cancelled=threading.Event()
  def send():
   with _SLOTS:
    if cancelled.is_set():raise TimeoutError()
    event=self._metrics.start(kind='translation',provider='deepseek',model='deepseek-flash') if self._metrics is not None else None
    conn=None;started=time.monotonic();status=None;outcome='error'
    try:
     tls=_verified_tls_context()
     conn=http.client.HTTPSConnection('api.deepseek.com',timeout=3,context=tls)
     if cancelled.is_set():raise TimeoutError()
     if event is not None:event.mark_dispatch()
     conn.request('POST','/chat/completions',body=body,headers={'Authorization':'Bearer '+self._key,'Content-Type':'application/json'})
     response=conn.getresponse();status=response.status
     if event is not None:event.mark_provider_response()
     if status!=200:outcome='http_error';raise DeepLExperimentError({401:'auth',402:'quota',429:'rate_limit'}.get(status,'http_error'))
     raw=response.read(32769)
     if len(raw)>32768:raise DeepLExperimentError('invalid_response')
     data=json.loads(raw)
     if event is not None:event.observe_usage(data.get('usage'),final=True)
     choice=data['choices'][0]
     if choice.get('finish_reason')!='stop':raise DeepLExperimentError('invalid_response')
     text=choice['message']['content']
     if not isinstance(text,str) or not text.strip() or len(text)>4000:raise DeepLExperimentError('invalid_response')
     outcome='ok';return text
    finally:
     if conn is not None:conn.close()
     if event is not None:
      try:event.finish('cancelled' if cancelled.is_set() else ('success' if outcome=='ok' else 'failure'),retries=0)
      except Exception:self._metrics.poison() # preserve unknown and refuse new calls
     if diagnostic:
      try:diagnostic({'stage':'http','outcome':outcome,'status':status if type(status) is int and 100<=status<=599 else None,'elapsed_ms':round((time.monotonic()-started)*1000)})
      except Exception:pass
  try:return await asyncio.to_thread(send)
  except asyncio.CancelledError:cancelled.set();raise
  except DeepLExperimentError:raise
  except (TimeoutError,ssl.SSLError,ConnectionError,OSError) as exc:
   raise DeepLExperimentError('timeout' if isinstance(exc,TimeoutError) else 'tls' if isinstance(exc,ssl.SSLError) else 'network') from None
  except Exception:raise DeepLExperimentError('invalid_response') from None
