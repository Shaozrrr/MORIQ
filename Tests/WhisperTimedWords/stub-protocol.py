#!/usr/bin/env python3
"""Exercise the production helper protocol without downloading any models."""
import pathlib, struct, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='moriq-cjk-protocol-') as tmp:
    exe=pathlib.Path(tmp)/'helper'
    subprocess.run(['c++','-O2','-std=c++17','-I',str(root/'Tests/WhisperTimedWords/Stub'),str(root/'Vendor/SpeechEngine/main.cpp'),'-o',str(exe)],check=True)
    audio=struct.pack('<f',1.0)*32000
    def run(args): return subprocess.run([str(exe),'unused','zh',*args],input=audio,stdout=subprocess.PIPE,check=True).stdout.decode().splitlines()
    old=run([]); timed=run(['--word-timestamps'])
    assert [line for line in timed if line.startswith(('P\t','F\t'))] == old
    assert not any(line.startswith(('B\t','W\t','E')) for line in old)
    words=[line.split('\t') for line in timed if line.startswith('W\t')]
    assert [(int(x[1]),int(x[2]),bytes.fromhex(x[3]).decode()) for x in words] == [(1600,4800,'智'),(4800,6400,'我们')],words
    print('PASS original transcript unchanged; fragmented UTF-8 merged; zero-duration token omitted')
