#!/usr/bin/env python3
"""Research-only token timings and English word aggregation, not a diarizer.

Runs a modified helper in a temporary directory with explicitly supplied public
recordings. Neither this script nor the helper is connected to the app. Its
sample clock counts contiguous stdin only: no claim about captured-audio clocks,
dropped frames, audio-device changes, or speaker accuracy is made.
"""
import argparse
import json
import pathlib
import string
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--whisper-source', type=pathlib.Path, required=True)
p.add_argument('--whisper-build', type=pathlib.Path, required=True)
p.add_argument('--ffmpeg', type=pathlib.Path, required=True)
p.add_argument('--audio', type=pathlib.Path, action='append', required=True)
p.add_argument('--export-json', type=pathlib.Path, help='optional isolated public-fixture output; contains recognized text')
a = p.parse_args()
source = (ROOT/'Vendor/SpeechEngine/main.cpp').read_text()
for old, new in [
    ('int iteration=0;', 'int iteration=0; uint64_t totalSamples=0;'),
    ('if(n==0) break;', 'if(n==0) break; totalSamples+=n;'),
    ('p.print_timestamps=false;', 'p.print_timestamps=false; p.token_timestamps=true;'),
]:
    assert old in source
    source = source.replace(old, new, 1)
needle = 'std::string text; for(int i=0;'
assert needle in source
source = source.replace(needle, r'''fprintf(stderr,"WINDOW\t%llu\t%zu\t%d\n",(unsigned long long)(totalSamples-rolling.size()),rolling.size(),((iteration+1)%commitEvery)==0 || n<step);
  for(int si=0;si<whisper_full_n_segments(ctx);si++) for(int ti=0;ti<whisper_full_n_tokens(ctx,si);ti++) {
   auto d=whisper_full_get_token_data(ctx,si,ti); const char *tok=whisper_full_get_token_text(ctx,si,ti);
   if(d.id<whisper_token_eot(ctx) && tok) { fprintf(stderr,"TOKEN\t%lld\t%lld\t",(long long)d.t0,(long long)d.t1); for(const unsigned char *x=(const unsigned char*)tok;*x;x++) fprintf(stderr,"%02x",*x); fprintf(stderr,"\n"); }
  }
  std::string text; for(int i=0;''', 1)
base = a.whisper_build/'whisper'
libs = [base/'src/libwhisper.a',base/'ggml/src/libggml.a',base/'ggml/src/libggml-cpu.a',base/'ggml/src/ggml-blas/libggml-blas.a',base/'ggml/src/libggml-base.a']
with tempfile.TemporaryDirectory(prefix='moriq-word-times-') as folder:
    temp = pathlib.Path(folder); cpp=temp/'main.cpp'; exe=temp/'helper'; cpp.write_text(source)
    subprocess.run(['c++','-O3','-I',str(a.whisper_source/'include'),'-I',str(a.whisper_source/'ggml/include'),str(cpp),*(str(x) for x in libs),'-lm','-framework','Accelerate','-o',str(exe)],check=True)
    joined=b''
    for audio in a.audio:
        result=subprocess.run([str(a.ffmpeg),'-v','error','-i',str(audio),'-ar','16000','-ac','1','-f','f32le','-'],check=True,stdout=subprocess.PIPE)
        joined += result.stdout
    result=subprocess.run([str(exe),str(ROOT/'Vendor/SpeechEngine/ggml-base.bin'),'en'],input=joined,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True)
    windows=[]
    for line in result.stderr.splitlines():
        parts=line.split(b'\t')
        if parts[0]==b'WINDOW': windows.append((int(parts[1]),int(parts[2]),[],bool(int(parts[3]))))
        elif parts[0]==b'TOKEN':
            start,end=int(parts[1]),int(parts[2]); raw=bytes.fromhex(parts[3].decode())
            base_sample,length,tokens,_=windows[-1]
            assert 0 <= start <= end and end*160 <= length
            tokens.append((base_sample+start*160,base_sample+end*160,raw))
    assert windows and windows[0][0]==0
    assert all(x[0] >= 0 and x[0]+x[1] <= len(joined)//4 for x in windows)
    if len(joined)//4 > 8*16000:
        assert any(x[0] > 0 for x in windows), 'missing rolling-window base offset after commit'
    # English-only exploratory assembly: tokens starting with a space start a
    # word, subsequent bytes are appended; decoding occurs after concatenation
    # to preserve a codepoint split across BPE tokens. This is not CJK word
    # segmentation and punctuation-only or zero-span words are not alignable.
    def words(tokens):
        grouped=[]
        for start,end,raw in tokens:
            if raw.startswith(b' ') or not grouped: grouped.append([start,end,raw])
            else: grouped[-1][1]=max(grouped[-1][1],end); grouped[-1][2]+=raw
        out=[]
        for start,end,raw in grouped:
            try: text=raw.decode('utf-8').strip()
            except UnicodeDecodeError: continue
            if text and text.strip(string.punctuation) and end>start: out.append((start,end,text))
        return out
    assert words([(0,1,b' Qu'),(1,2,b'il'),(2,3,b'ter')]) == [(0,3,'Quilter')]
    assert words([(0,1,b' \xe4'),(1,2,b'\xb8\xad')]) == [(0,2,'中')]
    groups=[words(w[2]) for w in windows]
    stable=0
    for before,after,wa,wb in zip(groups,groups[1:],windows,windows[1:]):
        if wa[0]!=wb[0]: continue  # reset/overlap: no cross-window dedup claim
        for left,right in zip(before,after):
            if left[2].casefold().strip(string.punctuation)!=right[2].casefold().strip(string.punctuation): break
            stable+=1
    assert any(groups) and stable>0
    assert all(window[0] <= start < end <= window[0]+window[1] for window,group in zip(windows,groups) for start,end,_ in group)
    if a.export_json:
        a.export_json.write_text(json.dumps({'sampleRate':16000,'inputSamples':len(joined)//4,'windows':[{'start':window[0],'end':window[0]+window[1],'final':window[3], 'words':[{'start':start,'end':end,'text':text} for start,end,text in group]} for window,group in zip(windows,groups)]},ensure_ascii=False))
    print(f'PASS {len(windows)} actual windows, {sum(map(len,groups))} word hypotheses, {stable} repeated-prefix words, {len(joined)//4} input samples')
    print('NOT validated: real capture clock, word-ground-truth timing, window-boundary dedup, non-English segmentation, diarization')
