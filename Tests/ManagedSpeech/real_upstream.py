"""Opt-in live provider smoke test with a synthetic, non-user audio file.

The operator must explicitly supply a synthetic 16 kHz mono PCM16 WAV and
request --run. The provider credential is read once from macOS Keychain into
memory only; neither the credential nor recorded user audio is logged/stored.
This is a limited live test, not a production deployment or quality benchmark.
"""
import argparse
import asyncio
import hashlib
import json
import pathlib
import secrets
import subprocess
import sys
import tempfile
import wave

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Services/ManagedAI'))
from speech_gateway import SpeechGateway

def provider_key():
    result = subprocess.run(
        ['/usr/bin/security', 'find-generic-password', '-s', 'local.moriq.volcengine.speech', '-a', 'MORIQ', '-w'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode != 0: raise RuntimeError('语音服务凭据不可用或未获钥匙串授权')
    key = result.stdout.decode('utf-8').strip()
    if not key: raise RuntimeError('语音服务凭据为空')
    return key

async def main(path, show_events=False, swift_client=None):
    with wave.open(str(path), 'rb') as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError('需要 16 kHz 单声道 PCM16 WAV')
        if not 1 <= audio.getnframes() <= 16000 * 30: raise ValueError('样本时长须在 30 秒内')
        pcm = audio.readframes(audio.getnframes())
    token = secrets.token_urlsafe(32)
    gateway = SpeechGateway(provider_key(), [hashlib.sha256(token.encode('ascii')).hexdigest()])
    source, translation, order = [], [], []
    async with serve(gateway.handle, '127.0.0.1', 0, compression=None) as server:
        port = server.sockets[0].getsockname()[1]
        if swift_client:
            with tempfile.TemporaryDirectory(prefix='moriq-synthetic-speech-') as tmp:
                audio_path = pathlib.Path(tmp) / 'synthetic.pcm'
                audio_path.write_bytes(pcm)
                child = await asyncio.create_subprocess_exec(str(swift_client), f'ws://127.0.0.1:{port}/v1/speech/stream', token, str(audio_path), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                try: out, _ = await asyncio.wait_for(child.communicate(), 60)
                except BaseException:
                    child.kill(); await child.wait(); raise
                if child.returncode != 0: raise RuntimeError('Swift live client failed')
                print(out.decode('utf-8').strip())
                return
        async with connect(f'ws://127.0.0.1:{port}/v1/speech/stream', additional_headers={'Authorization': 'Bearer ' + token}, proxy=None) as ws:
            await ws.send(json.dumps({'type': 'start', 'source': 'en', 'target': 'zh'}))
            first = json.loads(await asyncio.wait_for(ws.recv(), 20))
            if first.get('type') != 'ready': raise RuntimeError('上游未建立会话，请检查服务权限与网络')
            async def send_audio():
                for offset in range(0, len(pcm), 2560):
                    await ws.send(pcm[offset:offset+2560]); await asyncio.sleep(0.08)
                await ws.send('{"type":"finish"}')
            task = asyncio.create_task(send_audio())
            try:
                async def receive_events():
                    async for raw in ws:
                        event = json.loads(raw)
                        if event.get('type') in ('source', 'translation'):
                            order.append((event['type'], event.get('segment'), event.get('final'), event.get('text')))
                        if event.get('type') == 'error': raise RuntimeError('上游语音服务返回错误')
                        if event.get('type') == 'source' and event.get('text'): source.append((event['text'], event.get('final')))
                        if event.get('type') == 'translation' and event.get('text'): translation.append((event['text'], event.get('final')))
                        if event.get('type') == 'finished': break
                await asyncio.wait_for(receive_events(), 60)
                await task
            finally:
                task.cancel(); await asyncio.gather(task, return_exceptions=True)
    if not source or not translation: raise RuntimeError('上游没有同时返回原文和译文')
    print('PASS live provider source events:', len(source), 'translation events:', len(translation))
    print('SOURCE:', ' | '.join(text for text, final in source if final) or source[-1][0])
    print('TRANSLATION:', ' | '.join(text for text, final in translation if final) or translation[-1][0])
    if show_events:
        print('SOURCE_EVENTS:', json.dumps(source, ensure_ascii=False))
        print('TRANSLATION_EVENTS:', json.dumps(translation, ensure_ascii=False))
        print('EVENT_ORDER:', json.dumps(order, ensure_ascii=False))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', action='store_true', help='explicitly allow synthetic audio to be sent to the provider')
    parser.add_argument('--show-synthetic-events', action='store_true', help='print text events from the synthetic sample for protocol evaluation')
    parser.add_argument('--swift-client', type=pathlib.Path, help='exercise a compiled synthetic Swift client end to end')
    parser.add_argument('synthetic_wav', type=pathlib.Path)
    args = parser.parse_args()
    if not args.run: parser.error('pass --run to explicitly perform a real provider request')
    try: asyncio.run(main(args.synthetic_wav, args.show_synthetic_events, args.swift_client))
    except Exception as exc:
        # Do not print exception repr: lower-level network/credential errors
        # could contain request headers or a provider credential.
        print('FAIL live provider smoke test:', type(exc).__name__, file=sys.stderr)
        sys.exit(1)
