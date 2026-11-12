import subprocess,numpy as np,json,time,re
from pathlib import Path
import os
root=Path(__file__).resolve().parents[2]
fixture=Path(os.environ.get('MORIQ_HUMAN_AUDIO_FIXTURE','/tmp/moriq-human-benchmark'))
res=json.load(open(fixture/'results.json'))[:4]
a=[]
for i in range(4):
 b=subprocess.check_output([str(root/'Vendor/MediaEngine/ffmpeg'),'-v','error','-i',str(fixture/f'{i}.wav'),'-ar','16000','-ac','1','-f','f32le','pipe:1']); a.append(np.frombuffer(b,dtype='<f4'))
a=np.concatenate(a)
def norm(s):
 s=s.lower().replace('mr.', 'mister');return re.findall(r"[a-z]+(?:'[a-z]+)?",s)
def dist(a,b):
 prev=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  row=[i]
  for j,y in enumerate(b,1):row.append(min(row[-1]+1,prev[j]+1,prev[j-1]+(x!=y)))
  prev=row
 return prev[-1]
ref=norm(' '.join(x['reference'] for x in res))
for label,noise in [('clean',0),('noise_rms_0.01',0.01)]:
 data=np.clip(a+np.random.default_rng(43).normal(0,noise,len(a)),-1,1).astype('<f4');t=time.monotonic()
 p=subprocess.run([str(root/'Vendor/SpeechEngine/moriq-speech'),str(root/'Vendor/SpeechEngine/ggml-base.bin'),'en'],input=data.tobytes(),capture_output=True,timeout=240)
 lines=p.stdout.decode().splitlines();finals=[x[2:] for x in lines if x.startswith('F\t')]; hyp=norm(' '.join(finals)); print(json.dumps({'case':label,'seconds':round(len(data)/16000,2),'wall_seconds':round(time.monotonic()-t,2),'ref_words':len(ref),'errors':dist(ref,hyp),'wer':round(dist(ref,hyp)/len(ref),3),'finals':finals,'returncode':p.returncode},ensure_ascii=False),flush=True)
