#!/usr/bin/env python3
"""Score a captured AMI excerpt with dscore's upstream NIST md-eval-22.pl."""
import argparse
import json
import statistics
import subprocess
import tempfile
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--events", type=Path, required=True)
    p.add_argument("--reference-rttm", type=Path, required=True)
    p.add_argument("--md-eval", type=Path, required=True)
    args = p.parse_args()
    data = json.loads(args.events.read_text())
    start, duration = float(data["start"]), float(data["duration"])
    end = start + duration
    ref = []
    for line in args.reference_rttm.read_text().splitlines():
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER": continue
        begin, length = float(fields[3]), float(fields[4])
        lo, hi = max(start, begin), min(end, begin + length)
        if hi > lo: ref.append(f"SPEAKER excerpt 1 {lo-start:.6f} {hi-lo:.6f} <NA> <NA> {fields[7]} <NA> <NA>\n")
    predicted, completion_lags = [], []
    for item in data["events"]:
        for turn in item["event"].get("turns") or []:
            if not turn.get("final"): continue
            lo, hi = max(0, turn["startSample"] / 16000), min(duration, turn["endSample"] / 16000)
            if hi <= lo: continue
            predicted.append(f"SPEAKER excerpt 1 {lo:.6f} {hi-lo:.6f} <NA> <NA> S{turn['speaker']} <NA> <NA>\n")
            # Time from predicted turn end to final output, not ground-truth
            # word or speaker-switch delay. Negative values indicate inconsistency.
            if item.get("elapsed") is not None: completion_lags.append(item["elapsed"] - hi)
    if not ref or not predicted: raise RuntimeError("empty reference or hypothesis")
    with tempfile.TemporaryDirectory(prefix="moriq-ami-score-") as tmp:
        root = Path(tmp); r = root / "ref.rttm"; s = root / "sys.rttm"; u = root / "excerpt.uem"
        r.write_text("".join(ref)); s.write_text("".join(predicted)); u.write_text(f"excerpt 1 0 {duration:.6f}\n")
        result = subprocess.run(["perl", str(args.md_eval), "-r", str(r), "-s", str(s), "-c", "0", "-u", str(u)], capture_output=True, text=True, check=True)
        for line in result.stdout.splitlines():
            if any(x in line for x in ("SCORED SPEAKER TIME", "MISSED SPEAKER TIME", "FALARM SPEAKER TIME", "SPEAKER ERROR TIME", "DIARIZATION ERROR")):
                print(line)
    lags = sorted(completion_lags)
    if lags:
        print("final turns:", len(lags), "median final-output lag from predicted turn end:", round(statistics.median(lags), 3), "s; max:", round(max(lags), 3), "s")
    else:
        print("final turns:", len(predicted), "; output latency not measured in offline processing")
    print("max audio-write scheduling lag:", data.get("max_write_lag", "not recorded"), "s")
    print("No collar; overlapped speech included; false attribution is diarization confusion, not named-person identification.")


if __name__ == "__main__": main()
