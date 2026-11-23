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

    def test_registry_24hook_candidate_is_isolated_and_cannot_overwrite_27hook_testing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="soulspire_reg24_cand_") as tmp:
            tmp_repo = Path(tmp)
            shutil.copytree(REPO_ROOT / "scripts", tmp_repo / "scripts")
            shutil.copy2(REPO_ROOT / "registry_sync.json", tmp_repo / "registry_sync.json")
            (tmp_repo / "plugins" / "ashita4").mkdir(parents=True, exist_ok=True)
            dummy_old_dll = tmp_repo / "plugins" / "ashita4" / "crystaljobs.dll"
            dummy_old_dll.write_bytes(b"OLD-STABLE-DLL")
            import hashlib
            old_sha = hashlib.sha256(b"OLD-STABLE-DLL").hexdigest()
            stable_manifest = {
                "schemaVersion": 1,
                "channel": "stable",
                "manifestVersion": "2.1.0",
                "serverName": "SoulspireXI",
                "defaultHost": "play.soulspirexi.com",
                "ports": {"lobby": 54231, "auth": 54001, "search": 54002},
                "useHairpin": True,
                "repo": {"owner": "Infomatictek", "name": "soulspirexi-launcher", "branch": "main", "rawBaseUrl": "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/main"},
                "bootstrap": {},
                "files": [
                    {
                        "sourcePath": "plugins/ashita4/crystaljobs.dll",
                        "targetPath": "crystaljobs.dll",
                        "sha256": old_sha,
                        "size": len(b"OLD-STABLE-DLL"),
                        "category": "plugin",
                        "required": True,
                    }
                ],
            }
            (tmp_repo / "manifest.json").write_text(json.dumps(stable_manifest, indent=2) + "\n", encoding="utf-8")

            # Attempting to publish 24-hook DLL into default-27hook channel MUST fail
            with self.assertRaises(ValueError):
                publish_testing.build_testing_manifest(
                    tmp_repo,
                    crystaljobs_dll=None,
                    build_info=None,
                    manifest_version="2.1.0-testing.24",
                    server_version="feat/centralized-game-registry-phase5c",
                    server_branch="feat/centralized-game-registry-phase5c",
                    server_commit="57dbdbe",
                    server_image="soulspirexi/server:registry",
                    crystaljobs_hooks=24,
                    testing_notes="Should be rejected",
                    candidate="default-27hook",
                )

            # Publishing via explicit --candidate registry-24hook succeeds in its own isolated path
            real_dll = REPO_ROOT / "plugins" / "ashita4" / "crystaljobs.dll"
            new_dll = tmp_repo / "ci_crystaljobs.dll"
            shutil.copy2(real_dll, new_dll)
            real_sha = hashlib.sha256(new_dll.read_bytes()).hexdigest()
            prov = tmp_repo / "crystaljobs-provenance.json"
            prov.write_text(
                json.dumps(
                    {
                        "dllSha256": real_sha,
                        "compiledRegistryHash": "de6314e97385e328",
                        "clientVerified": False,
                    }
                ),
                encoding="utf-8",
            )
            out = publish_testing.build_testing_manifest(
                tmp_repo,
                crystaljobs_dll=new_dll,
                build_info=None,
                manifest_version="2.1.0-testing.registry24",
                server_version="feat/centralized-game-registry-phase5c",
                server_branch="feat/centralized-game-registry-phase5c",
                server_commit="57dbdbe",
                server_image="soulspirexi/server:registry",
                crystaljobs_hooks=24,
                testing_notes="24-hook registry candidate for Windows client Search label verification",
                candidate="registry-24hook",
                provenance_json=prov,
            )
            self.assertEqual(out, tmp_repo / "channels" / "testing-registry-24hook" / "manifest.json")
            cand = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(cand["channel"], "testing")
            self.assertEqual(cand["candidateId"], "registry-24hook")
            self.assertEqual(cand["registry"]["crystalJobsHooks"], 24)
            self.assertFalse(cand["registry"]["nativeDllClientVerified"])
            self.assertEqual(cand["registry"]["nativeDllCompiledHash"], "de6314e97385e328")
            self.assertEqual(cand["registry"]["nativeDllSha256"], real_sha)
            self.assertTrue((tmp_repo / "channels" / "testing-registry-24hook" / "crystaljobs-provenance.json").is_file())
            self.assertEqual(
                cand["files"][0]["sourcePath"],
                "channels/testing-registry-24hook/payload/plugins/ashita4/crystaljobs.dll",
            )
            self.assertEqual(cand["files"][0]["sha256"], real_sha)
            self.assertFalse((tmp_repo / "channels" / "testing" / "manifest.json").exists())
            self.assertEqual([], verify_manifest.verify_manifest(tmp_repo, manifest_path=out))


if __name__ == "__main__":
    unittest.main()
