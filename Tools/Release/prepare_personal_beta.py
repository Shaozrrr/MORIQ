"""Prepare a reviewable personal-service source tree; never upload or deploy."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import shutil
from prepare_fake_beta import PATTERNS, SERVICE

FILES=(
 'account_store.py','asr_gateway.py','audio_timeline.py','caption_auto_translation.py',
 'caption_memory_ledger.py','caption_source_collector.py','caption_source_collector_v2.py',
 'deepgram_gateway.py','deepl_experiment.py','deepl_https_transport.py','deepseek_translation.py',
 'soniox_gateway.py','soniox_native_translation.py','speech_gateway.py','unanchored_preview.py',
 'deploy/railway_config.py','deploy/export_bootstrap_seed.py','deploy/bootstrap_personal_volume.py','deploy/provision_personal_beta.py','deploy/start_railway_staging.py',
 'deploy/start_staging.py','deploy/start_personal_unprivileged.py','deploy/requirements.txt','deploy/RAILWAY_PERSONAL_BETA.md',
 'Dockerfile.personal','.dockerignore')

def prepare(destination):
    dest=Path(destination)
    if not dest.is_absolute() or dest.exists():raise ValueError('new absolute destination required')
    content={}
    for relative in FILES:
        path=SERVICE/relative
        if path.is_symlink() or not path.is_file():raise ValueError('invalid input: '+relative)
        data=path.read_bytes();text=data.decode('utf-8')
        if path.suffix=='.py':ast.parse(text,filename=relative)
        for label,pattern in PATTERNS.items():
            if pattern.search(text):raise ValueError(label+' detected in '+relative)
        content[relative]=data
    dest.mkdir(parents=True,mode=0o700)
    try:
        for relative,data in content.items():
            target=dest/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        manifest={relative:hashlib.sha256(data).hexdigest() for relative,data in sorted(content.items())}
        (dest/'PERSONAL_BETA_MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
    except BaseException:
        shutil.rmtree(dest);raise
    return manifest

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('destination')
    args=parser.parse_args();manifest=prepare(args.destination)
    print(f'Prepared {len(manifest)} allowlisted files. No upload or deployment was performed.')
