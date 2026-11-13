#!/usr/bin/env python3
"""Verify the exact pinned CAM++ v2 Core ML files; never download or execute them."""
import argparse
import hashlib
import json
import os
import stat
from pathlib import Path, PurePosixPath

MANIFEST = Path(__file__).with_name("campplus-v2-manifest.json")
EXPECTED_REPOSITORY = "https://huggingface.co/FluidInference/campplus-coreml"
EXPECTED_REVISION = "f316edbc70d9023a94aaf8965538aba4330dc28e"
MODEL_DIRS = ("CamPlusPlus_v2.mlmodelc", "CamPlusPreprocessor_v2.mlmodelc")


class VerificationError(Exception):
    pass


def verify(root: Path, files: dict) -> None:
    if not isinstance(files, dict) or not files:
        raise VerificationError("invalid manifest")
    expected_dirs = set(MODEL_DIRS)
    for name, spec in files.items():
        if not isinstance(name, str):
            raise VerificationError("invalid manifest entry")
        p = PurePosixPath(name)
        if (not name or p.is_absolute() or
                any(part in ("", ".", "..") for part in name.split("/")) or
                not p.parts or p.parts[0] not in MODEL_DIRS or len(p.parts) < 2 or
                not isinstance(spec, dict) or type(spec.get("size")) is not int or spec["size"] < 0 or
                not isinstance(spec.get("sha256"), str) or len(spec["sha256"]) != 64 or
                any(c not in "0123456789abcdef" for c in spec["sha256"])):
            raise VerificationError("invalid manifest entry")
        expected_dirs.update("/".join(p.parts[:i]) for i in range(1, len(p.parts)))

    # Restrict verification to the two v2 model bundles; other model versions in
    # their parent are irrelevant. Do not follow directory or file symlinks.
    try:
        if root.is_symlink() or not root.is_dir():
            raise VerificationError("model root is not a real directory")
        actual = set()
        for model in MODEL_DIRS:
            base = root / model
            if base.is_symlink() or not base.is_dir():
                raise VerificationError("missing model directory")
            for directory, dirs, names in os.walk(base, followlinks=False):
                for item in dirs + names:
                    path = Path(directory) / item
                    rel = path.relative_to(root).as_posix()
                    mode = path.lstat().st_mode
                    if stat.S_ISLNK(mode):
                        raise VerificationError("symlink in model directory")
                    if stat.S_ISDIR(mode):
                        if rel not in expected_dirs: raise VerificationError("unexpected directory")
                    elif stat.S_ISREG(mode):
                        if rel not in files: raise VerificationError("unexpected file")
                        actual.add(rel)
                    else:
                        raise VerificationError("unsupported filesystem entry")
        if actual != set(files):
            raise VerificationError("missing model file")

        # openat + O_NOFOLLOW prevents following symlinks in each relative
        # component; this is a packaging check, not a live anti-tamper lock.
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for name, spec in files.items():
                parts = name.split("/")
                current = os.dup(root_fd)
                try:
                    for part in parts[:-1]:
                        next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
                        os.close(current); current = next_fd
                    fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=current)
                    try:
                        info = os.fstat(fd)
                        if not stat.S_ISREG(info.st_mode) or info.st_size != spec["size"]:
                            raise VerificationError("incorrect file size")
                        digest = hashlib.sha256()
                        while True:
                            block = os.read(fd, 1_048_576)
                            if not block: break
                            digest.update(block)
                        if digest.hexdigest() != spec["sha256"]:
                            raise VerificationError("incorrect file digest")
                    finally:
                        os.close(fd)
                finally:
                    os.close(current)
        finally:
            os.close(root_fd)
    except OSError as exc:
        raise VerificationError("model files unavailable or changed") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_root", type=Path)
    args = parser.parse_args()
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        if manifest.get("repository") != EXPECTED_REPOSITORY or manifest.get("revision") != EXPECTED_REVISION:
            raise VerificationError("unexpected source revision")
        verify(args.model_root, manifest.get("files"))
    except (OSError, ValueError, VerificationError) as exc:
        print(f"FAIL CAM++ verification: {exc}")
        return 1
    print("PASS pinned CAM++ v2 10-file integrity check")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
