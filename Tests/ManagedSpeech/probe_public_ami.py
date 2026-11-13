import sys,subprocess,asyncio,time,wave,json,uuid,argparse,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Services/ManagedAI'))
p=argparse.ArgumentParser(description='Opt-in public AMI online test; may incur usage charges.')
p.add_argument('--run',action='store_true');p.add_argument('--wav',type=Path,required=True)
args=p.parse_args()
if not args.run: p.error('pass --run to send public AMI test audio to the service')
if hashlib.sha256(args.wav.read_bytes()).hexdigest()!='bd705284d4d2b1f945874361e6d9ecca8c484d10f203d25287bef62987f5f493': p.error('wrong public AMI WAV hash')
from speech_gateway import PROVIDER,request,parse,provider_tls_context,NoRedirect
from websockets.exceptions import ConnectionClosed
async def go():
 p=subprocess.run(['/usr/bin/security','find-generic-password','-s','local.moriq.volcengine.speech','-a','MORIQ','-w'],capture_output=True)
 if p.returncode: print('CREDENTIAL_UNAVAILABLE'); return
 key=p.stdout.decode().strip(); del p
 if not key: print('CREDENTIAL_UNAVAILABLE'); return
 with wave.open(str(args.wav)) as w:
  assert (w.getnchannels(),w.getsampwidth(),w.getframerate())==(1,2,16000)
  w.setpos(60*16000); pcm=w.readframes(20*16000)
 session=str(uuid.uuid4()); counts={}; trace=[]; textlength={'source':0,'translation':0}; first={}; started=time.monotonic()
 try:
  async with NoRedirect(PROVIDER,additional_headers={'X-Api-Key':key,'X-Api-Resource-Id':'volc.service_type.10053'},ssl=provider_tls_context(),proxy=None,open_timeout=20) as ws:
   del key
   await ws.send(request(100,session,source='en',target='zh'))
   h=parse(await asyncio.wait_for(ws.recv(),20)); assert h.get(2)==150
   start=time.monotonic()
   async def send():
    for off in range(0,len(pcm),2560):
     await ws.send(request(200,session,pcm=pcm[off:off+2560])); await asyncio.sleep(.08)
    await ws.send(request(102,session))
   t=asyncio.create_task(send())
   while True:
    raw=await asyncio.wait_for(ws.recv(),40); e=parse(raw); n=e.get(2); now=time.monotonic()-start
    counts[str(n)]=counts.get(str(n),0)+1
    if n in (650,653): trace.append({'event':n,'at':round(now,3),'start':e.get(5),'end':e.get(6),'spk_chg':e.get(7),'field7_present':7 in e})
    if n in (651,652,654,655):
     which='source' if n in (651,652) else 'translation'; tdata=e.get(4,b'')
     if tdata: first.setdefault(which,round(now,3)); textlength[which]+=len(tdata)
     if n in (652,655): trace.append({'event':n,'at':round(now,3),'start':e.get(5),'end':e.get(6),'spk_chg':e.get(7),'chars':len(tdata.decode('utf8','replace'))})
    if n in (151,153): raise RuntimeError('session rejected')
    if n==152: break
   await t
  print(json.dumps({'sample':'AMI ES2002a 60-80 seconds publicly licensed','duration_seconds':20,'counts':counts,'first_seconds':first,'payload_bytes':textlength,'events':trace,'elapsed_seconds':round(time.monotonic()-started,2)},ensure_ascii=False))
 except Exception as e: print('TEST_FAILED',type(e).__name__)
asyncio.run(go())
