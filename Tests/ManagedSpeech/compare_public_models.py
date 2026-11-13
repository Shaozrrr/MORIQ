import sys,subprocess,asyncio,time,wave,json,uuid,re,struct,argparse,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/ManagedAI'))
from speech_gateway import PROVIDER,request,parse,provider_tls_context,NoRedirect
p=argparse.ArgumentParser(description='Opt-in public audio cloud benchmark; may incur usage charges.')
p.add_argument('--run',action='store_true'); p.add_argument('--wav',type=Path,required=True); p.add_argument('--refs-a',type=Path,required=True); p.add_argument('--refs-b',type=Path,required=True)
args=p.parse_args()
if not args.run: p.error('pass --run to send the specified public test audio to the online service')
if hashlib.sha256(args.wav.read_bytes()).hexdigest()!='073d16da4f077f47c623f4786e2c7a3ae7d736088d2c3e01c18b1594eea36916': p.error('wrong public benchmark WAV hash')
def norm(s): return re.findall(r"[a-z]+(?:'[a-z]+)?",s.lower().replace('mr.', 'mister'))
def dist(a,b):
 prev=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  row=[i]
  for j,y in enumerate(b,1): row.append(min(row[-1]+1,prev[j]+1,prev[j-1]+(x!=y)))
  prev=row
 return prev[-1]
async def go():
 with wave.open(str(args.wav)) as w:
  assert (w.getnchannels(),w.getsampwidth(),w.getframerate())==(1,2,16000)
  pcm=w.readframes(round(19.205*16000))
 a=json.load(args.refs_a.open()); b=json.load(args.refs_b.open())
 assert b[0]['speaker_id']==8455
 reference=norm(' '.join([a[0]['reference'],b[0]['text'],a[1]['reference']]))
 helper=ROOT/'Vendor/SpeechEngine/moriq-speech'; model=ROOT/'Vendor/SpeechEngine/ggml-base.bin'
 proc=await asyncio.create_subprocess_exec(str(helper),str(model),'en',stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL)
 started=time.monotonic(); local_final=[]; first_local=None; local_counts={'partial':0,'final':0}
 async def local_read():
  nonlocal first_local
  while line:=await proc.stdout.readline():
   v=line.decode('utf8','replace').strip(); typ=v[:1]; text=v[2:] if len(v)>2 else ''
   if typ in ('P','F') and text:
    if first_local is None: first_local=round(time.monotonic()-started,3)
    local_counts['partial' if typ=='P' else 'final']+=1
    if typ=='F':local_final.append(text)
 t=asyncio.create_task(local_read())
 for off in range(0,len(pcm),2560):
  part=pcm[off:off+2560]; samples=struct.unpack('<%dh'%(len(part)//2),part)
  proc.stdin.write(struct.pack('<%df'%len(samples),*(x/32768 for x in samples))); await proc.stdin.drain(); await asyncio.sleep(.08)
 proc.stdin.close(); await proc.wait(); await t
 if proc.returncode!=0: raise RuntimeError('local failed')
 local_hyp=norm(' '.join(local_final)); local_errors=dist(reference,local_hyp)
 credential=subprocess.run(['/usr/bin/security','find-generic-password','-s','local.moriq.volcengine.speech','-a','MORIQ','-w'],capture_output=True)
 if credential.returncode: raise RuntimeError('credential unavailable')
 key=credential.stdout.decode().strip();del credential
 session=str(uuid.uuid4());cloud_finals=[];first={};counts={'source_partial':0,'source_final':0,'translation_partial':0,'translation_final':0,'speaker_change':0};delay=[]
 async with NoRedirect(PROVIDER,additional_headers={'X-Api-Key':key,'X-Api-Resource-Id':'volc.service_type.10053'},ssl=provider_tls_context(),proxy=None,open_timeout=20) as ws:
  del key
  await ws.send(request(100,session,source='en',target='zh')); assert parse(await asyncio.wait_for(ws.recv(),20)).get(2)==150
  start=time.monotonic()
  async def send():
   for off in range(0,len(pcm),2560):await ws.send(request(200,session,pcm=pcm[off:off+2560])); await asyncio.sleep(.08)
   await ws.send(request(102,session))
  task=asyncio.create_task(send())
  while True:
   e=parse(await asyncio.wait_for(ws.recv(),45)); event=e.get(2); now=time.monotonic()-start
   if event==650 and e.get(7)==1:counts['speaker_change']+=1
   if event in (651,652,654,655):
    kind='source' if event in (651,652) else 'translation'; final=event in (652,655);counts[kind+('_final' if final else '_partial')]+=1
    if e.get(4):first.setdefault(kind,round(now,3))
    if event==652:
     cloud_finals.append(e.get(4,b'').decode('utf8','replace'))
     if isinstance(e.get(6),int):delay.append(round(now-e[6]/1000,3))
   if event in (151,153): raise RuntimeError('provider rejected')
   if event==152: break
  await task
 cloud_errors=dist(reference,norm(' '.join(cloud_finals)))
 print(json.dumps({'dataset':'LibriSpeech two readers A0 B0 A1 with original 0.4s gaps','duration_seconds':19.205,'reference_words':len(reference),'local':{'errors':local_errors,'wer':round(local_errors/len(reference),4),'first_nonempty_seconds':first_local,'events':local_counts},'cloud':{'errors':cloud_errors,'wer':round(cloud_errors/len(reference),4),'first_seconds':first,'events':counts,'final_end_latency_seconds':delay},'normalization':'lowercase, punctuation removed, Mr. to mister'},ensure_ascii=False))
try:asyncio.run(go())
except Exception as e: print('COMPARISON_FAILED',type(e).__name__)
