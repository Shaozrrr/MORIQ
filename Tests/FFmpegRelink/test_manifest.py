import pathlib,subprocess,sys,tempfile,unittest
root=pathlib.Path(__file__).resolve().parents[2]
script=root/'Tools/Release/create_ffmpeg_object_manifest.py'
class TestManifest(unittest.TestCase):
 def test_detects_changed_object_and_never_overwrites(self):
  with tempfile.TemporaryDirectory(prefix='moriq-manifest-test-') as d:
   p=pathlib.Path(d);(p/'COMPLETE').touch();(p/'metadata').mkdir();(p/'build').mkdir()
   obj=p/'build/test.o';obj.write_bytes(b'original');(p/'build/test.a').write_bytes(b'archive')
   r=subprocess.run([sys.executable,str(script),str(p)],capture_output=True,text=True);self.assertEqual(r.returncode,0,r.stderr)
   self.assertEqual(subprocess.run(['shasum','-a','256','-c','metadata/object-sha256.txt'],cwd=p,capture_output=True).returncode,0)
   obj.write_bytes(b'changed')
   self.assertNotEqual(subprocess.run(['shasum','-a','256','-c','metadata/object-sha256.txt'],cwd=p,capture_output=True).returncode,0)
   self.assertNotEqual(subprocess.run([sys.executable,str(script),str(p)],capture_output=True).returncode,0)
if __name__=='__main__':unittest.main()
