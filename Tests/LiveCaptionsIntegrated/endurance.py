#!/usr/bin/env python3
"""Run the isolated caption chain and sample only its own processes' RSS."""
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
env = os.environ.copy()
env['MORIQ_CAPTION_TEST_SECONDS'] = env.get('MORIQ_CAPTION_TEST_SECONDS', '300')
process = subprocess.Popen(['bash', 'Tests/LiveCaptionsIntegrated/run.sh'], cwd=ROOT, env=env)
samples = []
seen = set()

def snapshot():
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,comm='], text=True)
    result = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            try:
                result[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[3])
            except ValueError:
                pass
    return result

while process.poll() is None:
    processes = snapshot()
    descendants = {process.pid}
    while True:
        children = {pid for pid, (ppid, _, _) in processes.items() if ppid in descendants}
        grown = descendants | children
        if grown == descendants:
            break
        descendants = grown
    targets = {pid: data for pid, data in processes.items() if pid in descendants and Path(data[2]).name in ('CaptionTest', 'moriq-speech')}
    if targets:
        seen.update(targets)
        samples.append(sum(data[1] for data in targets.values()))
    time.sleep(10)

code = process.wait()
remaining = snapshot()
survivors = [pid for pid in seen if pid in remaining and Path(remaining[pid][2]).name in ('CaptionTest', 'moriq-speech')]
if samples:
    print(f'RESOURCE samples={len(samples)} first_mib={samples[0]/1024:.1f} peak_mib={max(samples)/1024:.1f} last_mib={samples[-1]/1024:.1f} surviving_test_processes={len(survivors)}', flush=True)
else:
    print('RESOURCE no test process sampled', flush=True)
if code or not samples or survivors:
    raise SystemExit(code or 1)
