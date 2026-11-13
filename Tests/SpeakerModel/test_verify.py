import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_campplus", ROOT / "Tools/SpeakerModel/verify_campplus.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.files = {}
        for directory in module.MODEL_DIRS:
            path = self.root / directory / "weights" / "weight.bin"
            path.parent.mkdir(parents=True)
            path.write_bytes(b"small-model-fixture")
            name = path.relative_to(self.root).as_posix()
            self.files[name] = {"size": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    def tearDown(self):
        self.tmp.cleanup()

    def test_valid_exact_tree(self):
        module.verify(self.root, self.files)

    def test_truncated_and_modified_file_rejected(self):
        path = self.root / next(iter(self.files))
        path.write_bytes(b"x")
        with self.assertRaises(module.VerificationError): module.verify(self.root, self.files)
        path.write_bytes(b"X" * len(b"small-model-fixture"))
        with self.assertRaises(module.VerificationError): module.verify(self.root, self.files)

    def test_missing_extra_and_symlink_rejected(self):
        path = self.root / next(iter(self.files))
        path.unlink()
        with self.assertRaises(module.VerificationError): module.verify(self.root, self.files)
        path.symlink_to(self.root / list(self.files)[1])
        with self.assertRaises(module.VerificationError): module.verify(self.root, self.files)
        path.unlink(); path.write_bytes(b"small-model-fixture")
        (path.parent / "extra").write_text("unexpected")
        with self.assertRaises(module.VerificationError): module.verify(self.root, self.files)

    def test_manifest_path_traversal_and_unexpected_root_rejected(self):
        bad = dict(self.files)
        bad["CamPlusPlus_v2.mlmodelc/../escape"] = {"size": 0, "sha256": "0" * 64}
        with self.assertRaises(module.VerificationError): module.verify(self.root, bad)
        bad = {"/etc/passwd": {"size": 0, "sha256": "0" * 64}}
        with self.assertRaises(module.VerificationError): module.verify(self.root, bad)

    def test_directory_symlink_and_extra_directory_rejected(self):
        extra = self.root / module.MODEL_DIRS[0] / "extra"
        extra.mkdir()
        with self.assertRaises(module.VerificationError): module.verify(self.root, self.files)
        extra.rmdir()
        extra.symlink_to(self.root / module.MODEL_DIRS[1], target_is_directory=True)
        with self.assertRaises(module.VerificationError): module.verify(self.root, self.files)


if __name__ == "__main__":
    unittest.main()
