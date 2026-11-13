#!/usr/bin/env python3
"""Replay a public AMI WAV segment at real time through the existing helper.

Records anonymous diarization events and elapsed times, not speech or names.
Run only with a public CC-BY-4.0 sample, never with a private user recording.
"""
import argparse
import array
import json
import subprocess
import threading
import time
import wave
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--helper", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--wav", required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--start", type=float, default=60)
    p.add_argument("--duration", type=float, default=60)
    args = p.parse_args()
    with wave.open(args.wav, "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, 16000):
            raise ValueError("Requires 16 kHz mono PCM16 WAV")
        if args.start < 0 or args.duration <= 0 or int((args.start + args.duration) * 16000) > w.getnframes():
            raise ValueError("Invalid clip range")
        w.setpos(int(args.start * 16000))
        pcm = w.readframes(int(args.duration * 16000))
    samples = array.array("h"); samples.frombytes(pcm)
    child = subprocess.Popen([args.helper, args.model], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    ready = json.loads(child.stdout.readline())
    if ready.get("type") != "ready": raise RuntimeError("model did not start")
    events = []
    start = time.monotonic()
    def read_events():
        for line in child.stdout:
            event = json.loads(line)
            events.append({"elapsed": time.monotonic() - start, "event": event})
    reader = threading.Thread(target=read_events); reader.start()
    block_size = 1600
    max_lag = 0.0
    for offset in range(0, len(samples), block_size):
        # Deliver the first chunk at t=0.1 seconds, after it would be heard.
        goal = start + min(offset + block_size, len(samples)) / 16000
        wait = goal - time.monotonic()
        if wait > 0: time.sleep(wait)
        floats = array.array("f", (s / 32768.0 for s in samples[offset:offset + block_size]))
        child.stdin.write(floats.tobytes())
        max_lag = max(max_lag, time.monotonic() - goal)
    child.stdin.close()
    child.wait(timeout=60); reader.join(timeout=5)
    if child.returncode != 0 or not events or events[-1]["event"].get("type") != "finished":
        raise RuntimeError("model did not finish")
    result = {"dataset": "AMI ES2002a Mix-Headset, CC BY 4.0", "start": args.start,
              "duration": args.duration, "max_write_lag": max_lag, "events": events}
    args.output.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    print("PASS real-time audio replay", len(events), "events")


if __name__ == "__main__": main()
