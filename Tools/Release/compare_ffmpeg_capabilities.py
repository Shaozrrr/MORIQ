#!/usr/bin/env python3
"""Compare declared encoders, decoders, formats and protocols; no media is opened."""
import argparse, pathlib, subprocess, sys
p=argparse.ArgumentParser(description=__doc__);p.add_argument('candidate',type=pathlib.Path);p.add_argument('reference',type=pathlib.Path);a=p.parse_args()
try:
 mismatch=False
 for flag in ('-encoders','-decoders','-formats','-protocols'):
  def capture(path):return subprocess.run([str(path.resolve()),'-hide_banner',flag],check=True,capture_output=True,text=True).stdout.splitlines()
  new,old=capture(a.candidate),capture(a.reference)
  same=new==old; mismatch |= not same
  print(f'{flag}: '+('identical' if same else 'DIFFERENT')+f' (candidate {len(new)} lines, reference {len(old)} lines)')
 sys.exit(1 if mismatch else 0)
except (OSError,subprocess.CalledProcessError) as e:
 print(f'failed: {e}',file=sys.stderr);sys.exit(2)
