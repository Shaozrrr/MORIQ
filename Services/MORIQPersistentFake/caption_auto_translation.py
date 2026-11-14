"""Disabled-by-default confirmed-source translation experiment.

Only ledger-owned confirmed units can be submitted. This is not a production
publisher, alignment mechanism, or comprehensive translation verifier.
"""
import asyncio,re,time
from caption_memory_ledger import ident

class ControlledDeepLProvider:
    """Official HTTPS endpoint only; credentials remain in this process."""
    def __init__(self,key):
        if not isinstance(key,str) or not key or not key.isascii() or any(not 33<=ord(c)<=126 for c in key):raise ValueError('invalid credential')
        self._key=key
    async def translate_with_context(self,source,target,context,*,diagnostic=None):
        from deepl_experiment import DeepLExperiment
        from deepl_https_transport import DirectDeepLTransport
        return await DeepLExperiment(self._key,DirectDeepLTransport(diagnostic=diagnostic),timeout=3,context=context)(source,target)
    async def __call__(self,source,target):return await self.translate_with_context(source,target,'')

_NUM=re.compile(r'(?<![0-9.])\d+(?:\.\d+)?')
_ZH_DIGITS={'零':0,'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9}
_FRACTIONS=('五分之一','1/5','20%','20％')
_TEMPERATURE_REFERENTS=('温差','温度差','温度变化','升温幅度','变暖幅度','气温变化','温差幅度')

def fraction_referent_present(candidate):
    clauses=re.split(r'[，。；！？,;!?\n]',candidate)
    return any(any(x in clause for x in _FRACTIONS) and any(x in clause for x in _TEMPERATURE_REFERENTS) for clause in clauses)

def _century_numbers(text):
    values=set()
    for match in re.finditer(r'([一二三四五六七八九十]{1,3})世纪',text):
        word=match.group(1)
        if '十' in word:
            a,b=word.split('十',1);n=(_ZH_DIGITS.get(a,1) if a else 1)*10+(_ZH_DIGITS.get(b,0) if b else 0)
        else:n=_ZH_DIGITS.get(word)
        if n is not None:values.add(str(n))
    return values

def guard_rule(source,candidate,context=''):
    s=source.lower();c=candidate.lower()
    f=('fahrenheit' in s or '°f' in s)
    source_numbers=set(_NUM.findall(s));target_numbers=set(_NUM.findall(c))|_century_numbers(c)
    if f and ('摄氏' in c or '°c' in c):
        # Only explicit temperature differences are convertible here; never
        # apply a delta conversion to an absolute Fahrenheit temperature.
        if re.search(r'[-−]\s*\d',s+' '+c):return None
        fmatch=re.search(r'(\d+(?:\.\d+)?)\s*(?:degrees?\s*)?(?:fahrenheit|°f)',s)
        cmatch=re.search(r'(\d+(?:\.\d+)?)\s*(?:摄氏|°c)',c) or re.search(r'(?:摄氏|°c)\s*(\d+(?:\.\d+)?)',c)
        if not fmatch or not cmatch or len(re.findall(r'(\d+(?:\.\d+)?)\s*(?:degrees?\s*)?(?:fahrenheit|°f)',s))!=1:return None
        if float(fmatch.group(1))==float(cmatch.group(1)) and float(fmatch.group(1))>0:return 'unit_conversion_conflict'
        if not re.search(r'\b(warmed|colder|warmer|increase|decrease|rise|difference)\b',s):return None
        if abs(float(cmatch.group(1))-float(fmatch.group(1))*5/9)>0.06:return 'unit_conversion_conflict'
        source_numbers.discard(fmatch.group(1));target_numbers.discard(cmatch.group(1))
    elif f and ('华氏' in c or '°f' in c):
        fs=re.findall(r'(\d+(?:\.\d+)?)\s*(?:degrees?\s*)?(?:fahrenheit|°f)',s)
        cs=re.findall(r'(\d+(?:\.\d+)?)\s*(?:华氏|°f)',c) or re.findall(r'(?:华氏|°f)\s*(\d+(?:\.\d+)?)',c)
        if len(fs)==len(cs)==1 and float(fs[0])!=float(cs[0]):return 'quantity_conflict'
    fraction=bool(re.search(r'\b(a|one)\s+fifth\b',s))
    if fraction and not any(x in c for x in _FRACTIONS) and re.search(r'(?:五|5)\s*(?:摄氏|华氏)?度',c):return 'fraction_conflict'
    return None

def obvious_conflict(source,candidate):return guard_rule(source,candidate) is not None

class AutoTranslation:
    def __init__(self,ledger,provider,*,enabled=False,fake_only=False,max_pending=8,diagnostic=None,public_capture=None):
        if enabled is not True or fake_only is not True or not callable(provider) or not 1<=max_pending<=32:
            raise ValueError('experimental service disabled')
        from caption_memory_ledger import MemorySourceLedger
        if type(ledger) is not MemorySourceLedger:raise ValueError('volatile trusted ledger required')
        self.ledger=ledger;self.provider=provider;self.queue=asyncio.Queue(maxsize=max_pending);self.closed=False;self.diagnostic=diagnostic;self.public_capture=public_capture
        self.workers=[asyncio.create_task(self._work()) for _ in range(2)]

    async def submit(self,account,reference,*,context=''):
        if self.closed or not isinstance(context,str) or len(context)>512 or not isinstance(reference,dict) or set(reference)!={'session','epoch','unit','revision','target'} or not all(ident(reference[k]) for k in ('session','epoch','unit')) or type(reference['revision']) is not int or not 0<reference['revision']<=2**53-1 or reference['target'] not in ('en-US','zh-Hans'):
            return {'status':'unavailable'}
        future=asyncio.get_running_loop().create_future()
        try:self.queue.put_nowait((account,reference.copy(),context,future,time.monotonic()))
        except asyncio.QueueFull:
            if self.diagnostic:
                try:self.diagnostic({'unit':reference.get('unit'),'stage':'queue','outcome':'full','elapsed_ms':0})
                except Exception:pass
            return {'status':'unavailable'}
        return await future

    async def _work(self):
        while True:
            account,reference,context,future,enqueued=await self.queue.get()
            def report(stage,outcome,elapsed_ms,**extra):
                if self.diagnostic:
                    try:self.diagnostic({'unit':reference['unit'],'stage':stage,'outcome':outcome,'elapsed_ms':elapsed_ms,**extra})
                    except Exception:pass
            report('queue','started',round((time.monotonic()-enqueued)*1000))
            try:
                if future.cancelled():continue
                async def checked(source,target):
                    contextual=getattr(self.provider,'translate_with_context',None)
                    started=time.monotonic();outcome='error'
                    try:
                        from deepseek_translation import ControlledDeepSeekProvider
                        if type(self.provider) in (ControlledDeepLProvider,ControlledDeepSeekProvider):
                            candidate=await contextual(source,target,context,diagnostic=lambda d:report(d['stage'],d['outcome'],d['elapsed_ms'],status=d['status']))
                        else:candidate=await contextual(source,target,context) if callable(contextual) else await self.provider(source,target)
                        outcome='ok'
                    except asyncio.CancelledError:
                        outcome='cancelled_or_timeout';raise
                    except Exception as exc:
                        from deepl_experiment import DeepLExperimentError
                        category=str(exc) if isinstance(exc,DeepLExperimentError) else ''
                        outcome=category if category in ('auth','rate_limit','quota','http_error','invalid_response','timeout','tls','network') else 'error'
                        raise
                    finally:report('provider',outcome,round((time.monotonic()-started)*1000))
                    rule=guard_rule(source,candidate,context) if isinstance(candidate,str) else 'invalid_candidate'
                    if self.public_capture is not None:
                        try:self.public_capture(source,context,target,candidate,rule)
                        except Exception:pass
                    if rule:
                        report('guard','conflict',0,rule=rule);raise ValueError('candidate rejected')
                    report('guard','passed',0)
                    return candidate
                result=await self.ledger.review(account,reference,checked,context_cost=len(context))
                report('ledger','candidate' if result.get('status')=='candidate' else 'unavailable',0)
                if not future.done():future.set_result(result)
            except asyncio.CancelledError:
                if not future.done():future.set_result({'status':'unavailable'})
                raise
            except Exception:
                report('ledger','claim_or_lifecycle_error',0)
                if not future.done():future.set_result({'status':'unavailable'})
            finally:self.queue.task_done()

    async def close(self):
        self.closed=True
        for worker in self.workers:worker.cancel()
        await asyncio.gather(*self.workers,return_exceptions=True)
        while not self.queue.empty():
            _,_,_,future,_=self.queue.get_nowait()
            if not future.done():future.set_result({'status':'unavailable'})
            self.queue.task_done()
