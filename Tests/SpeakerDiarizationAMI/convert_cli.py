#!/usr/bin/env python3
"""Convert FluidAudio offline CLI JSON for scoring; no latency is inferred."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--input", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--start", type=float, default=60)
p.add_argument("--duration", type=float, default=60)
a = p.parse_args()
source = json.loads(a.input.read_text())
turns = [{"speaker": t["speakerIndex"], "startSample": round(t["startTimeSeconds"] * 16000),
          "endSample": round(t["endTimeSeconds"] * 16000), "final": True} for t in source["segments"]]
out = {"start": a.start, "duration": a.duration, "events": [{"elapsed": None, "event": {"type": "turns", "turns": turns}}]}
a.output.write_text(json.dumps(out), encoding="utf-8")
