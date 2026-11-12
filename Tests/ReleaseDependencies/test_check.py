import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('bundlecheck',root/'Tools/Release/check_bundle_dependencies.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Tests(unittest.TestCase):
 def test_checks_fixture_and_detects_absence_corruption_and_arch(self):
  with tempfile.TemporaryDirectory(prefix='moriq-dependency-test-') as d:
   app=Path(d)/'MORIQ.app'
   for name in list(m.BINARIES)+m.FILES:
    p=app/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture')
    if name in m.BINARIES: p.chmod(0o755)
   for name in m.JARS:
    p=app/name;p.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(p,'w') as z:z.writestr('fixture','ok')
   with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump({'CFBundleIdentifier':'fixture','CFBundleVersion':'1','LSMinimumSystemVersion':'15'},f)
   def arches(p): return m.BINARIES[str(p.relative_to(app))]
   errors=m.check(app,arches,lambda p,a:(15,0))
   self.assertEqual(len(errors),1)
   self.assertIn('字幕模型',errors[0])
   self.assertTrue(any('最低系统版本' in x for x in m.check(app,arches,lambda p,a:(27,0))))
   (app/m.FILES[0]).unlink()
   (app/m.JARS[0]).write_text('bad zip')
   def missing_arm(p): return {'arm64'}
   errors=m.check(app,missing_arm,lambda p,a:(15,0))
   self.assertTrue(any('资源' in x for x in errors))
   self.assertTrue(any('JAR' in x for x in errors))
   self.assertTrue(any('架构' in x for x in errors))
   with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(['not a dictionary'],f)
   self.assertTrue(any('Info.plist' in x for x in m.check(app,arches,lambda p,a:(15,0))))
if __name__=='__main__':unittest.main()
