"""Explicitly enabled loopback-only Soniox experiment; not a production service.

The provider key stays server-side. Audio and recognition text are never logged.
"""
import asyncio
import hashlib
import hmac
import ipaddress
import json
import math
import os
import time
import urllib.parse
from collections import deque
from websockets.asyncio.server import serve
from speech_gateway import NoRedirect, provider_tls_context
from deepgram_gateway import guarded_upstream
from asr_gateway import decode_audio_frame
from soniox_native_translation import NativeTranslationLanes

PROVIDER = 'wss://stt-rt.soniox.com/transcribe-websocket'
MAX_PAYLOAD = 131072


def provider_config(source, translation_target=None):
    if source not in ('auto','en','zh','ja','ko'): raise ValueError('unsupported source')
    config={'model':'stt-rt-v6','audio_format':'pcm_s16le','sample_rate':16000,
            'num_channels':1,'enable_endpoint_detection':True,'enable_language_identification':True}
    if source != 'auto':
        config.update(language_hints=[source], language_hints_strict=True)
    if translation_target is not None:
        if translation_target not in ('en','zh','ja','ko'): raise ValueError('unsupported target')
        config['translation']={'type':'one_way','target_language':translation_target}
    return config


class TokenSnapshots:
    """Per-connection final-token accumulator and replaceable non-final suffix.

    Soniox specifies finals once, not a token ID. Timestamp-based duplicate
    suppression is best effort; untimed identical consecutive final batches are
    ambiguous and fail closed instead of silently deleting repeated words.
    """
    def __init__(self, max_final_audio_ms=4000):
        if type(max_final_audio_ms) is not int or not 1000 <= max_final_audio_ms <= 10000: raise ValueError('invalid segment duration')
        self.max_final_audio_ms=max_final_audio_ms
        self.segment_start_ms=None; self.timing_complete=True
        self.segment=1; self.committed=''; self.previous=None
        self.seen=set(); self.seen_fifo=deque(); self.last_start=None
        self.last_untimed_batch=None; self.languages=set(); self.language_unknown=False
        self.committed_bytes=0
        self.delta_segment=1; self.delta_confirmed=''; self.delta_provisional=''; self.delta_revision=0

    def _remember(self, identity):
        self.seen.add(identity); self.seen_fifo.append(identity)
        if len(self.seen_fifo) > 50000: self.seen.remove(self.seen_fifo.popleft())

    def _final_event(self):
        if not self.committed: return []
        event={'type':'source','segment':self.segment,'text':self.committed,'final':True}
        if len(self.languages)==1 and not self.language_unknown: event['language_labels']=list(self.languages)
        self.segment += 1; self.committed=''; self.committed_bytes=0; self.previous=None; self.languages=set(); self.language_unknown=False
        self.segment_start_ms=None; self.timing_complete=True
        return [event]

    def accept(self, message):
        if not isinstance(message,dict): raise ValueError('invalid provider message')
        if message.get('error_code') is not None or message.get('error_type') is not None: raise ValueError('provider error')
        if 'finished' in message and type(message['finished']) is not bool: raise ValueError('invalid finish')
        tokens=message.get('tokens',[])
        if not isinstance(tokens,list) or len(tokens)>2000: raise ValueError('invalid tokens')
        if not tokens:
            if message.get('finished') is True: return self._final_event()
            return []
        out=[]; interim=[]; saw_nonfinal=False; untimed=[]; timed_seen_this_batch=set()
        for token in tokens:
            if not isinstance(token,dict): raise ValueError('invalid token')
            text,final=token.get('text'),token.get('is_final')
            if not isinstance(text,str) or len(text.encode())>16000 or type(final) is not bool: raise ValueError('invalid token')
            if text in ('<end>','<fin>'):
                if not final or interim: raise ValueError('invalid endpoint')
                out.extend(self._final_event()); saw_nonfinal=False; continue
            if not final:
                interim.append(text); saw_nonfinal=True; continue
            if saw_nonfinal: raise ValueError('final after provisional token')
            start,end=token.get('start_ms'),token.get('end_ms')
            timed = type(start) is int and type(end) is int and 0 <= start < end <= 2_147_483_647
            if timed:
                identity=(start,end,text)
                if identity in timed_seen_this_batch: raise ValueError('ambiguous repeated token')
                if identity in self.seen: continue
                if self.last_start is not None and start < self.last_start: raise ValueError('reordered final token')
                timed_seen_this_batch.add(identity); self._remember(identity); self.last_start=start
            else:
                if (start is not None or end is not None) and not (type(start) is int and type(end) is int and 0 <= start == end <= 2_147_483_647): raise ValueError('invalid timing')
                untimed.append(text)
            # Final tokens are immutable per the provider protocol. Bound a
            # long turn without waiting for <end>; provisional tokens never
            # enter these segments. Prefer sentence, then word boundaries,
            # with a hard Unicode-character boundary for unbroken text.
            if not self.committed:
                self.segment_start_ms=start if timed else None
            if not timed:
                self.timing_complete=False
            lang=token.get('language')
            valid_lang=isinstance(lang,str) and 0<len(lang)<=35 and lang.isascii() and all(c.isalnum() or c=='-' for c in lang)
            for i,char in enumerate(text):
                if i and not self.committed:
                    # A byte-limit cut inside a token has no trustworthy
                    # timestamp for the remaining sub-token characters.
                    self.timing_complete=False; self.segment_start_ms=None
                self.committed+=char
                self.committed_bytes+=len(char.encode('utf-8'))
                if not char.isspace():
                    if valid_lang: self.languages.add(lang)
                    else: self.language_unknown=True
                sentence=char in '.!?。！？；;'
                boundary=char.isspace() or char in ',，、:：'
                if ((sentence and self.committed_bytes>=120) or
                    (boundary and self.committed_bytes>=480) or
                    self.committed_bytes>=2048):
                    out.extend(self._final_event())
            # Token timestamps describe its complete audio interval, never a
            # sub-token split. Use only a fully timed current segment.
            if self.committed and timed and self.timing_complete and self.segment_start_ms is not None:
                elapsed=end-self.segment_start_ms
                last=text[-1:] or self.committed[-1:]
                cjk=bool(last) and ('\u3400' <= last <= '\u9fff' or '\u3040' <= last <= '\u30ff' or '\uac00' <= last <= '\ud7af')
                boundary=bool(last) and (last.isspace() or last in '.,!?;:，。！？；：、' or cjk)
                # A timed provider token is not necessarily a sentence: the
                # previous four-second word cut split names and changed the
                # meaning of the separately translated fragments. Prefer a
                # sentence boundary, keeping word boundaries only as a bounded
                # fallback for extended speech without punctuation. Provisional
                # text remains available while this final segment is pending.
                sentence_boundary=bool(last) and last in '.!?;。！？；'
                forced_elapsed=self.max_final_audio_ms+6000
                if ((elapsed >= self.max_final_audio_ms and sentence_boundary) or
                    (elapsed >= forced_elapsed and boundary) or elapsed >= forced_elapsed+2000):
                    out.extend(self._final_event())
        if untimed:
            batch=tuple(untimed)
            if batch == self.last_untimed_batch: raise ValueError('ambiguous repeated untimed finals')
            self.last_untimed_batch=batch
        else: self.last_untimed_batch=None
        snapshot=self.committed+''.join(interim)
        if len(snapshot.encode())>16000: raise ValueError('segment too long')
        if snapshot != self.previous and (snapshot or self.previous is not None):
            out.append({'type':'source','segment':self.segment,'text':snapshot,'final':False}); self.previous=snapshot
        if message.get('finished') is True:
            # Never promote an unconfirmed suffix into final history.
            out.extend(self._final_event())
        return out


    def accept_deltas(self, message):
        """Atomic final-token append plus replaceable provisional tail."""
        events=self.accept(message)
        result=[]
        def emit(segment, confirmed, provisional, final, language_labels=None):
            if segment != self.delta_segment or not confirmed.startswith(self.delta_confirmed):
                raise ValueError('inconsistent confirmed token state')
            if final and provisional: raise ValueError('provisional final')
            delta=confirmed[len(self.delta_confirmed):]
            if delta or provisional != self.delta_provisional or final:
                self.delta_revision += 1
                result.append({'type':'confirmed_delta','segment':segment,'revision':self.delta_revision,
                    'confirmed_utf8_offset':len(self.delta_confirmed.encode('utf-8')),
                    'confirmed_delta':delta,'provisional':provisional,'segment_final':final})
                if final and language_labels is not None: result[-1]['language_labels']=language_labels
                self.delta_confirmed=confirmed; self.delta_provisional=provisional
            if final:
                self.delta_segment+=1; self.delta_confirmed=''; self.delta_provisional=''
        for event in events:
            if event['final']:
                emit(event['segment'],event['text'],'',True,event.get('language_labels'))
        # Only the current segment can contain provisional words. Legacy
        # snapshots sometimes omit a provisional->confirmed transition when
        # display text is unchanged; independently inspect committed state.
        if self.segment == self.delta_segment and self.previous is not None:
            if not self.previous.startswith(self.committed): raise ValueError('invalid provisional state')
            # A finished stream cannot revise or confirm its remaining suffix.
            # Explicitly clear it rather than leaving a stale live preview.
            provisional='' if message.get('finished') is True else self.previous[len(self.committed):]
            emit(self.segment,self.committed,provisional,False)
            # Preserve a real upstream re-observation, even if its text is
            # identical. The consumer needs two upstream observations to
            # establish stability; a timer alone cannot supply evidence. Do
            # not synthesize observations for keepalives or finished events.
            observed = any(isinstance(token, dict) and token.get('is_final') is False and isinstance(token.get('text'), str) and token['text'] for token in message.get('tokens', []))
            if not result and observed and provisional and message.get('finished') is not True:
                self.delta_revision += 1
                result.append({'type':'confirmed_delta','segment':self.delta_segment,'revision':self.delta_revision,
                    'confirmed_utf8_offset':len(self.delta_confirmed.encode('utf-8')),
                    'confirmed_delta':'','provisional':provisional,'segment_final':False})
        return result


