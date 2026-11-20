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
    if '-m' in args and 'dmgbuild' in args: Path(args[-1]).write_bytes(b'fixture')
    if cmd=='hdiutil' and 'attach' in args:
     (Path(args[args.index('-mountpoint')+1])/'Applications').symlink_to('/Applications')
    return ''
   with patch.object(m,'run',fake), patch.object(m,'identity_check'), patch.object(m,'assert_universal'), patch.object(m,'require_universal_binary'), patch.object(m,'require_system_dylibs'), patch.object(m,'require_speech_resources'), patch.object(m,'require_developer_signature'):
    m.sign(str(source),str(root/'signed'),IDENTITY,'1.2.0','42')
    signed=root/'signed/MORIQ.app'
    with (signed/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
    self.assertEqual((info['CFBundleShortVersionString'],info['CFBundleVersion']),('1.2.0','42'))
    m.package(str(signed),str(root/'dmg'),IDENTITY)
   self.assertTrue((root/'dmg/MORIQ.dmg').exists())
   mounted_verify=next(i for i,c in enumerate(calls) if c[0]=='codesign' and '--verify' in c and c[-1].endswith('/volume/MORIQ.app'))
   image_sign=next(i for i,c in enumerate(calls) if c[0]=='codesign' and '--sign' in c and c[-1].endswith('/dmg/MORIQ.dmg'))
   self.assertLess(mounted_verify,image_sign)
   self.assertFalse(any('notarytool' in ' '.join(c) or 'submit' in c or 'upload' in c for c in calls))
   signs=[c for c in calls if c[0]=='codesign' and '--sign' in c]
   self.assertTrue(signs)
   self.assertTrue(any(c[-1].endswith('/SpeechEngine/moriq-speech') for c in signs))
   for arch in ('arm64','x86_64'):
    self.assertTrue(any(c[0]=='codesign' and '--verify' in c and '--deep' in c and c[-1].endswith(f'/OfficeSuite/LibreOffice-{arch}.app') for c in calls))
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

 def test_explicit_speech_configuration_and_invalid_endpoints(self):
  good='wss://captions.moriq.examplehost.com/v1/speech/stream'
  self.assertEqual(m.validate_speech_endpoint(good),good)
  for bad in ['ws://captions.examplehost.com/v1/speech/stream','wss://127.0.0.1/v1/speech/stream','wss://localhost/v1/speech/stream','wss://device.local/v1/speech/stream','wss://example.com/v1/speech/stream','wss://host.examplehost.com/v1/speech/stream?token=secret','wss://token@host.examplehost.com/v1/speech/stream','wss://host.examplehost.com/v1/speech/stream#x','wss://host.examplehost.com/token']:
   with self.subTest(bad=bad), self.assertRaises(m.ReleaseError): m.validate_speech_endpoint(bad)
  with tempfile.TemporaryDirectory(prefix='moriq-release-speech-') as d:
   out=Path(d)/'build'; calls=[]
   def fake(args,capture=False):
    calls.append([str(x) for x in args]); contents=out/'derived/Build/Products/Release/MORIQ.app/Contents'; contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f: plistlib.dump({'CFBundleIdentifier':'local.moriq.app'},f)
    return ''
   with patch.object(m,'run',fake), patch.object(m,'assert_universal'): m.build(str(out),good)
   self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS=MORIQ_NATIVE_TRANSLATION_PRODUCT MORIQ_AUTO_TRANSLATION_PRODUCT',calls[0])
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
   self.assertEqual(info['MORIQManagedSpeechEndpoint'],good)
   self.assertEqual(info['MORIQNativeCaptionMode'],'batch-v1')
   self.assertEqual(info['MORIQCaptionAutomaticMode'],'trusted-v1')
   self.assertIs(info['MORIQCaptionPunctAvailable'],False)
   self.assertEqual(info['CFBundleIdentifier'],'local.moriq.app')
   self.assertFalse(any('token' in k.lower() for k in info))

 def test_ai_endpoint_is_explicit_and_never_contains_credentials(self):
  good='https://assistant.moriq.examplehost.com/v1/chat/completions'
  self.assertEqual(m.validate_ai_endpoint(good),good)
  for bad in ('http://assistant.examplehost.com/v1/chat/completions','https://127.0.0.1/v1/chat/completions','https://localhost/v1/chat/completions','https://example.com/v1/chat/completions','https://x.examplehost.com/v1/chat/completions?key=secret','https://user@x.examplehost.com/v1/chat/completions','https://x.examplehost.com/other'):
   with self.subTest(bad=bad), self.assertRaises(m.ReleaseError):m.validate_ai_endpoint(bad)
  with tempfile.TemporaryDirectory(prefix='moriq-release-ai-') as d:
   out=Path(d)/'build'
   def fake(args,capture=False):
    contents=out/'derived/Build/Products/Release/MORIQ.app/Contents';contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({},f)
    return ''
   with patch.object(m,'run',fake),patch.object(m,'assert_universal'):m.build(str(out),ai_endpoint=good)
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
   self.assertEqual(info['MORIQManagedAIEndpoint'],good)
   self.assertNotIn('MORIQManagedSpeechEndpoint',info)
   self.assertFalse(any('token' in k.lower() for k in info))

 def test_full_featured_requires_both_endpoints_before_creating_output(self):
  with tempfile.TemporaryDirectory(prefix='moriq-release-full-') as d:
   for i,(speech,ai) in enumerate(((None,None),('wss://captions.moriq.examplehost.com/v1/speech/stream',None),(None,'https://assistant.moriq.examplehost.com/v1/chat/completions'))):
    out=Path(d)/str(i)
    with self.assertRaises(m.ReleaseError):m.build(str(out),speech_endpoint=speech,ai_endpoint=ai,full_featured=True)
    self.assertFalse(out.exists())

 def test_friend_release_rejects_missing_activation_or_shared_leases(self):
  speech='wss://service.moriq.examplehost.com/v1/speech/stream'
  ai='https://service.moriq.examplehost.com/v1/chat/completions'
  activation='https://service.moriq.examplehost.com/v1/devices/renew'
  with tempfile.TemporaryDirectory(prefix='moriq-release-friend-') as d:
   for i,(endpoint,leases) in enumerate(((None,False),(None,True),(activation,False))):
    out=Path(d)/str(i)
    with self.assertRaises(m.ReleaseError):m.build(str(out),speech_endpoint=speech,ai_endpoint=ai,activation_endpoint=endpoint,shared_leases=leases,full_featured=True)
    self.assertFalse(out.exists())
   out=Path(d)/'complete'
   def fake(args,capture=False):
    contents=out/'derived/Build/Products/Release/MORIQ.app/Contents';contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({},f)
    return ''
   with patch.object(m,'run',fake),patch.object(m,'assert_universal'):m.build(str(out),speech_endpoint=speech,ai_endpoint=ai,activation_endpoint=activation,shared_leases=True,full_featured=True)
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
   self.assertIs(info['MORIQSharedSessionLeasesEnabled'],True)
   self.assertEqual(info['MORIQDeviceActivationEndpoint'],activation)

 def test_activation_endpoint_requires_secure_remote_exact_path(self):
  good='https://service.moriq.examplehost.com/v1/devices/renew'
  self.assertEqual(m.validate_activation_endpoint(good),good)
  for bad in ('http://service.moriq.examplehost.com/v1/devices/renew','https://127.0.0.1/v1/devices/renew','https://service.moriq.examplehost.com/v1/devices/renew?token=x','https://service.moriq.examplehost.com/v1/devices/activate'):
   with self.subTest(bad=bad), self.assertRaises(m.ReleaseError):m.validate_activation_endpoint(bad)
  with tempfile.TemporaryDirectory(prefix='moriq-release-device-') as d:
   out=Path(d)/'build'
   def fake(args,capture=False):
    contents=out/'derived/Build/Products/Release/MORIQ.app/Contents';contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({},f)
    return ''
   with patch.object(m,'run',fake),patch.object(m,'assert_universal'):m.build(str(out),activation_endpoint=good)
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
   self.assertEqual(info['MORIQDeviceActivationEndpoint'],good)
   self.assertNotIn('MORIQSharedSessionLeasesEnabled',info)

 def test_shared_leases_require_one_origin_and_all_endpoints(self):
  speech='wss://service.moriq.examplehost.com/v1/speech/stream'
  ai='https://service.moriq.examplehost.com/v1/chat/completions'
  activation='https://service.moriq.examplehost.com/v1/devices/renew'
  with tempfile.TemporaryDirectory(prefix='moriq-release-shared-') as d:
   with self.assertRaises(m.ReleaseError):m.build(str(Path(d)/'missing'),speech_endpoint=speech,shared_leases=True)
   with self.assertRaises(m.ReleaseError):m.build(str(Path(d)/'mismatch'),speech_endpoint=speech,ai_endpoint=ai,activation_endpoint=activation.replace('service.','other.'),shared_leases=True)
   out=Path(d)/'build'
   def fake(args,capture=False):
    contents=out/'derived/Build/Products/Release/MORIQ.app/Contents';contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({},f)
    return ''
   with patch.object(m,'run',fake),patch.object(m,'assert_universal'):m.build(str(out),speech_endpoint=speech,ai_endpoint=ai,activation_endpoint=activation,shared_leases=True)
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
   self.assertIs(info['MORIQSharedSessionLeasesEnabled'],True)

 def test_anonymous_build_requires_shared_service_and_is_opt_in(self):
  speech='wss://service.moriq.examplehost.com/v1/speech/stream'
  ai='https://service.moriq.examplehost.com/v1/chat/completions'
  activation='https://service.moriq.examplehost.com/v1/devices/renew'
  with tempfile.TemporaryDirectory(prefix='moriq-release-anonymous-') as d:
   with self.assertRaises(m.ReleaseError):m.build(str(Path(d)/'invalid'),anonymous_device=True)
   out=Path(d)/'build'
   def fake(args,capture=False):
    contents=out/'derived/Build/Products/Release/MORIQ.app/Contents';contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({},f)
    return ''
   with patch.object(m,'run',fake),patch.object(m,'assert_universal'):
    m.build(str(out),speech_endpoint=speech,ai_endpoint=ai,activation_endpoint=activation,shared_leases=True,anonymous_device=True)
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
   self.assertIs(info['MORIQAnonymousDeviceEnabled'],True)

 def test_punct_build_is_explicit_and_requires_endpoint(self):
  good='wss://captions.moriq.examplehost.com/v1/speech/stream'
  with tempfile.TemporaryDirectory(prefix='moriq-release-punct-') as d:
   out=Path(d)/'missing'
   with self.assertRaises(m.ReleaseError):m.build(str(out),caption_punct_available=True)
   self.assertFalse(out.exists())
   out=Path(d)/'explicit'
   def fake(args,capture=False):
    contents=out/'derived/Build/Products/Release/MORIQ.app/Contents';contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({},f)
    return ''
   with patch.object(m,'run',fake),patch.object(m,'assert_universal'):m.build(str(out),good,True)
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
   self.assertIs(info['MORIQCaptionPunctAvailable'],True)
   self.assertEqual(info['MORIQCaptionAutomaticMode'],'trusted-v1')

 def test_native_only_disables_automatic_translation(self):
  speech='wss://service.moriq.examplehost.com/v1/speech/stream'
  with tempfile.TemporaryDirectory(prefix='moriq-release-native-') as d:
   out=Path(d)/'build'
   def fake(args,capture=False):
    contents=out/'derived/Build/Products/Release/MORIQ.app/Contents';contents.mkdir(parents=True)
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({},f)
    return ''
   with patch.object(m,'run',fake),patch.object(m,'assert_universal'):
    m.build(str(out),speech_endpoint=speech,native_only=True)
   with (out/'derived/Build/Products/Release/MORIQ.app/Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
   self.assertEqual(info['MORIQNativeCaptionMode'],'batch-v1')
   self.assertNotIn('MORIQCaptionAutomaticMode',info)
   with self.assertRaises(m.ReleaseError):
    m.build(str(Path(d)/'invalid'),speech_endpoint=speech,native_only=True,caption_punct_available=True)

if __name__=='__main__': unittest.main()
