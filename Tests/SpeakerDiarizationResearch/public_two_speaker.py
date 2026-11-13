#!/usr/bin/env python3
"""Optional research-only two-reader test; downloads public LibriSpeech samples.

Requires an already built FluidAudio CLI and ffmpeg; not a product test or DER.
"""
import argparse
import collections
import itertools
import json
import pathlib
import subprocess
import tempfile
import urllib.parse
import wave

p = argparse.ArgumentParser()
p.add_argument('--fluidaudio-cli', required=True)
p.add_argument('--ffmpeg', required=True)
args = p.parse_args()

def rows(dataset, split, offset):
    query = urllib.parse.urlencode(dict(dataset=dataset, config='clean', split=split, offset=offset, length=4))
    return json.loads(subprocess.check_output(['curl', '-fsSL', '--max-time', '60', 'https://datasets-server.huggingface.co/rows?' + query]))['rows']

with tempfile.TemporaryDirectory(prefix='moriq-public-speakers-') as d:
    root = pathlib.Path(d)
    a = rows('hf-internal-testing/librispeech_asr_dummy', 'validation', 0)
    b = rows('openslr/librispeech_asr', 'test', 1000)
    assert len(a) == len(b) == 4
    assert {x['row']['speaker_id'] for x in a} == {1272} and {x['row']['speaker_id'] for x in b} == {8455}
    audio = bytearray()
    reference = []
    for i in range(4):
        for label, row in [('A', a[i]['row']), ('B', b[i]['row'])]:
            f = root / f'{label}{i}.flac'
            subprocess.run(['curl', '-fsSL', '--max-time', '60', '-o', str(f), row['audio'][0]['src']], check=True)
            pcm = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(f), '-f', 's16le', '-ac', '1', '-ar', '16000', 'pipe:1'])
            start = len(audio) / 32000
            audio.extend(pcm)
            reference.append((label, start, len(audio) / 32000))
            audio.extend(b'\0' * 12800)  # 0.4 seconds between clips
    wav = root / 'public-readers.wav'
    with wave.open(str(wav), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(audio)
    for model in ('lseend', 'sortformer'):
        out = root / f'{model}.json'
        cmd = [args.fluidaudio_cli, model, str(wav), '--output', str(out)]
        if model == 'lseend': cmd += ['--variant', 'dihard3']
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
        result = json.loads(out.read_text())
        matrix = collections.Counter()
        for label, start, end in reference:
            for seg in result['segments']:
                overlap = max(0.0, min(end, seg['endTimeSeconds']) - max(start, seg['startTimeSeconds']))
                matrix[(label, seg['speakerIndex'])] += overlap
        ids = sorted({key[1] for key in matrix})
        total = sum(matrix.values())
        best = max((matrix[('A', x)] + matrix[('B', y)] for x, y in itertools.permutations(ids, 2)), default=0)
        print(f'{model}: assigned clip overlap {best:.1f}/{total:.1f} s; nonempty labels {len(ids)}; processing {result["processingTimeSeconds"]:.2f} s')
    print('This is label agreement only over predicted intervals inside whole clips, NOT DER; clips include silence.')