class SonioxGateway:
    def __init__(self,key,*,account_store,upstream=PROVIDER,testing=False,first_audio_timeout=8,idle_timeout=12,clock=time.monotonic,source_ledger=None,enable_trusted_source=False,auto_provider=None,auto_diagnostic=None,public_capture=None,auto_skip_units=0,auto_max_units=None):
        parsed=urllib.parse.urlsplit(upstream)
        try: local=ipaddress.ip_address(parsed.hostname or '').is_loopback
        except ValueError: local=False
        if upstream != PROVIDER and not (testing and parsed.scheme=='ws' and local and parsed.path=='/transcribe-websocket' and not parsed.query and not parsed.fragment and parsed.username is None): raise ValueError('invalid upstream')
        if not isinstance(key,str) or not key or not key.isascii() or any(not 33<=ord(c)<=126 for c in key): raise ValueError('invalid provider credential')
        if account_store is None: raise ValueError('account store required')
        if not testing and (first_audio_timeout != 8 or idle_timeout != 12 or clock is not time.monotonic): raise ValueError('fixed timing policy')
        if not 0<first_audio_timeout<=8 or not 0<idle_timeout<=12: raise ValueError('invalid timeouts')
        if type(enable_trusted_source) is not bool: raise ValueError('invalid source configuration')
        if enable_trusted_source:
            from caption_memory_ledger import MemorySourceLedger
            if type(source_ledger) is not MemorySourceLedger or source_ledger.accounts is not account_store:
                raise ValueError('trusted source requires the matching memory ledger')
        elif source_ledger is not None and not testing:
            raise ValueError('source ledger is disabled')
        self.source_ledger=source_ledger
        self.trusted_source=enable_trusted_source
        if auto_provider is not None:
            from caption_auto_translation import ControlledDeepLProvider
            from deepseek_translation import ControlledDeepSeekProvider
            if not enable_trusted_source or not callable(auto_provider) or (not testing and type(auto_provider) not in (ControlledDeepLProvider,ControlledDeepSeekProvider)):
                raise ValueError('automatic translation provider is not permitted')
        self.auto_provider=auto_provider
        if auto_diagnostic is not None and (not testing or not callable(auto_diagnostic)):raise ValueError('diagnostics are local-test only')
        self.auto_diagnostic=auto_diagnostic
        if public_capture is not None and (not testing or not callable(public_capture)):raise ValueError('public capture is local-test only')
        self.public_capture=public_capture
        if type(auto_skip_units) is not int or not 0<=auto_skip_units<=1 or (auto_skip_units and not testing):raise ValueError('invalid test skip')
        self.auto_skip_units=auto_skip_units
        if auto_max_units is not None and (not testing or type(auto_max_units) is not int or not 1<=auto_max_units<=4):raise ValueError('invalid fixture budget')
        self.auto_max_units=auto_max_units
        self.key,self.accounts,self.upstream,self.clock=key,account_store,upstream,clock
        self.first_audio_timeout,self.idle_timeout=first_audio_timeout,idle_timeout
        self.slots=asyncio.Semaphore(2)
        # Railway staging is intentionally a single process protected by a
        # volume lock. A single account may not occupy both upstream slots.
        # This is not a distributed limit across separate deployments.
        self.active_accounts=set()

    async def handle(self,client):
        async with self.slots:
            collector=None;automatic=None;pending_auto=set();active_account=None
            try:
                auth=client.request.headers.get('Authorization',''); token=auth[7:] if auth.startswith('Bearer ') else ''
                if client.request.path!='/v1/speech/stream' or not 32<=len(token)<=256 or not token.isascii() or not all(33<=ord(c)<=126 for c in token):
                    await client.send(json.dumps({'type':'error','code':'session_expired','message':'试用会话无效或已结束。'},ensure_ascii=False))
                    await client.close(1008,'unauthorized'); return
                digest=hashlib.sha256(token.encode()).hexdigest()
                account=await asyncio.to_thread(self.accounts.authenticate,digest)
                if account is None:
                    await client.send(json.dumps({'type':'error','code':'session_expired','message':'试用会话无效或已结束。'},ensure_ascii=False))
                    await client.close(1008,'unauthorized'); return
                # No await between checking and insertion: both happen on the
                # serving event loop and therefore form one admission decision.
                if account.account in self.active_accounts:
                    await client.send(json.dumps({'type':'error','message':'该账户已有字幕会话，请先关闭后重试。'},ensure_ascii=False))
                    await client.close(1013,'account busy'); return
                self.active_accounts.add(account.account);active_account=account.account
                raw=await asyncio.wait_for(client.recv(),5)
                config=json.loads(raw) if isinstance(raw,str) and len(raw)<=512 else None
                required={'type','source','target'}
                if (not isinstance(config,dict) or not required <= set(config) or
                    not set(config) <= required|{'protocol','confirmed_delta_v1','native_translation_v1','native_batch_v1','source_units_v1','source_units_v2','source_units_atomic_v1','auto_translation_v1'} or
                    config['type']!='start' or config['target'] not in ('en','zh','ja','ko') or
                    ('confirmed_delta_v1' in config and config['confirmed_delta_v1'] is not True) or
                    ('native_translation_v1' in config and config['native_translation_v1'] is not True) or
                    ('native_batch_v1' in config and (config['native_batch_v1'] is not True or config.get('native_translation_v1') is not True)) or
                    ('source_units_v1' in config and (config['source_units_v1'] is not True or config.get('native_translation_v1') is not True or self.source_ledger is None)) or
                    ('source_units_v2' in config and (config['source_units_v2'] is not True or config.get('native_translation_v1') is not True or config.get('native_batch_v1') is not True or self.source_ledger is None or 'source_units_v1' in config)) or
                    ('source_units_atomic_v1' in config and (config['source_units_atomic_v1'] is not True or config.get('source_units_v2') is not True)) or
                    ('auto_translation_v1' in config and (config['auto_translation_v1'] is not True or config.get('source_units_atomic_v1') is not True or self.auto_provider is None or config['target'] not in ('en','zh'))) or
                    (self.trusted_source and ('source_units_v1' in config or ('source_units_v2' in config and config.get('source_units_atomic_v1') is not True))) or
                    (config.get('confirmed_delta_v1') and config.get('native_translation_v1'))):
                    await client.close(1008,'invalid configuration'); return
                delta_mode=config.get('confirmed_delta_v1',False)
                native_mode=config.get('native_translation_v1',False)
                native_batch=config.get('native_batch_v1',False)
                source_units=config.get('source_units_v1',False)
                source_units_v2=config.get('source_units_v2',False)
                atomic_units=config.get('source_units_atomic_v1',False)
                auto_enabled=config.get('auto_translation_v1',False)
                if auto_enabled:
                    from caption_auto_translation import AutoTranslation
                    automatic=AutoTranslation(self.source_ledger,self.auto_provider,enabled=True,fake_only=True,diagnostic=self.auto_diagnostic,public_capture=self.public_capture)
                if source_units or source_units_v2:
                    if source_units_v2:
                        from caption_source_collector_v2 import SourceUnitCollectorV2
                        collector=SourceUnitCollectorV2(self.source_ledger,account,with_context=auto_enabled)
                    else:
                        from caption_source_collector import SourceUnitCollector
                        collector=SourceUnitCollector(self.source_ledger,account)
                version=config.get('protocol',1)
                if type(version) is not int or version not in (1,2): await client.close(1008,'unsupported protocol'); return
                if config['source'] not in ('auto','en','zh','ja','ko'):
                    await client.send(json.dumps({'type':'error','code':'unsupported_source_language'})); await client.close(1008,'unsupported source language'); return
                if not await asyncio.to_thread(self.accounts.consume,account):
                    if await asyncio.to_thread(self.accounts.authenticate,digest)!=account:raise PermissionError('session ended')
                    raise PermissionError('request quota unavailable')
                if not await asyncio.to_thread(self.accounts.consume_speech,account,1):
                    if await asyncio.to_thread(self.accounts.authenticate,digest)!=account:raise PermissionError('session ended')
                    raise PermissionError('speech quota unavailable')
                tls=provider_tls_context() if self.upstream.startswith('wss://') else None
                connector=NoRedirect(self.upstream,additional_headers={'Authorization':'Bearer '+self.key},proxy=None,ssl=tls,max_size=MAX_PAYLOAD,open_timeout=10,close_timeout=2,compression=None)
                async with guarded_upstream(connector,client,self.accounts,digest,account) as upstream:
                    # Meter starts before provider configuration, so stalled or
                    # idle streams cannot spend unreserved wall-clock time.
                    started=self.clock(); reserved=1; budget_lock=asyncio.Lock()
                    async def reserve(required):
                        nonlocal reserved
                        async with budget_lock:
                            while required>reserved:
                                add=min(2,required-reserved)
                                if not await asyncio.to_thread(self.accounts.consume_speech,account,add):
                                    if await asyncio.to_thread(self.accounts.authenticate,digest)!=account:raise PermissionError('session ended')
                                    raise PermissionError('speech quota unavailable')
                                reserved+=add
                    async def meter():
                        while True:
                            await asyncio.sleep(.25)
                            elapsed=max(0,self.clock()-started)
                            if elapsed>=1800: raise TimeoutError('session limit')
                            await reserve(max(1,math.floor(elapsed)+1))
                    budget_task=asyncio.create_task(meter())
                    tasks=set()
                    try:
                        await asyncio.wait_for(upstream.send(json.dumps(provider_config(config['source'], config['target'] if native_mode else None))),5)
                        if budget_task.done(): budget_task.result()
                        ready={'type':'ready','mode':'translation' if native_mode else 'transcription','supports_keepalive':True}
                        if version==2: ready['protocol']=2
                        if delta_mode: ready['confirmed_delta_v1']=True
                        if native_mode: ready['native_translation_v1']=True
                        if native_batch: ready['native_batch_v1']=True
                        if source_units: ready['source_units_v1']=True
                        if source_units_v2:
                            ready['source_units_v2']=True;ready['original_stream_id']=collector.original_stream_id
                            ready['session']=collector.session;ready['epoch']=collector.epoch
                        if atomic_units: ready['source_units_atomic_v1']=True
                        if auto_enabled: ready['auto_translation_v1']=True
                        await client.send(json.dumps(ready))
                        async def upload():
                            total=next_sample=0
                            while True:
                                msg=await asyncio.wait_for(client.recv(),self.idle_timeout if total else self.first_audio_timeout)
                                if isinstance(msg,bytes):
                                    pcm,next_sample=decode_audio_frame(msg,version,next_sample)
                                    total+=len(pcm)
                                    if total>32000*60*30: raise ValueError('session limit')
                                    await reserve((total+31999)//32000)
                                    await upstream.send(pcm)
                                elif msg=='{"type":"keepalive"}' and total:
                                    await upstream.send('{"type":"keepalive"}')
                                elif msg=='{"type":"finish"}':
                                    await upstream.send(''); return
                                else: raise ValueError('invalid client message')
                        async def download():
                            snapshots=NativeTranslationLanes() if native_mode else TokenSnapshots()
                            batch_seq=0;auto_seen=0;auto_attempts=0;previous_auto=None;auto_order=0
                            async def auto_emit(unit,context,previous,force_error=False):
                                target={'zh':'zh-Hans','en':'en-US'}[config['target']]
                                fields={k:unit[k] for k in ('session','epoch','original_stream_id','unit','revision','source_sha256')}
                                fields['target']=target
                                ref={k:fields[k] for k in ('session','epoch','unit','revision','target')}
                                result={'status':'unavailable'} if force_error else await automatic.submit(account,ref,context=context)
                                wait_start=time.monotonic()
                                if previous is not None:
                                    try:await asyncio.shield(previous)
                                    except Exception:pass
                                if self.auto_diagnostic:
                                    try:self.auto_diagnostic({'unit':unit['unit'],'stage':'publish_wait','outcome':'released','elapsed_ms':round((time.monotonic()-wait_start)*1000)})
                                    except Exception:pass
                                valid=(result.get('status')=='candidate' and result.get('source_sha256')==fields['source_sha256'] and
                                       await asyncio.to_thread(self.source_ledger.is_live,account,ref))
                                if valid: event={'type':'auto_translation_v1',**fields,'text':result['candidate']}
                                else: event={'type':'auto_translation_error_v1',**fields,'code':'unavailable'}
                                await client.send(json.dumps(event,ensure_ascii=False))
                            async def emit_atomic(events,finished=False,due=False):
                                nonlocal batch_seq,auto_seen,auto_attempts,previous_auto,auto_order
                                batch_seq+=1
                                batch={'type':'lane_batch','events':events,'batch_seq':batch_seq}
                                units=collector.flush_due(batch_seq) if due else collector.accept(events,batch_seq,finished=finished)
                                if collector.enabled:batch['source_units']=units
                                else:
                                    try:collector.close()
                                    except Exception:pass
                                    batch['source_units_unavailable']=True
                                payload=json.dumps(batch,ensure_ascii=False)
                                if len(payload.encode('utf-8'))>32768:
                                    try:collector.close()
                                    except Exception:pass
                                    batch.pop('source_units',None);batch['source_units_unavailable']=True
                                    payload=json.dumps(batch,ensure_ascii=False)
                                if len(payload.encode('utf-8'))>32768:raise ValueError('native batch too large')
                                await client.send(payload)
                                if auto_enabled and collector.enabled and 'source_units' in batch:
                                    for unit in units:
                                        context=collector.contexts.pop(unit['unit'],'')
                                        force_error=auto_seen<self.auto_skip_units or (self.auto_max_units is not None and auto_attempts>=self.auto_max_units)
                                        auto_seen+=1
                                        if not force_error:auto_attempts+=1
                                        if len(pending_auto)>=8 and previous_auto is not None:await previous_auto
                                        task=asyncio.create_task(auto_emit(unit,context,previous_auto,force_error));task.source_unit=unit;task.order=auto_order;auto_order+=1
                                        pending_auto.add(task);task.add_done_callback(pending_auto.discard);previous_auto=task
                            while True:
                                if auto_enabled and collector.deadline is not None:
                                    timeout=max(0,collector.deadline-time.monotonic())
                                    try:raw=await asyncio.wait_for(upstream.recv(),timeout)
                                    except asyncio.TimeoutError:
                                        await emit_atomic([],due=True);continue
                                else:raw=await upstream.recv()
                                if not isinstance(raw,str) or len(raw.encode())>MAX_PAYLOAD: raise ValueError('invalid response')
                                msg=json.loads(raw)
                                events=snapshots.accept_deltas(msg) if delta_mode else snapshots.accept(msg)
                                if atomic_units:
                                    # A finished packet can flush confirmed source without
                                    # native events; give that unit its own ordered batch.
                                    pending_finish=msg.get('finished') is True and bool(collector.pending.strip())
                                    if events or pending_finish:
                                        await emit_atomic(events,finished=msg.get('finished') is True)
                                else:
                                    if native_batch and events:
                                        batch={'type':'lane_batch','events':events}
                                        if source_units_v2:
                                            batch_seq+=1;batch['batch_seq']=batch_seq
                                        payload=json.dumps(batch,ensure_ascii=False)
                                        if len(payload.encode('utf-8'))>32768: raise ValueError('native batch too large')
                                        await client.send(payload)
                                    else:
                                        for event in events: await client.send(json.dumps(event,ensure_ascii=False))
                                    if collector is not None:
                                        units=(collector.accept(events,batch_seq,finished=msg.get('finished') is True) if source_units_v2 else collector.accept(events,finished=msg.get('finished') is True))
                                        for unit in units:
                                            await client.send(json.dumps(unit))
                                if msg.get('finished') is True:
                                    if pending_auto:
                                        _,late=await asyncio.wait(pending_auto,timeout=7)
                                        for task in late:task.cancel()
                                        if late:await asyncio.gather(*late,return_exceptions=True)
                                        for task in sorted(late,key=lambda t:t.order):
                                            fields={k:task.source_unit[k] for k in ('session','epoch','original_stream_id','unit','revision','source_sha256')}
                                            fields.update(type='auto_translation_error_v1',target={'zh':'zh-Hans','en':'en-US'}[config['target']],code='unavailable')
                                            await client.send(json.dumps(fields))
                                    await client.send(json.dumps({'type':'finished'})); return
                        async def monitor():
                            while True:
                                await asyncio.sleep(1)
                                if await asyncio.to_thread(self.accounts.authenticate,digest)!=account: raise PermissionError('session ended')
                        sender,receiver,watcher=asyncio.create_task(upload()),asyncio.create_task(download()),asyncio.create_task(monitor())
                        tasks={sender,receiver,watcher,budget_task}
                        done,_=await asyncio.wait(tasks,timeout=1800,return_when=asyncio.FIRST_COMPLETED)
                        if not done: raise TimeoutError('session limit')
                        for task in done: task.result()
                        if sender in done and receiver not in done:
                            done,_=await asyncio.wait({receiver,watcher,budget_task},timeout=15,return_when=asyncio.FIRST_COMPLETED)
                            if not done: raise TimeoutError('provider did not finish')
                            for task in done: task.result()
                    finally:
                        for task in tasks|{budget_task}: task.cancel()
                        await asyncio.gather(*(tasks|{budget_task}),return_exceptions=True)
            except Exception as error:
                quota=isinstance(error,PermissionError) and str(error) in ('request quota unavailable','speech quota unavailable')
                expired=isinstance(error,PermissionError) and str(error)=='session ended'
                payload={'type':'error','message':'额度或请求频率已达上限' if quota else ('试用会话无效或已结束。' if expired else '语音服务暂不可用')}
                if quota:payload['code']='quota_exhausted'
                if expired:payload['code']='session_expired'
                try: await client.send(json.dumps(payload,ensure_ascii=False)); await client.close(1011,'speech unavailable')
                except Exception: pass
            finally:
                try:
                    for task in pending_auto:task.cancel()
                    if pending_auto:await asyncio.gather(*pending_auto,return_exceptions=True)
                    if automatic is not None:await automatic.close()
                    if collector is not None:
                        try: collector.close()
                        except Exception: pass
                finally:
                    if active_account is not None:self.active_accounts.discard(active_account)


def build_local_gateway(env):
    if env.get('MORIQ_SONIOX_EXPERIMENTAL')!='1': raise ValueError('explicit experimental opt-in required')
    db=env.get('MORIQ_ACCOUNT_DB')
    if not db or env.get('MORIQ_SPEECH_TOKEN_HASHES'): raise ValueError('account database required')
    from account_store import AccountStore
    opt=env.get('MORIQ_SONIOX_TRUSTED_SOURCE_EXPERIMENTAL','0')
    if opt not in ('0','1'): raise ValueError('invalid source opt-in')
    auto=env.get('MORIQ_AUTO_DEEPL_EXPERIMENTAL','0')
    ds=env.get('MORIQ_AUTO_DEEPSEEK_EXPERIMENTAL','0')
    if auto not in ('0','1') or ds not in ('0','1') or (auto=='1' and ds=='1') or ((auto=='1' or ds=='1') and opt!='1'):raise ValueError('invalid automatic translation opt-in')
    accounts=AccountStore(db)
    ledger=None
    if opt=='1':
        from caption_memory_ledger import MemorySourceLedger
        ledger=MemorySourceLedger(accounts,fake_only=True)
    try:
        provider=None
        if auto=='1':
            from caption_auto_translation import ControlledDeepLProvider
            provider=ControlledDeepLProvider(env.get('MORIQ_DEEPL_PROVIDER_KEY',''))
        if ds=='1':
            from deepseek_translation import ControlledDeepSeekProvider
            provider=ControlledDeepSeekProvider(env.get('MORIQ_DEEPSEEK_PROVIDER_KEY',''))
        return SonioxGateway(env.get('MORIQ_SPEECH_PROVIDER_KEY',''),account_store=accounts,source_ledger=ledger,enable_trusted_source=opt=='1',auto_provider=provider)
    except BaseException:
        if ledger: ledger.shutdown()
        raise

async def run_local():
    gateway=build_local_gateway(os.environ)
    try:
        async with serve(gateway.handle,'127.0.0.1',int(os.environ.get('MORIQ_SPEECH_PORT','8777')),max_size=8192,compression=None): await asyncio.Future()
    finally:
        if gateway.source_ledger: gateway.source_ledger.shutdown()

if __name__=='__main__': asyncio.run(run_local())
