#!/usr/bin/env python3
"""Validate source hashes and relink/run both retained FFmpeg architectures."""
import argparse, hashlib, pathlib, subprocess, sys, tempfile

def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
 return h.hexdigest()

def run(args, **kw):
 return subprocess.run([str(x) for x in args],check=True,capture_output=True,text=True,**kw).stdout

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args();root=a.root.expanduser().resolve()
 if not (root/'COMPLETE').is_file() or (root/'INCOMPLETE').exists(): p.error('materials are incomplete')
 try:
  run(['shasum','-a','256','-c','metadata/source-sha256.txt'],cwd=root)
  run(['shasum','-a','256','-c','metadata/object-sha256.txt'],cwd=root)
  expected=(root/'metadata/candidate-sha256.txt').read_text().split()[0]
  if digest(root/'ffmpeg') != expected: raise ValueError('candidate hash differs')
  print('PASS source archives, object/static-library manifest and candidate hash',flush=True)
  with tempfile.TemporaryDirectory(prefix='moriq-ffmpeg-relink-verify-') as temp:
   temp=pathlib.Path(temp); ppm=temp/'input.ppm'; ppm.write_bytes(b'P6\n2 2\n255\n'+bytes([255,0,0,0,255,0,0,0,255,255,255,255]))
   for arch in ('arm64','x86_64'):
    binary=temp/f'ffmpeg-{arch}'; run([sys.executable,root/'relink.py',arch,binary])
    report=run(['/usr/bin/arch','-'+arch,binary,'-version'])
    if 'ffmpeg version 9.0.2' not in report or '--disable-gpl' not in report or '--disable-nonfree' not in report:
     raise ValueError(f'{arch} version or configure flags differ')
    png=temp/f'{arch}.png';run(['/usr/bin/arch','-'+arch,binary,'-nostdin','-v','error','-i',ppm,'-frames:v','1',png])
    if not png.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):raise ValueError(f'{arch} output is not PNG')
    original=root/'build'/arch/'FFmpeg-n9.0.2/ffmpeg_g'
    comparison='identical' if digest(binary)==digest(original) else 'different bytes'
    print(f'PASS {arch} retained-object relink and PNG conversion; ffmpeg_g comparison: {comparison}',flush=True)
 except (OSError,subprocess.CalledProcessError,ValueError,IndexError) as e:
  print(f'FAIL {e}',file=sys.stderr)
  if isinstance(e,subprocess.CalledProcessError) and e.stderr: print(e.stderr[-1800:],file=sys.stderr)
  return 1
 print('This does not establish legal compliance, all codecs, Intel hardware behavior, or notarization.')
 return 0
if __name__=='__main__':sys.exit(main())
