#!/usr/bin/env python3
"""Run upstream sherpa-onnx offline diarization on an existing 16kHz mono WAV."""
import argparse
import json
import time
import wave
from pathlib import Path
import numpy as np
import sherpa_onnx as s

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--wav", required=True)
p.add_argument("--segmentation", required=True)
p.add_argument("--embedding", required=True)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--source-start", type=float, default=0)
a = p.parse_args()
with wave.open(a.wav, "rb") as w:
    if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, 16000): raise ValueError("requires mono 16kHz PCM16")
    audio = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
config = s.OfflineSpeakerDiarizationConfig(
    segmentation=s.OfflineSpeakerSegmentationModelConfig(pyannote=s.OfflineSpeakerSegmentationPyannoteModelConfig(model=a.segmentation, window_shift_ratio=0.1)),
    embedding=s.SpeakerEmbeddingExtractorConfig(model=a.embedding),
    clustering=s.FastClusteringConfig(num_clusters=-1, threshold=0.5),
    min_duration_on=0.3, min_duration_off=0.5)
if not config.validate(): raise RuntimeError("invalid config")
engine = s.OfflineSpeakerDiarization(config)
begin = time.monotonic(); turns = engine.process(audio).sort_by_start_time(); elapsed = time.monotonic()-begin
payload = {"start": a.source_start, "duration": len(audio)/16000, "processing_seconds": elapsed,
           "events": [{"elapsed": None, "event": {"type": "turns", "turns": [
               {"speaker": t.speaker, "startSample": round(t.start*16000), "endSample": round(t.end*16000), "final": True} for t in turns]}}]}
a.output.write_text(json.dumps(payload), encoding="utf-8")
print("sherpa offline segments", len(turns), "speakers", len({t.speaker for t in turns}), "seconds", round(elapsed, 3))
