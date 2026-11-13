"""Compare rolling-window recognition on an identical public audio fixture.

This is an offline ASR-only throughput/accuracy check, not live latency or
translation quality. Supply existing model paths; no downloads or audio capture.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("models", nargs="+", type=Path)
parser.add_argument("--fixture", type=Path, default=Path(os.environ.get("MORIQ_HUMAN_AUDIO_FIXTURE", "/tmp/moriq-human-benchmark")))
parser.add_argument("--start", type=int, default=0)
parser.add_argument("--count", type=int, default=4)
args = parser.parse_args()
if args.start < 0 or args.count < 1:
    parser.error("start must be nonnegative and count must be positive")
records = json.loads((args.fixture / "results.json").read_text())[args.start:args.start + args.count]
if len(records) != args.count:
    parser.error("fixture does not contain the requested records")
audio = []
for i in range(args.start, args.start + len(records)):
    decoded = subprocess.check_output([str(ROOT / "Vendor/MediaEngine/ffmpeg"), "-v", "error", "-i", str(args.fixture / f"{i}.wav"), "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1"])
    audio.append(np.frombuffer(decoded, dtype="<f4"))
audio = np.concatenate(audio)

def normalize(value):
    return re.findall(r"[a-z]+(?:'[a-z]+)?", value.lower().replace("mr.", "mister"))

def distance(left, right):
    prev = list(range(len(right) + 1))
    for i, x in enumerate(left, 1):
        row = [i]
        for j, y in enumerate(right, 1):
            row.append(min(row[-1] + 1, prev[j] + 1, prev[j - 1] + (x != y)))
        prev = row
    return prev[-1]

reference = normalize(" ".join(r["reference"] for r in records))
for model in args.models:
    digest = hashlib.sha256()
    with model.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    for label, noise in (("clean", 0), ("noise_rms_0.01", .01)):
        samples = np.clip(audio + np.random.default_rng(43).normal(0, noise, len(audio)), -1, 1).astype("<f4")
        start = time.monotonic()
        result = subprocess.run([str(ROOT / "Vendor/SpeechEngine/moriq-speech"), str(model), "en"], input=samples.tobytes(), capture_output=True, timeout=600, check=True)
        elapsed = time.monotonic() - start
        finals = [s[2:] for s in result.stdout.decode().splitlines() if s.startswith("F\t")]
        words = normalize(" ".join(finals))
        errors = distance(reference, words)
        print(json.dumps({"model": model.name, "sha256": digest.hexdigest(), "case": label, "fixture_start": args.start, "fixture_count": len(records), "audio_seconds": round(len(samples) / 16000, 2), "wall_seconds": round(elapsed, 2), "reference_words": len(reference), "errors": errors, "wer": round(errors / len(reference), 3)}, ensure_ascii=False), flush=True)
