"""Tests for the Phase 2 allowlist-only public release staging & validation pipeline."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STAGE_SCRIPT = REPO_ROOT / "scripts" / "stage-public-release.py"
VERIFY_SCRIPT = REPO_ROOT / "scripts" / "verify-launcher-manifest.py"


class PublicReleasesPipelineTests(unittest.TestCase):
    def test_verify_launcher_manifest_passes_and_excludes_dev_tests_and_docs(self):
        res = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT)],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
        )
        self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)
        manifest = json.loads((REPO_ROOT / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["repo"]["name"], "soulspirexi-releases")
        self.assertEqual(
            manifest["repo"]["rawBaseUrl"],
            "https://raw.githubusercontent.com/Infomatictek/soulspirexi-releases/main",
        )
        for entry in manifest["files"]:
            src = entry["sourcePath"]
            self.assertNotIn("/tests/", src, f"Test file leaked into manifest: {src}")
            self.assertFalse(src.lower().endswith(".md"), f"Markdown doc leaked into manifest: {src}")

    def test_stage_public_release_builds_clean_allowlist_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "public-stage"
            res = subprocess.run(
                [sys.executable, str(STAGE_SCRIPT), "--repo-root", str(REPO_ROOT), "--output-dir", str(out_dir)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)
            self.assertTrue((out_dir / "manifest.json").is_file())
            self.assertTrue((out_dir / "README.md").is_file())
            self.assertFalse((out_dir / "SoulspireLauncher").exists())
            self.assertFalse((out_dir / "native").exists())
            self.assertFalse((out_dir / "docs").exists())
            self.assertFalse((out_dir / "scripts").exists())
            staged_manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertNotIn("soulspirexi-launcher", json.dumps(staged_manifest))
            compat = staged_manifest.get("serverCompatibility") or {}
            for bad_k in ("branch", "commit", "dockerImage", "crystalJobsHooks"):
                self.assertNotIn(bad_k, compat)


if __name__ == "__main__":
    unittest.main()
