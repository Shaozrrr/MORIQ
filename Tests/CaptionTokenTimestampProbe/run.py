#!/usr/bin/env python3
"""Isolated whisper.cpp token-time probe; never changes the shipping helper.

Inputs: previously built whisper.cpp static archives/source, bundled model and an
explicit public audio fixture. Tokens are inspected in memory and never printed.
"""
import argparse
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--whisper-source', type=pathlib.Path, required=True)
parser.add_argument('--whisper-build', type=pathlib.Path, required=True)
parser.add_argument('--ffmpeg', type=pathlib.Path, required=True)
parser.add_argument('--audio', type=pathlib.Path, required=True, help='public test recording, not private audio')
args = parser.parse_args()

source = (ROOT / 'Vendor/SpeechEngine/main.cpp').read_text()
assert 'p.print_timestamps=false;' in source
source = source.replace('p.print_timestamps=false;', 'p.print_timestamps=false; p.token_timestamps=true;')
needle = 'std::string text; for(int i=0;'
assert needle in source
source = source.replace(needle, r'''fprintf(stderr,"WINDOW\t%zu\n",rolling.size());
  for(int si=0;si<whisper_full_n_segments(ctx);si++) for(int ti=0;ti<whisper_full_n_tokens(ctx,si);ti++) { auto d=whisper_full_get_token_data(ctx,si,ti); if(d.id<whisper_token_eot(ctx)) fprintf(stderr,"TIME\t%lld\t%lld\n",(long long)d.t0,(long long)d.t1); }
  std::string text; for(int i=0;''')
archive = args.whisper_build / 'whisper'
libs = [archive/'src/libwhisper.a', archive/'ggml/src/libggml.a', archive/'ggml/src/libggml-cpu.a', archive/'ggml/src/ggml-blas/libggml-blas.a', archive/'ggml/src/libggml-base.a']
with tempfile.TemporaryDirectory(prefix='moriq-token-times-') as folder:
    root = pathlib.Path(folder)
    main, exe, pcm = root/'main.cpp', root/'helper', root/'audio.pcm'
    main.write_text(source)
    subprocess.run(['c++', '-O3', '-I', str(args.whisper_source/'include'), '-I', str(args.whisper_source/'ggml/include'), str(main), *(str(lib) for lib in libs), '-lm', '-framework', 'Accelerate', '-o', str(exe)], check=True)
    subprocess.run([str(args.ffmpeg), '-v', 'error', '-i', str(args.audio), '-ar', '16000', '-ac', '1', '-f', 'f32le', str(pcm)], check=True)
    with pcm.open('rb') as audio:
        result = subprocess.run([str(exe), str(ROOT/'Vendor/SpeechEngine/ggml-base.bin'), 'en'], stdin=audio, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=True)
    window = None
    total = zero = 0
    for line in result.stderr.splitlines():
        parts = line.split('\t')
        if parts[0] == 'WINDOW': window = int(parts[1])
        elif parts[0] == 'TIME':
            assert window is not None
            start, end = map(int, parts[1:])
            assert 0 <= start <= end and end * 160 <= window, (start, end, window)
            total += 1
            zero += start == end
    assert total > 0
    print(f'PASS actual token timestamps; {total} tokens, {zero} zero-duration; checked against each rolling window')
    print('NOT validated: word aggregation, absolute time mapping, timing accuracy, speaker alignment')
