#!/usr/bin/env python3
"""Record retained object/static-library hashes for accidental corruption checks."""
import argparse, hashlib
from pathlib import Path

def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);root=p.parse_args().root.resolve()
 if not (root/'COMPLETE').is_file() or (root/'INCOMPLETE').exists(): p.error('materials are incomplete')
 output=root/'metadata/object-sha256.txt'
 if output.exists(): p.error('manifest exists; refusing to overwrite')
 files=sorted(x for x in (root/'build').rglob('*') if x.is_file() and x.suffix in ('.o','.a'))
 if not files: p.error('no retained object files or static libraries')
 with output.open('x',encoding='utf-8') as f:
  for path in files:
   name=path.relative_to(root).as_posix()
   if '\n' in name or '\r' in name: p.error('invalid filename')
   f.write(f'{digest(path)}  {name}\n')
 print(f'Recorded {len(files)} object/static-library hashes in {output}')
if __name__=='__main__':main()
