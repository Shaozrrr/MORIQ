"""Prepare isolated synthetic-only test deployment, never upload."""
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
 'deploy/railway_config.py','deploy/bootstrap_personal_volume.py',
 'deploy/start_railway_persistent_fake.py','deploy/requirements.txt',
 'Dockerfile.persistent-fake','.dockerignore')

def prepare(destination):
    dest=Path(destination)
    if not dest.is_absolute() or dest.exists(): raise ValueError('new absolute destination required')
    content={}
    for relative in FILES:
        path=SERVICE/relative
        if path.is_symlink() or not path.is_file(): raise ValueError('invalid source: '+relative)
        data=path.read_bytes(); txt=data.decode('utf-8')
        if path.suffix=='.py': ast.parse(txt,filename=relative)
        for label,pattern in PATTERNS.items():
            if pattern.search(txt): raise ValueError(label+' detected in '+relative)
        content[relative]=data
    dest.mkdir(parents=True,mode=0o700)
    try:
        for relative,data in content.items():
            p=dest/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        manifest={name:hashlib.sha256(data).hexdigest() for name,data in sorted(content.items())}
        (dest/'PERSISTENT_FAKE_MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
    except BaseException:
        shutil.rmtree(dest);raise
    return manifest

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('destination');args=p.parse_args()
    print(f'Prepared {len(prepare(args.destination))} synthetic test source files. No upload.')
