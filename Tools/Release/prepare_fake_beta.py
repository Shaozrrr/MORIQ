"""Prepare an allowlisted, synthetic-only Railway source tree; never upload."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT=Path(__file__).resolve().parents[2]
SERVICE=ROOT/'Services'/'ManagedAI'
FILES=(
 'account_store.py','asr_gateway.py','audio_timeline.py','caption_auto_translation.py',
 'caption_memory_ledger.py','caption_source_collector.py','caption_source_collector_v2.py',
 'deepgram_gateway.py','deepl_experiment.py','deepl_https_transport.py','deepseek_translation.py',
 'soniox_gateway.py','soniox_native_translation.py','speech_gateway.py','unanchored_preview.py',
 'deploy/railway_config.py','deploy/start_railway_fake.py','deploy/requirements.txt',
 'deploy/RAILWAY_FAKE_BETA.md','Dockerfile.fake','.dockerignore')
PATTERNS={
 'private_key':re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
 'api_key':re.compile(r'\bsk-[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b'),
 'home_path':re.compile(r'/Users/[^/\s]+'),
 'email':re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
}

def prepare(destination):
    dest=Path(destination)
    if not dest.is_absolute() or dest.exists():raise ValueError('new absolute destination required')
    # Validate the exact allowlist before creating anything. Report file names,
    # never the matching material. This targeted scan is not a secret audit.
    content={}
    for relative in FILES:
        path=SERVICE/relative
        if path.is_symlink() or not path.is_file():raise ValueError('invalid input: '+relative)
        data=path.read_bytes()
        text=data.decode('utf-8')
        if path.suffix=='.py':ast.parse(text,filename=relative)
        for label,pattern in PATTERNS.items():
            if pattern.search(text):raise ValueError(label+' detected in '+relative)
        content[relative]=data
    dest.mkdir(parents=True,mode=0o700)
    try:
        for relative,data in content.items():
            target=dest/relative;target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(data)
        manifest={relative:hashlib.sha256(data).hexdigest() for relative,data in sorted(content.items())}
        (dest/'FAKE_BETA_MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
    except BaseException:
        shutil.rmtree(dest)
        raise
    return manifest

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('destination')
    args=parser.parse_args();manifest=prepare(args.destination)
    print(f'Prepared {len(manifest)} allowlisted files. No upload was performed.')
