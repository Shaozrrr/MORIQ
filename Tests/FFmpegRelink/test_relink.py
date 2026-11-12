import pathlib, shutil, subprocess, sys, tempfile, unittest
root=pathlib.Path(__file__).resolve().parents[2]
class RelinkTests(unittest.TestCase):
 def test_relocation_and_no_overwrite(self):
  with tempfile.TemporaryDirectory(prefix='moriq-relink-test-') as d:
   p=pathlib.Path(d); shutil.copy(root/'Tools/Release/relink_ffmpeg_materials.py',p/'relink.py')
   (p/'metadata').mkdir();(p/'COMPLETE').touch();(p/'build/arm64/FFmpeg-n9.0.2').mkdir(parents=True)
   fake=p/'fake.py';fake.write_text('import pathlib,sys\na=sys.argv\npathlib.Path(a[a.index("-o")+1]).write_text(" ".join(a[1:]))\n')
   (p/'metadata/link-arm64.txt').write_text('printf ok; '+sys.executable+' '+str(fake)+' -L/old/path/local/lib -o ffmpeg_g\n')
   out=p/'result'; result=subprocess.run([sys.executable,str(p/'relink.py'),'arm64',str(out)],capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stderr)
   self.assertIn('-L'+str(p.resolve()/'build/arm64/local/lib'),out.read_text())
   override=p/'replacement';override.mkdir();out_override=p/'with-override'
   result=subprocess.run([sys.executable,str(p/'relink.py'),'arm64',str(out_override),'--override-lib-dir',str(override)],capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stderr)
   args=out_override.read_text();self.assertLess(args.index('-L'+str(override.resolve())),args.index('-L'+str(p.resolve()/'build/arm64/local/lib')))
   before=out.read_text();result=subprocess.run([sys.executable,str(p/'relink.py'),'arm64',str(out)],capture_output=True,text=True)
   self.assertNotEqual(result.returncode,0);self.assertEqual(out.read_text(),before)
   (p/'COMPLETE').unlink(); out2=p/'uncreated'
   result=subprocess.run([sys.executable,str(p/'relink.py'),'arm64',str(out2)],capture_output=True,text=True)
   self.assertNotEqual(result.returncode,0);self.assertFalse(out2.exists())
if __name__=='__main__':unittest.main()
