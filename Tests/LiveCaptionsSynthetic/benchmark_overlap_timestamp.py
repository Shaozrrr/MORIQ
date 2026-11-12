import glob,subprocess,time,resource,re,unicodedata,json
base='/tmp/moriq-whisper-models'; cli='/tmp/moriq-whisper-universal/bin/whisper-cli'
def norm(s,language):
 s=unicodedata.normalize('NFKC',s).lower()
 return re.findall(r"[a-z0-9']+",s.replace('9','nine')) if language=='en' else [c for c in s if c.isalnum()]
def alignment(a,b):
 d=[[(0,0,0,0)]*(len(b)+1) for _ in range(len(a)+1)]
 for i in range(1,len(a)+1):d[i][0]=(i,0,i,0)
 for j in range(1,len(b)+1):d[0][j]=(j,0,0,j)
 for i in range(1,len(a)+1):
  for j in range(1,len(b)+1):
   z=d[i-1][j-1]; sub=(z[0]+(a[i-1]!=b[j-1]),z[1]+(a[i-1]!=b[j-1]),z[2],z[3]);z=d[i-1][j];dele=(z[0]+1,z[1],z[2]+1,z[3]);z=d[i][j-1];ins=(z[0]+1,z[1],z[2],z[3]+1);d[i][j]=min(sub,dele,ins,key=lambda x:x[0])
 return d[-1][-1]
for language in ['en','ja','ko']:
 files=sorted(glob.glob(f'{base}/overlap-{language}-*.wav'))
 reference=norm(open('/tmp/moriq-caption-benchmark/english-20.reference.txt' if language=='en' else f'{base}/{language}.reference.txt').read(),language)
 for model in ['base','small']:
  t0=time.monotonic();time.sleep(3);first=None;parts=[];elapsed=[];start=resource.getrusage(resource.RUSAGE_CHILDREN)
  for i,f in enumerate(files):
   output=f'{base}/ts-{language}-{model}-{i:02}'
   cmd=['/usr/bin/arch','-arm64',cli,'-m',f'{base}/ggml-{model}.bin','-f',f,'-l',language,'-t','4','-ojf','-of',output]
   begin=time.monotonic();p=subprocess.run(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30);elapsed.append(time.monotonic()-begin)
   if p.returncode: raise RuntimeError((model,language,i,p.returncode))
   data=json.load(open(output+'.json')); tokens=[t for seg in data['transcription'] for t in seg.get('tokens',[]) if not t['text'].startswith('[_')]
   lower=0 if i==0 else 500; upper=3001 if i==len(files)-1 else 2500
   selected=[t['text'] for t in tokens if lower <= (t['offsets']['from']+t['offsets']['to'])/2 < upper]
   parts.append(''.join(selected))
   if first is None and any(t.strip() for t in selected):first=time.monotonic()-t0
  hyp=norm(''.join(parts),language);distance,s,d,ins=alignment(reference,hyp);end=resource.getrusage(resource.RUSAGE_CHILDREN);cpu=end.ru_utime+end.ru_stime-start.ru_utime-start.ru_stime
  print(language,model,'WER_or_CER',round(distance/len(reference),3),'S',s,'D',d,'I',ins,'ref',len(reference),'first_s',round(first or -1,2),'cpu_s',round(cpu,2),'wall_s',round(sum(elapsed),2),'max_window_s',round(max(elapsed),2),flush=True)
