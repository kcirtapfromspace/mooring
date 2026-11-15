#!/usr/bin/env python3
"""Exercise the integrity boundary for vendored license evidence, offline."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("notices", Path(__file__).with_name("collect-licenses.py"))
notices = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notices)


class Supplements(unittest.TestCase):
    def test_every_reviewed_file_matches_its_pinned_digest(self):
        entries = json.loads((notices.ROOT / "docs/license-supplements/manifest.json").read_text())
        identities = [(entry["name"], entry["version"]) for entry in entries]
        self.assertEqual(len(identities), len(set(identities)))
        for entry in entries:
            self.assertRegex(entry["commit"], r"^[0-9a-f]{40}$")
            for item in entry["files"]:
                path = (notices.ROOT / item["path"]).resolve()
                self.assertTrue(path.is_relative_to(notices.ROOT / "docs/license-supplements"))
                self.assertTrue(item["url"].startswith("https://"))
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), item["sha256"])

    def fixture(self, root):
        folder = root / "docs/license-supplements"
        folder.mkdir(parents=True)
        (root / ".cargo_vcs_info.json").write_text(json.dumps({"git": {"sha1": "a" * 40}}))
        (folder / "LICENSE").write_text("reviewed evidence")
        entry = {"name": "fixture", "version": "1", "commit": "a" * 40, "declared_spdx": "MIT", "files": [
            {"path": "docs/license-supplements/LICENSE", "url": "https://example.com/pinned/LICENSE",
             "sha256": hashlib.sha256(b"reviewed evidence").hexdigest()}]}
        return folder / "manifest.json", entry, {"name": "fixture", "version": "1", "license": "MIT"}

    def test_rejects_mutated_evidence_and_source_revisions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, entry, package = self.fixture(root)
            with patch.object(notices, "ROOT", root):
                manifest.write_text(json.dumps([entry]))
                self.assertEqual(len(notices.supplemental_notices(package, root)), 1)
                entry["files"][0]["sha256"] = "0" * 64
                manifest.write_text(json.dumps([entry]))
                with self.assertRaises(notices.NoticeError):
                    notices.supplemental_notices(package, root)
                entry["commit"] = "b" * 40
                manifest.write_text(json.dumps([entry]))
                with self.assertRaises(notices.NoticeError):
                    notices.supplemental_notices(package, root)

    def test_rejects_path_escape_and_changed_license_declarations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, entry, package = self.fixture(root)
            with patch.object(notices, "ROOT", root):
                entry["files"][0]["path"] = ".cargo_vcs_info.json"
                manifest.write_text(json.dumps([entry]))
                with self.assertRaises(notices.NoticeError):
                    notices.supplemental_notices(package, root)
                entry["declared_spdx"] = "AGPL-3.0-only"
                manifest.write_text(json.dumps([entry]))
                with self.assertRaises(notices.NoticeError):
                    notices.supplemental_notices(package, root)


if __name__ == "__main__":
    unittest.main()
