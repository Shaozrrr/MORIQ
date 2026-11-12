#!/usr/bin/env python3
"""Test replacing the retained libogg with a modified build in a temp directory."""
import argparse, os, pathlib, shutil, subprocess, sys, tempfile

def run(args, **kw):
 return subprocess.run([str(x) for x in args],check=True,capture_output=True,text=True,**kw).stdout

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);root=p.parse_args().root.expanduser().resolve()
 if not (root/'COMPLETE').is_file() or (root/'INCOMPLETE').exists(): p.error('materials are incomplete')
 try:
  with tempfile.TemporaryDirectory(prefix='moriq-ogg-relink-verify-') as tmp:
   tmp=pathlib.Path(tmp)
   for arch in ('arm64','x86_64'):
    source=root/'build'/arch/'libogg-1.3.6'; copy=tmp/f'ogg-{arch}'
    shutil.copytree(source,copy,symlinks=True)
    cfile=copy/'src/bitwise.c'
    with cfile.open('a') as f:f.write('\n/* Isolated relink verification marker. */\nconst char moriq_relink_marker[] = "MORIQ_RELINK_TEST_MARKER";\n')
    os.utime(cfile,None)
    run(['make','-j2'],cwd=copy)
    override=tmp/f'override-{arch}';override.mkdir()
    shutil.copy2(copy/'src/.libs/libogg.a',override/'libogg.a')
    output=tmp/f'ffmpeg-{arch}'
    run([sys.executable,root/'relink.py',arch,output,'--override-lib-dir',override])
    symbols=run(['nm','-g',output])
    if '_moriq_relink_marker' not in symbols:raise ValueError(f'{arch}: replacement marker not linked')
    version=run(['/usr/bin/arch','-'+arch,output,'-version'])
    if 'ffmpeg version 9.0.2' not in version:raise ValueError(f'{arch}: executable did not run')
    print(f'PASS {arch} modified libogg linked and executable ran',flush=True)
 except (OSError,subprocess.CalledProcessError,ValueError) as e:
  print(f'FAIL {e}',file=sys.stderr)
  if isinstance(e,subprocess.CalledProcessError) and e.stderr:print(e.stderr[-1800:],file=sys.stderr)
  return 1
 print('This test does not prove legal compliance, all modified libraries, or Intel hardware behavior.')
 return 0
if __name__=='__main__':sys.exit(main())
