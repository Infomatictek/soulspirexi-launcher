#!/usr/bin/env python3
"""Unit tests for Testing channel manifest publishing and Stable/Testing isolation."""
from __future__ import annotations

import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load(rel_path: str, name: str):
    path = REPO_ROOT / rel_path
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


publish_testing = _load("scripts/publish-testing-channel.py", "publish_testing_channel")
verify_manifest = _load("scripts/verify-launcher-manifest.py", "verify_launcher_manifest")


class TestingChannelPublishTests(unittest.TestCase):
    def test_testing_manifest_builds_cleanly_without_modifying_stable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="soulspire_testing_chan_") as tmp:
            tmp_repo = Path(tmp)
            shutil.copytree(REPO_ROOT / "scripts", tmp_repo / "scripts")
            shutil.copytree(REPO_ROOT / "addons" / "ashita4" / "crystalsocket", tmp_repo / "addons" / "ashita4" / "crystalsocket")
            shutil.copytree(
                REPO_ROOT / "channels" / "testing" / "payload",
                tmp_repo / "channels" / "testing" / "payload",
            )

            # Seed minimal valid Stable manifest.json pointing at crystalsocket files
            stable_files = []
            for p in sorted((tmp_repo / "addons" / "ashita4" / "crystalsocket").rglob("*")):
                if not p.is_file():
                    continue
                digest, size = publish_testing.sha256_file(p)
                stable_files.append(
                    {
                        "category": "addon",
                        "sourcePath": p.relative_to(tmp_repo).as_posix(),
                        "targetPath": p.relative_to(tmp_repo / "addons" / "ashita4").as_posix(),
                        "sha256": digest,
                        "size": size,
                    }
                )

            stable_manifest = {
                "schemaVersion": 1,
                "channel": "stable",
                "manifestVersion": "2.1.0",
                "serverName": "SoulspireXI",
                "defaultHost": "play.soulspirexi.com",
                "useHairpin": False,
                "ports": {"lobby": 54231, "auth": 54001, "search": 54002},
                "repo": {
                    "owner": "Infomatictek",
                    "name": "soulspirexi-launcher",
                    "branch": "main",
                    "rawBaseUrl": "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/main",
                },
                "bootstrap": {},
                "files": stable_files,
            }
            stable_path = tmp_repo / "manifest.json"
            stable_before = json.dumps(stable_manifest, indent=2) + "\n"
            stable_path.write_text(stable_before, encoding="utf-8")

            out_path = publish_testing.build_testing_manifest(
                tmp_repo,
                crystaljobs_dll=None,
                build_info=None,
                manifest_version="2.1.0-testing.1",
                server_version="feat/soul-weapon-templates (b05c027 / patch 0074)",
                server_branch="feat/soul-weapon-templates",
                server_commit="b05c027",
                server_image="soulspirexi/server:feat-soul-weapon-templates",
                crystaljobs_hooks=27,
                testing_notes="Testing channel unit test",
            )

            # Stable manifest must remain byte-for-byte unchanged
            self.assertEqual(stable_before, stable_path.read_text(encoding="utf-8"))

            testing_data = json.loads(out_path.read_text(encoding="utf-8"))
            self.assertEqual("testing", testing_data["channel"])
            self.assertEqual("2.1.0-testing.1", testing_data["manifestVersion"])
            self.assertEqual(27, testing_data["serverCompatibility"]["crystalJobsHooks"])

            # Overridden crystalsocket files point into channels/testing/payload/
            by_target = {f["targetPath"]: f for f in testing_data["files"]}
            self.assertEqual(
                "channels/testing/payload/addons/ashita4/crystalsocket/weapon_config.lua",
                by_target["crystalsocket/weapon_config.lua"]["sourcePath"],
            )

            # Both Stable and Testing manifests pass strict read-only verifier
            self.assertEqual([], verify_manifest.verify_manifest(tmp_repo, manifest_path=stable_path))
            self.assertEqual([], verify_manifest.verify_manifest(tmp_repo, manifest_path=out_path))


if __name__ == "__main__":
    unittest.main()
