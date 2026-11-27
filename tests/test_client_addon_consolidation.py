#!/usr/bin/env python3
"""Regression tests for CLIENT-ADDON-001: Core Addon Protection, COR DAT Protection & Boost Retirement."""

from __future__ import annotations

import hashlib
import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


class ClientAddonConsolidationTests(unittest.TestCase):
    def test_testing_manifest_marks_cor_dat_required_and_preserves_278_files(self) -> None:
        testing_manifest = json.loads((REPO_ROOT / "channels" / "testing" / "manifest.json").read_text(encoding="utf-8"))
        overlays = testing_manifest.get("optionalOverlays", [])
        cor_overlays = [o for o in overlays if o.get("id") == "flintlock-akimbo-compact"]
        self.assertEqual(len(cor_overlays), 1, "Testing manifest must contain flintlock-akimbo-compact overlay")
        cor = cor_overlays[0]
        self.assertIs(cor.get("required"), True, "COR DAT overlay must be marked required=true on Testing")
        self.assertIs(cor.get("defaultEnabled"), True, "COR DAT overlay must be defaultEnabled=true on Testing")
        self.assertEqual(len(cor.get("files", [])), 278, "All 278 working COR DAT files must be preserved")

        # Verify zero overlap with base dat-overlay/ROM/
        base_targets = {
            e["targetPath"]
            for e in testing_manifest.get("files", [])
            if e.get("category") == "dat"
        }
        cor_targets = {e["targetPath"] for e in cor.get("files", [])}
        self.assertEqual(len(base_targets & cor_targets), 0, "COR DAT overlay must have 0 path overlaps with base DATs")

    def test_cor_skeleton_dats_preserved_byte_for_byte(self) -> None:
        expected_skeletons = {
            "27/82.DAT": "2dedf537eabf0afd5718b87e697cee10c30aa5a4d8275e56bb10d3b22101449c",
            "32/58.DAT": "1ea97d8d2d46bb98c9b539354ec7f01744741b081ddc1c1d5d1913230943720b",
            "37/31.DAT": "be572827ffc1c0d0c1eed60901cd9f5351f9db3c601f8aba3fb0c156d75549fa",
            "42/4.DAT": "fac891177d0eccdd9e61891f42d2733d714ab04d40077406a96c592276f92f98",
            "46/93.DAT": "010878136f50254c78565dba78686029ab85f9b52a58f932acd95edc11a9c34d",
            "51/89.DAT": "c02aec49d251cc65235ebb5abdec4999a94075d1a2db586b286af3cf579a6d0f",
            "56/59.DAT": "f09eb0c44daff87d2bace5f686582be8946e59422e1ef029c71f15d660523be1",
        }
        rom_root = REPO_ROOT / "dat-overlays" / "flintlock-akimbo-compact" / "ROM"
        for rel, expected_sha in expected_skeletons.items():
            path = rom_root / rel
            self.assertTrue(path.is_file(), f"Missing COR skeleton DAT: {rel}")
            actual_sha = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(actual_sha, expected_sha, f"COR skeleton DAT {rel} was unexpectedly altered")

    def test_boost_retired_from_manifests_and_runtime_unloads(self) -> None:
        for rel in ("manifest.json", "channels/testing/manifest.json"):
            data = json.loads((REPO_ROOT / rel).read_text(encoding="utf-8"))
            for entry in data.get("files", []):
                sp = entry.get("sourcePath", "").lower()
                tp = entry.get("targetPath", "").lower()
                self.assertNotIn("overlords_boost", sp, f"{rel} must not distribute overlords_boost")
                self.assertNotIn("overlords_boost", tp, f"{rel} must not target overlords_boost")

        soulhud_lua = (REPO_ROOT / "addons" / "ashita4" / "soulspire_soulhud" / "soulspire_soulhud.lua").read_text(
            encoding="utf-8"
        )
        self.assertNotIn(
            "/addon unload overlords_boost",
            soulhud_lua,
            "soulspire_soulhud.lua must not spam /addon unload overlords_boost on load",
        )

        xaml = (REPO_ROOT / "SoulspireLauncher" / "MainWindow.xaml").read_text(encoding="utf-8")
        self.assertNotIn("Chi Weaver Boost", xaml, "MainWindow.xaml must not advertise retired Boost addon")

    def test_modern_config_enforces_mandatory_pivot_overlays_and_diagnostics(self) -> None:
        cfg_cs = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientConfigGenerator.cs").read_text(
            encoding="utf-8"
        )
        self.assertIn("0=soulspirexi", cfg_cs)
        self.assertIn("FlintlockOverlayFolderName", cfg_cs)
        self.assertNotIn("if (settings.EnableFlintlockDualPistolsOverlay)", cfg_cs)

        diag_cs = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientDiagnosticsService.cs").read_text(
            encoding="utf-8"
        )
        self.assertIn("EvaluateClientComponentHealth", diag_cs)
        self.assertIn("retired_present", diag_cs)
        self.assertIn("missing_file", diag_cs)
        self.assertIn("overlords_boost", diag_cs)


if __name__ == "__main__":
    unittest.main()
