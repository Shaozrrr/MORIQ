"""Run reproducible, offline video-model smoke tests on generated fixtures."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--model", type=Path, required=True, help="Local model directory")
parser.add_argument("--fixtures", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--fps", type=float, default=2)
args = parser.parse_args()
if not args.model.is_dir() or not args.fixtures.is_dir():
    parser.error("model and fixtures must be existing local directories")
if args.fps <= 0:
    parser.error("fps must be positive")

prompt = "请用中文回答：方块是什么颜色，如何移动（如果静止请说明）？项目编号是什么？"
expected = {
    "left": {"color": "蓝色", "motion": "向左", "code": "7392"},
    "still": {"color": "绿色", "motion": "静止", "code": "2764"},
    "right": {"color": "红色", "motion": "向右", "code": "4826"},
}
environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
results = []
for name, truth in expected.items():
    video = args.fixtures / f"{name}.mp4"
    if not video.is_file():
        raise FileNotFoundError(video)
    command = [sys.executable, "-m", "mlx_vlm.generate", "--model", str(args.model.resolve()),
               "--video", str(video.resolve()), "--fps", str(args.fps), "--max-tokens", "120",
               "--temperature", "0", "--prompt", prompt]
    started = time.monotonic()
    result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=180)
    results.append({"case": name, "expected": truth, "returncode": result.returncode,
                    "elapsed_seconds": round(time.monotonic() - started, 3),
                    "response": result.stdout.strip(), "error": result.stderr.strip()})
    print(f"{name}: exit={result.returncode}, elapsed={results[-1]['elapsed_seconds']}s", flush=True)
    if result.returncode:
        break
args.output.write_text(json.dumps({"model": str(args.model.resolve()), "fps": args.fps,
                                   "prompt": prompt, "results": results}, ensure_ascii=False, indent=2), encoding="utf-8")
if len(results) != len(expected) or any(item["returncode"] for item in results):
    sys.exit(1)
