#!/usr/bin/env python3
"""Isolated CJK token-time probe, not a word aligner or a production helper.

Each emitted text span retains the union of its source token time intervals.
UTF-8 fragments must be accumulated until they decode; multi-character tokens
are never split and receive no invented character/word timings. This cannot
prove the Whisper token times are accurate against spoken-audio ground truth.
"""
import argparse
import json
import pathlib
import subprocess
import tempfile
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[2]

def utf8_spans(tokens):
    """Return valid text spans, dropped groups, and number of joined fragments."""
    output, pending, pending_start, pending_end, fragments = [], bytearray(), None, None, 0
    dropped = joined = 0
    valid_timing = True
    for start, end, data in tokens:
        if not data or start < 0 or end < start:
            dropped += 1
            pending.clear(); pending_start = pending_end = None; fragments = 0; valid_timing = True
            continue
        valid_timing = valid_timing and end > start
        if pending_start is None:
            pending_start, pending_end = start, end
        else:
            pending_start, pending_end = min(pending_start, start), max(pending_end, end)
        pending.extend(data); fragments += 1
        try:
            text = pending.decode('utf-8', errors='strict')
        except UnicodeDecodeError as error:
            if error.reason == 'unexpected end of data' and len(pending) <= 64:
                continue
            dropped += 1
            pending.clear(); pending_start = pending_end = None; fragments = 0; valid_timing = True
            continue
        # Only real positive-duration spans containing a letter/number get
        # speaker assignments. Zero-duration punctuation isn't stretched.
        if valid_timing and pending_end > pending_start and any(unicodedata.category(c)[0] in ('L', 'N') for c in text):
            output.append((pending_start, pending_end, text))
            if fragments > 1:
                joined += 1
        else:
            dropped += 1
        pending.clear(); pending_start = pending_end = None; fragments = 0; valid_timing = True
    if pending:
        dropped += 1
    return output, dropped, joined

def selftest():
    # 日 is split across two byte-level tokens, with two measured intervals.
    spans, dropped, joined = utf8_spans([(20, 40, b'\xe6\x97'), (40, 50, b'\xa5'), (50, 70, '我们'.encode())])
    assert spans == [(20, 50, '日'), (50, 70, '我们')] and dropped == 0 and joined == 1
    assert utf8_spans([(1, 1, '。'.encode())])[0] == []
    assert utf8_spans([(0, 10, b'\xff')])[0] == []
    assert utf8_spans([(10, 0, '中'.encode())])[0] == []
    assert utf8_spans([(1, 2, b'\xe6\x97')])[0] == []
    assert utf8_spans([(0, 0, b'\xe6\x97'), (40, 50, b'\xa5')])[0] == []

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--whisper-source', type=pathlib.Path, required=True)
    p.add_argument('--whisper-build', type=pathlib.Path, required=True)
    p.add_argument('--ffmpeg', type=pathlib.Path, required=True)
    p.add_argument('--audio', type=pathlib.Path, required=True, help='public recording, never private audio')
    p.add_argument('--model', type=pathlib.Path, default=ROOT/'Vendor/SpeechEngine/ggml-base.bin')
    p.add_argument('--seconds', type=int, default=10)
    p.add_argument('--language', choices=['zh','ja','ko'], default='zh')
    p.add_argument('--export-json', type=pathlib.Path)
    args = p.parse_args()
    if not 1 <= args.seconds <= 60: p.error('seconds must be between 1 and 60')
    selftest()
    source = (ROOT/'Vendor/SpeechEngine/main.cpp').read_text()
    needle = 'std::string text; for(int i=0;'
    assert needle in source
    source = source.replace(needle, r'''fprintf(stderr,"WINDOW\t%llu\t%llu\n",(unsigned long long)(totalSamples-rolling.size()),(unsigned long long)totalSamples);
  for(int si=0;si<whisper_full_n_segments(ctx);si++) for(int ti=0;ti<whisper_full_n_tokens(ctx,si);ti++) {
   auto d=whisper_full_get_token_data(ctx,si,ti); const char *tok=whisper_full_get_token_text(ctx,si,ti);
   if(d.id<whisper_token_eot(ctx) && tok) { fprintf(stderr,"TOKEN\t%lld\t%lld\t",(long long)d.t0,(long long)d.t1); for(const unsigned char *x=(const unsigned char*)tok;*x;x++) fprintf(stderr,"%02x",*x); fprintf(stderr,"\n"); }
  }
  std::string text; for(int i=0;''', 1)
    base = args.whisper_build/'whisper'
    libs = [base/'src/libwhisper.a',base/'ggml/src/libggml.a',base/'ggml/src/libggml-cpu.a',base/'ggml/src/ggml-blas/libggml-blas.a',base/'ggml/src/libggml-base.a']
    with tempfile.TemporaryDirectory(prefix='moriq-cjk-token-') as folder:
        root=pathlib.Path(folder); cpp=root/'main.cpp'; exe=root/'helper'; cpp.write_text(source)
        subprocess.run(['c++','-O3','-std=c++17','-I',str(args.whisper_source/'include'),'-I',str(args.whisper_source/'ggml/include'),str(cpp),*(str(x) for x in libs),'-lm','-framework','Accelerate','-o',str(exe)],check=True)
        pcm=subprocess.run([str(args.ffmpeg),'-v','error','-i',str(args.audio),'-t',str(args.seconds),'-ar','16000','-ac','1','-f','f32le','-'],check=True,stdout=subprocess.PIPE).stdout
        result=subprocess.run([str(exe),str(args.model),args.language,'--word-timestamps'],input=pcm,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True)
        windows=[]
        for line in result.stderr.splitlines():
            fields=line.split(b'\t')
            if fields[0]==b'WINDOW': windows.append((int(fields[1]),int(fields[2]),[]))
            elif fields[0]==b'TOKEN':
                start,end=int(fields[1]),int(fields[2]); data=bytes.fromhex(fields[3].decode())
                lo,hi,tokens=windows[-1]
                if 0 <= start <= end and end*160 <= hi-lo: tokens.append((lo+start*160,lo+end*160,data))
        assert windows, 'no speech windows'
        spans=[]; dropped=joined=0
        for lo,hi,tokens in windows:
            group,d,j=utf8_spans(tokens); dropped+=d; joined+=j
            assert all(lo<=a<b<=hi for a,b,_ in group)
            spans.append({'start':lo,'end':hi,'spans':[{'start':a,'end':b,'text':text} for a,b,text in group]})
        count=sum(len(w['spans']) for w in spans)
        assert count > 0, 'no valid timed non-punctuation spans'
        if args.export_json: args.export_json.write_text(json.dumps({'sampleRate':16000,'windows':spans},ensure_ascii=False))
        print(f'PASS {args.language} real token-span probe: {len(windows)} windows, {count} spans, {joined} joined UTF-8 fragments, {dropped} unassignable groups')
        print('NOT validated: CJK word boundaries, timestamp accuracy, live capture clock, diarization, other languages')
