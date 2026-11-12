import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_tool', ROOT/'Tools/Release/moriq_release.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
IDENTITY = 'Developer ID Application: Fixture (TESTONLY)'

class ReleaseTests(unittest.TestCase):
 def test_identity_is_exact_and_not_development(self):
  fake = lambda args, capture=False: '  1) HASH "Developer ID Application: Fixture (TESTONLY)"\n'
  self.assertEqual(m.identity_check(IDENTITY, fake), IDENTITY)
  for identity in ['Apple Development: Fixture', '-', 'Developer ID Application: Other']:
   with self.assertRaises(m.ReleaseError): m.identity_check(identity, fake)
 def test_binary_architecture_and_vendor_signature_gates(self):
  m.assert_universal(Path('/fixture'), lambda *a, **k: 'arm64 x86_64')
  with self.assertRaises(m.ReleaseError): m.assert_universal(Path('/fixture'), lambda *a, **k: 'arm64')
  good = 'Authority=Developer ID Application: Test\nflags=0x10000(runtime)\nTimestamp=2026-01-01\n'
  m.require_developer_signature(Path('/fixture'), lambda *a, **k: good)
  with self.assertRaises(m.ReleaseError): m.require_developer_signature(Path('/fixture'), lambda *a, **k: 'Authority=Apple Development: Test\n')
 def test_helper_dylib_gate(self):
  good='helper (architecture arm64):\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
  m.require_system_dylibs(Path('/fixture'),lambda *a,**k:good)
  for bad in ['', 'helper:\n\t/opt/homebrew/lib/libforeign.dylib (compatibility version 1, current version 1)\n', 'helper:\n\t@rpath/libforeign.dylib (compatibility version 1, current version 1)\n']:
   with self.assertRaises(m.ReleaseError): m.require_system_dylibs(Path('/fixture'),lambda *a,**k:bad)
  m.require_universal_binary(Path('/fixture'),lambda *a,**k:'arm64 x86_64')
  with self.assertRaises(m.ReleaseError): m.require_universal_binary(Path('/fixture'),lambda *a,**k:'arm64')
 def test_speech_minimum_and_model_gate(self):
  with tempfile.TemporaryDirectory(prefix='moriq-speech-gate-') as d:
   res=Path(d); engine=res/'SpeechEngine'; engine.mkdir()
   (engine/'moriq-speech').write_bytes(b'fixture')
   (engine/'LICENSE.whisper-model').write_text('fixture')
   (engine/'ggml-base.bin').write_bytes(b'fixture')
   def too_new(args,capture=False): return 'cmd LC_BUILD_VERSION\n minos 27.0\n'
   with self.assertRaises(m.ReleaseError): m.require_speech_resources(res,'15.0',too_new)
   def valid(args,capture=False): return 'cmd LC_BUILD_VERSION\n minos 15.0\n'
   with self.assertRaises(m.ReleaseError): m.require_speech_resources(res,'15.0',valid)
   with self.assertRaises(m.ReleaseError): m.require_speech_resources(res,None,valid)
 def test_existing_or_install_output_is_not_overwritten(self):
  with tempfile.TemporaryDirectory(prefix='moriq-release-test-') as d:
   with self.assertRaises(m.ReleaseError): m.safe_new_dir(d)
   with self.assertRaises(m.ReleaseError): m.safe_new_dir('/Applications/MORIQ-RELEASE-TEST-NEVER-CREATE')
   with self.assertRaises(m.ReleaseError): m.safe_new_dir(str(ROOT/'fixture-never-create'))
 def test_local_flow_uses_fake_tools_and_never_uploads(self):
  with tempfile.TemporaryDirectory(prefix='moriq-release-test-') as d:
   root = Path(d); source = root/'input/MORIQ.app'; contents = source/'Contents'; res = contents/'Resources'
   (contents/'MacOS').mkdir(parents=True)
   (contents/'MacOS/MORIQ').write_text('fixture')
   with (contents/'Info.plist').open('wb') as f: plistlib.dump({'CFBundleVersion':'1'}, f)
   for rel in ['ffmpeg','SpeechEngine/moriq-speech','SpeechEngine/LICENSE.whisper.cpp','SpeechEngine/main.cpp','Pandoc/pandoc-arm64','Pandoc/pandoc-x86_64','OfficeEngine/jre-arm64/bin/java','OfficeEngine/jre-x86_64/bin/java','OfficeSuite/LibreOffice-arm64.app/Contents/Info.plist','OfficeSuite/LibreOffice-x86_64.app/Contents/Info.plist']:
    p=res/rel; p.parent.mkdir(parents=True,exist_ok=True); p.write_text('fixture')
   original_info = (contents/'Info.plist').read_bytes()
   calls=[]
   def fake(args, capture=False):
    calls.append([str(x) for x in args]); cmd=str(args[0])
    if cmd=='ditto': shutil.copytree(args[1],args[2])
    if cmd=='hdiutil': Path(args[-1]).write_bytes(b'fixture')
    return ''
   with patch.object(m,'run',fake), patch.object(m,'identity_check'), patch.object(m,'assert_universal'), patch.object(m,'require_universal_binary'), patch.object(m,'require_system_dylibs'), patch.object(m,'require_speech_resources'), patch.object(m,'require_developer_signature'):
    m.sign(str(source),str(root/'signed'),IDENTITY,'1.2.0','42')
    signed=root/'signed/MORIQ.app'
    with (signed/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
    self.assertEqual((info['CFBundleShortVersionString'],info['CFBundleVersion']),('1.2.0','42'))
    m.package(str(signed),str(root/'dmg'),IDENTITY)
   self.assertTrue((root/'dmg/MORIQ.dmg').exists())
   self.assertFalse(any('notarytool' in ' '.join(c) or 'submit' in c or 'upload' in c for c in calls))
   signs=[c for c in calls if c[0]=='codesign' and '--sign' in c]
   self.assertTrue(signs)
   self.assertTrue(any(c[-1].endswith('/SpeechEngine/moriq-speech') for c in signs))
   self.assertTrue(all('--deep' not in c and '--timestamp' in c for c in signs))
   self.assertEqual((contents/'Info.plist').read_bytes(), original_info)
 def test_build_uses_both_architectures_without_signing(self):
  with tempfile.TemporaryDirectory(prefix='moriq-release-test-') as d:
   out=Path(d)/'build'; calls=[]
   def fake(args, capture=False):
    calls.append([str(x) for x in args])
    app=out/'derived/Build/Products/Release/MORIQ.app'; app.mkdir(parents=True)
    return ''
   with patch.object(m,'run',fake), patch.object(m,'assert_universal'):
    m.build(str(out))
   command=calls[0]
   self.assertIn('ARCHS=arm64 x86_64',command)
   self.assertIn('ONLY_ACTIVE_ARCH=NO',command)
   self.assertIn('CODE_SIGNING_ALLOWED=NO',command)
   self.assertFalse(any('notarytool' in ' '.join(c) for c in calls))
 def test_version_rejected_before_output(self):
  with tempfile.TemporaryDirectory(prefix='moriq-release-test-') as d:
   out=Path(d)/'out'
   with patch.object(m,'identity_check'):
    with self.assertRaises(m.ReleaseError): m.sign('/not-used',str(out),IDENTITY,'1;bad','1')
   self.assertFalse(out.exists())

if __name__=='__main__': unittest.main()
