#!/usr/bin/env python3
"""Relink retained FFmpeg objects to a new output without modifying the package."""
import argparse
from pathlib import Path
import shlex
import subprocess
import sys

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('arch',choices=['arm64','x86_64']);p.add_argument('output',type=Path);p.add_argument('--override-lib-dir',type=Path);a=p.parse_args()
 root=Path(__file__).resolve().parent
 if not (root/'COMPLETE').is_file(): p.error('incomplete materials')
 out=a.output.expanduser().absolute()
 if out.exists() or out.is_symlink(): p.error('output already exists')
 if not out.parent.is_dir(): p.error('output parent does not exist')
 src=root/'build'/a.arch/'FFmpeg-n9.0.2'
 text=(root/'metadata'/f'link-{a.arch}.txt').read_text().strip()
 if '; ' not in text: p.error('unrecognized link recipe')
 argv=shlex.split(text.split('; ',1)[1])
 if '-o' not in argv: p.error('missing output option')
 argv[argv.index('-o')+1]=str(out)
 # The only build-specific absolute path expected in the link arguments is
 # the generated local static-library prefix. Rewrite it after relocation.
 old_prefixes=[v[2:-len('/local/lib')] for v in argv if v.startswith('-L/') and v.endswith('/local/lib')]
 if len(set(old_prefixes)) != 1: p.error('unexpected local library search paths')
 old=old_prefixes[0]; new=str(root/'build'/a.arch)
 argv=[v.replace(old,new) for v in argv]
 if a.override_lib_dir is not None:
  override=a.override_lib_dir.expanduser().resolve()
  if not override.is_dir(): p.error('override library directory does not exist')
  # Search replacement libraries before the retained original dependencies.
  index=next(i for i,v in enumerate(argv) if v.startswith('-L') and v.endswith('/local/lib'))
  argv.insert(index, '-L'+str(override))
 try: subprocess.run(argv,cwd=src,check=True)
 except (OSError,subprocess.CalledProcessError) as e:
  print(f'relink failed: {e}',file=sys.stderr); return 1
 print(f'Relinked {a.arch} to {out}; source materials were not modified.')
 return 0
if __name__=='__main__':sys.exit(main())
