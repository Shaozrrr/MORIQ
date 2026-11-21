#!/usr/bin/env python3
"""Build, sign and package locally. This tool never submits or publishes anything."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import ipaddress
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / 'MORIQ.xcodeproj'
ENTITLEMENTS = ROOT / 'MORIQ' / 'MORIQ.entitlements'

class ReleaseError(Exception): pass

def run(args, *, capture=False):
    try:
        p = subprocess.run([str(a) for a in args], check=True, text=True,
                           stdout=subprocess.PIPE if capture else None,
                           stderr=subprocess.PIPE if capture else None)
        return (p.stdout or '') + (p.stderr or '')
    except subprocess.CalledProcessError as e:
        raise ReleaseError(f'命令失败 ({e.returncode}): {args[0]}') from e
    except OSError as e:
        raise ReleaseError(f'无法执行 {args[0]}: {e.strerror}') from e

def identity_check(identity, runner=run):
    if not identity.startswith('Developer ID Application: '):
        raise ReleaseError('必须提供 Developer ID Application 证书名称，不能使用开发证书或 ad-hoc 签名。')
    listing = runner(['security', 'find-identity', '-v', '-p', 'codesigning'], capture=True)
    identities = re.findall(r'\"([^\"]+)\"', listing)
    if identity not in identities:
        raise ReleaseError('找不到匹配的有效 Developer ID Application 签名身份。')
    return identity

def safe_new_dir(raw):
    path = Path(raw).expanduser().absolute()
    if path.exists() or path.is_symlink(): raise ReleaseError(f'输出路径已存在：{path}')
    resolved = path.resolve()
    for forbidden in (Path('/Applications'), Path.home() / 'Applications', ROOT):
        if resolved == forbidden.resolve() or forbidden.resolve() in resolved.parents:
            raise ReleaseError('输出目录不能位于应用安装目录或项目源码目录。')
    path.mkdir(parents=True, exist_ok=False)
    return path

def assert_universal(app, runner=run):
    binary = app / 'Contents/MacOS/MORIQ'
    arches = set(runner(['lipo', '-archs', binary], capture=True).split())
    if not {'arm64', 'x86_64'} <= arches: raise ReleaseError(f'应用不是双架构：{sorted(arches)}')

def require_universal_binary(path, runner=run):
    arches = set(runner(['lipo', '-archs', path], capture=True).split())
    if not {'arm64', 'x86_64'} <= arches:
        raise ReleaseError(f'辅助程序不是双架构：{path} ({sorted(arches)})')

def require_system_dylibs(path, runner=run):
    output = runner(['otool', '-L', path], capture=True)
    libraries = []
    for line in output.splitlines():
        if line.startswith((' ', '\t')) and ' (compatibility version ' in line:
            libraries.append(line.strip().split(' (compatibility version ', 1)[0])
    if not libraries or any(not (item.startswith('/usr/lib/') or item.startswith('/System/Library/')) for item in libraries):
        raise ReleaseError(f'辅助程序含未核对的非系统动态依赖：{path}')

def require_speech_resources(res, minimum, runner=run):
    speech = res / 'SpeechEngine/moriq-speech'
    try:
        required = tuple(int(v) for v in minimum.split('.'))
        if not required: raise ValueError()
    except (AttributeError, ValueError):
        raise ReleaseError('应用缺少有效的最低系统版本。')
    for arch in ('arm64', 'x86_64'):
        output = runner(['otool', '-l', '-arch', arch, speech], capture=True)
        match = re.search(r'cmd LC_BUILD_VERSION\b(?:(?!\n\s*cmd ).)*?\bminos (\d+(?:\.\d+)*)', output, re.S)
        if not match or tuple(map(int, match.group(1).split('.'))) > required + (0,) * (3-len(required)):
            raise ReleaseError(f'字幕引擎 {arch} 最低系统版本不兼容：{minimum}')
    model = res / 'SpeechEngine/ggml-base.bin'
    license_file = res / 'SpeechEngine/LICENSE.whisper-model'
    if not model.is_file() or not license_file.is_file() or model.stat().st_size != 147951465:
        raise ReleaseError('缺少字幕模型或模型许可，或模型大小不正确。')
    with model.open('rb') as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''): digest.update(chunk)
        digest = digest.hexdigest()
    if digest != '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe':
        raise ReleaseError('字幕模型校验失败。')

def require_developer_signature(path, runner=run):
    runner(['codesign', '--verify', '--strict', path])
    desc = runner(['codesign', '-dv', '--verbose=4', path], capture=True)
    if 'Authority=Developer ID Application:' not in desc or 'runtime' not in desc or 'Timestamp=' not in desc:
        raise ReleaseError(f'嵌套组件缺少 Developer ID、加固运行时或可信时间戳：{path}')

def validate_endpoint(value, scheme, path):
    try:
        parsed = urlsplit(value)
        host = parsed.hostname
        port = parsed.port
        if parsed.scheme != scheme or not host or parsed.username is not None or parsed.password is not None or '?' in value or '#' in value or parsed.path != path:
            raise ValueError()
        if port is not None and not 1 <= port <= 65535: raise ValueError()
        try: ipaddress.ip_address(host)
        except ValueError: pass
        else: raise ValueError()
        labels = host.lower().split('.')
        if len(labels) < 2 or labels[-1] in ('local', 'localhost', 'test', 'invalid', 'example', 'internal') or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels): raise ValueError()
        if host.lower() in ('example.com', 'example.org', 'example.net') or host.lower().endswith(('.example.com', '.example.org', '.example.net')): raise ValueError()
        return value
    except (ValueError, UnicodeError):
        raise ReleaseError('服务地址须使用远端域名及指定的安全协议和路径，不能包含凭证、参数或测试地址。')

def validate_speech_endpoint(value):
    return validate_endpoint(value, 'wss', '/v1/speech/stream')

def validate_ai_endpoint(value):
    return validate_endpoint(value, 'https', '/v1/chat/completions')

def validate_activation_endpoint(value):
    return validate_endpoint(value, 'https', '/v1/devices/renew')

def build(out, speech_endpoint=None, caption_punct_available=False, ai_endpoint=None, full_featured=False, activation_endpoint=None, shared_leases=False, anonymous_device=False, native_only=False):
    if any(type(value) is not bool for value in (caption_punct_available, full_featured, shared_leases, anonymous_device, native_only)): raise ReleaseError('构建能力标记无效。')
    if native_only and caption_punct_available: raise ReleaseError('原生字幕模式不能启用依赖额外译文的增强字幕。')
    if anonymous_device and not shared_leases: raise ReleaseError('免注册接入需要共享会话和完整在线服务配置。')
    if shared_leases and not all((speech_endpoint,ai_endpoint,activation_endpoint)): raise ReleaseError('共享会话需要字幕、助手和设备激活服务地址。')
    if full_featured and (not shared_leases or not all((speech_endpoint, ai_endpoint, activation_endpoint))): raise ReleaseError('好友版完整功能构建需要字幕、助手、设备激活服务及共享会话。')
    if caption_punct_available and speech_endpoint is None: raise ReleaseError('启用增强字幕能力需要已核验的字幕服务地址。')
    if speech_endpoint is not None: validate_speech_endpoint(speech_endpoint)
    if ai_endpoint is not None: validate_ai_endpoint(ai_endpoint)
    if activation_endpoint is not None: validate_activation_endpoint(activation_endpoint)
    if shared_leases and len({(urlsplit(value).hostname,urlsplit(value).port or 443) for value in (speech_endpoint,ai_endpoint,activation_endpoint)}) != 1:
        raise ReleaseError('共享会话的三个服务必须使用同一主机和端口。')
    output = safe_new_dir(out)
    derived = output / 'derived'
    args = ['xcodebuild', '-project', PROJECT, '-scheme', 'MORIQ', '-configuration', 'Release',
         '-derivedDataPath', derived, 'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO',
         'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO']
    if speech_endpoint is not None:
        args.append('SWIFT_ACTIVE_COMPILATION_CONDITIONS=MORIQ_NATIVE_TRANSLATION_PRODUCT MORIQ_AUTO_TRANSLATION_PRODUCT')
    run(args + ['build'])
    app = derived / 'Build/Products/Release/MORIQ.app'
    if not app.is_dir(): raise ReleaseError('未找到构建产物。')
    assert_universal(app)
    if speech_endpoint is not None or ai_endpoint is not None or activation_endpoint is not None:
        info = app / 'Contents/Info.plist'
        with info.open('rb') as f: metadata = plistlib.load(f)
        if speech_endpoint is not None:
            metadata['MORIQManagedSpeechEndpoint'] = speech_endpoint
            metadata['MORIQNativeCaptionMode'] = 'batch-v1'
            if not native_only:
                metadata['MORIQCaptionAutomaticMode'] = 'trusted-v1'
            metadata['MORIQCaptionPunctAvailable'] = caption_punct_available
        if ai_endpoint is not None:
            metadata['MORIQManagedAIEndpoint'] = ai_endpoint
        if activation_endpoint is not None:
            metadata['MORIQDeviceActivationEndpoint'] = activation_endpoint
        if shared_leases:
            metadata['MORIQSharedSessionLeasesEnabled'] = True
        if anonymous_device:
            metadata['MORIQAnonymousDeviceEnabled'] = True
        with info.open('wb') as f: plistlib.dump(metadata, f, fmt=plistlib.FMT_XML, sort_keys=False)
    print('本地双架构未签名构建完成:', app)
    print('尚未签名、公证或发布。')

def sign(app_path, out, identity, version, build_number):
    identity_check(identity)
    if not re.fullmatch(r'\d+(?:\.\d+){1,2}', version) or not re.fullmatch(r'[1-9]\d*', build_number):
        raise ReleaseError('版本须为数字形式（如 1.2.0），构建号须为正整数。')
    source = Path(app_path).expanduser().resolve(strict=True)
    if source.name != 'MORIQ.app' or not source.is_dir(): raise ReleaseError('输入必须是 MORIQ.app 构建产物。')
    assert_universal(source)
    output = safe_new_dir(out)
    dest = output / 'MORIQ.app'
    run(['ditto', source, dest])
    info = dest / 'Contents/Info.plist'
    with info.open('rb') as f: metadata = plistlib.load(f)
    metadata['CFBundleShortVersionString'] = version; metadata['CFBundleVersion'] = build_number
    with info.open('wb') as f: plistlib.dump(metadata, f, fmt=plistlib.FMT_XML, sort_keys=False)
    res = dest / 'Contents/Resources'
    # FFmpeg is built by this project and currently ad-hoc signed. Other vendor
    # binaries retain their own signatures; do not use --deep as a signer.
    ffmpeg = res / 'ffmpeg'
    if not ffmpeg.is_file(): raise ReleaseError('缺少随包 FFmpeg。')
    speech = res / 'SpeechEngine/moriq-speech'
    license_file = res / 'SpeechEngine/LICENSE.whisper.cpp'
    source_file = res / 'SpeechEngine/main.cpp'
    if not speech.is_file() or not license_file.is_file() or not source_file.is_file():
        raise ReleaseError('缺少字幕引擎、许可或辅助程序源码。')
    require_universal_binary(speech)
    require_system_dylibs(speech)
    require_speech_resources(res, metadata.get('LSMinimumSystemVersion'))
    for helper in (ffmpeg, speech):
        run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', helper])
    required = [ffmpeg, speech,
        res/'Pandoc/pandoc-arm64', res/'Pandoc/pandoc-x86_64',
        res/'OfficeEngine/jre-arm64/bin/java', res/'OfficeEngine/jre-x86_64/bin/java',
        res/'OfficeSuite/LibreOffice-arm64.app', res/'OfficeSuite/LibreOffice-x86_64.app']
    for item in required:
        if not item.exists(): raise ReleaseError(f'缺少依赖：{item}')
        require_developer_signature(item)
    # Office bundles are shipped as resources. Verifying the outer app with
    # --deep does not reliably inspect their sealed nested Python frameworks.
    # A valid-looking Developer ID is insufficient when a sealed file is lost.
    for office in required[-2:]:
        run(['codesign', '--verify', '--deep', '--strict', office])
    run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp',
         '--entitlements', ENTITLEMENTS, dest])
    run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', dest])
    require_developer_signature(dest)
    assert_universal(dest)
    print('已生成本地签名候选:', dest)
    print('尚未公证或发布；仍需检查全部嵌套代码、许可及实际机器运行。')

def verify_packaged_app(app, arch):
    if arch is None:
        assert_universal(app)
    else:
        binary = app / 'Contents/MacOS/MORIQ'
        arches = run(['lipo', '-archs', binary], capture=True).split()
        if set(arches) != {arch}:
            raise ReleaseError(f'应用架构与安装包目标不一致：{arches}，预期 {arch}')
    require_developer_signature(app)
    run(['codesign', '--verify', '--deep', '--strict', app])

def package(app_path, out, identity, arch=None):
    identity_check(identity)
    app = Path(app_path).expanduser().resolve(strict=True)
    if app.name != 'MORIQ.app': raise ReleaseError('输入必须是签名后的 MORIQ.app。')
    verify_packaged_app(app, arch)
    ticket = app / 'Contents/CodeResources'
    stapled_ticket = ticket.read_bytes() if ticket.is_file() else None
    output = safe_new_dir(out)
    dmg_name = {'arm64': 'MORIQ-Apple.dmg', 'x86_64': 'MORIQ-Intel.dmg'}
    dmg = output / dmg_name.get(arch, 'MORIQ.dmg')
    settings = ROOT / 'Tools/Release/dmg_settings.py'
    assets = ROOT / 'Tools/Release/assets'
    run([sys.executable, '-m', 'dmgbuild', '-s', settings,
         '-D', f'app={app}', '-D', f'assets={assets}', 'MORIQ', dmg])
    # dmgbuild may not propagate a failed ditto copy. Inspect the image itself
    # before signing; a valid source app does not prove the mounted copy is complete.
    with tempfile.TemporaryDirectory(prefix='moriq-verify-', dir=output) as tmp:
        mount = Path(tmp) / 'volume'
        mount.mkdir()
        run(['hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', mount, dmg])
        try:
            mounted_app = mount / 'MORIQ.app'
            verify_packaged_app(mounted_app, arch)
            mounted_ticket = mounted_app / 'Contents/CodeResources'
            if stapled_ticket is not None and (not mounted_ticket.is_file() or mounted_ticket.read_bytes() != stapled_ticket):
                raise ReleaseError('安装镜像中的应用缺少原有公证票据。')
            if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
                raise ReleaseError('安装镜像缺少正确的应用程序快捷入口。')
        finally:
            run(['hdiutil', 'detach', mount])
    run(['codesign', '--sign', identity, '--timestamp', dmg])
    run(['codesign', '--verify', '--strict', dmg])
    print('已生成本地 DMG:', dmg)
    print('尚未公证、上传或发布。')

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('preflight'); p.add_argument('--identity', required=True)
    p = sub.add_parser('build'); p.add_argument('--out', required=True); p.add_argument('--speech-endpoint', help='已核验的远端字幕 WSS 地址'); p.add_argument('--caption-punct-available', action='store_true', help='在设置中提供增强字幕开关（仍默认关闭）'); p.add_argument('--ai-endpoint', help='已核验的远端 HTTPS 助手服务地址'); p.add_argument('--activation-endpoint', help='已核验的 HTTPS 设备续期服务地址'); p.add_argument('--shared-leases', action='store_true', help='显式启用经过联测的设备共享会话'); p.add_argument('--full-featured', action='store_true', help='要求好友版字幕、助手、设备激活及共享会话全部配置'); p.add_argument('--anonymous-device', action='store_true', help='启用免注册接入，须先验证服务端和防刷'); p.add_argument('--native-only', action='store_true', help='字幕使用原生实时翻译，不启用额外自动译文')
    p = sub.add_parser('sign'); p.add_argument('--app', required=True); p.add_argument('--out', required=True); p.add_argument('--identity', required=True); p.add_argument('--version', required=True); p.add_argument('--build-number', required=True)
    p = sub.add_parser('package'); p.add_argument('--app', required=True); p.add_argument('--out', required=True); p.add_argument('--identity', required=True)
    p.add_argument('--arch', choices=('arm64', 'x86_64'), help='打包已签名的单架构应用，默认要求双架构')
    a = parser.parse_args(argv)
    try:
        if a.command == 'preflight': identity_check(a.identity); print('找到有效证书；这不代表可公证或可发行。')
        elif a.command == 'build': build(a.out, a.speech_endpoint, a.caption_punct_available, a.ai_endpoint, a.full_featured, a.activation_endpoint, a.shared_leases, a.anonymous_device, a.native_only)
        elif a.command == 'sign': sign(a.app, a.out, a.identity, a.version, a.build_number)
        else: package(a.app, a.out, a.identity, a.arch)
    except (ReleaseError, FileNotFoundError, PermissionError, plistlib.InvalidFileException, OSError) as e:
        print(f'失败：{e}', file=sys.stderr); return 1
    return 0

if __name__ == '__main__': sys.exit(main())
