"""Static & contract verification for CLIENT-MODERN-001 (VanaCore dual-host & launcher integration)."""
from __future__ import annotations

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


class VanaCoreCompatibilityTests(unittest.TestCase):
    def test_soulspire_native_supports_dual_host_detours_fail_closed(self):
        hm = (REPO_ROOT / "soulspire_native" / "hooks" / "hook_manager.h").read_text(encoding="utf-8")
        cpp = (REPO_ROOT / "soulspire_native" / "soulspire_native.cpp").read_text(encoding="utf-8")
        self.assertIn("detect_vanacore_host_module", hm)
        self.assertIn('L"VanaCore.Core.dll"', hm)
        self.assertIn('L"SoulspireClient.Core.dll"', hm)
        self.assertIn("host_packet_detour_matches", hm)
        self.assertIn("host_detour(entry, expected, length, 7, vanacore_host)", hm)
        self.assertIn("host_packet_detour_matches(", cpp)
        # Singlemenu Button ID 16 collision fail-closed guard
        self.assertIn("VanaCore singlemenu=1", cpp)

    def test_soulspire_core_and_companion_addons_support_vanacore(self):
        inp = (REPO_ROOT / "addons" / "ashita4" / "soulspire_core" / "core" / "input.lua").read_text(encoding="utf-8")
        self.assertIn("normalize_xinput_state", inp)
        self.assertIn("normalize_dinput_state", inp)
        self.assertIn("SXI_XINPUT_STATE*", inp)

        pivot = (REPO_ROOT / "addons" / "ashita4" / "soulspire_flintlock" / "pivot_config.lua").read_text(encoding="utf-8")
        self.assertIn("pivot.order", pivot)
        self.assertIn("detect_section_name", pivot)

        flint = (REPO_ROOT / "addons" / "ashita4" / "soulspire_flintlock" / "soulspire_flintlock.lua").read_text(encoding="utf-8")
        self.assertIn("is_vanacore_host", flint)
        self.assertIn("VanaCore.Core.dll", flint)

        gear = (REPO_ROOT / "addons" / "ashita4" / "soulspire_gear" / "soulspire_gear.lua").read_text(encoding="utf-8")
        self.assertIn("ashita.interface_version >= 4.3", gear)

    def test_launcher_modern_engine_uses_password_stdin_and_stable_safety_gate(self):
        gls = (REPO_ROOT / "SoulspireLauncher" / "Services" / "GameLaunchService.cs").read_text(encoding="utf-8")
        self.assertIn("--password-stdin", gls)
        self.assertIn("RedirectStandardInput", gls)

        mcg = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientConfigGenerator.cs").read_text(encoding="utf-8")
        self.assertIn("singlemenu=0", mcg)
        self.assertIn("ashita.interface=4.30", mcg)
        self.assertIn("0=soulspirexi", mcg)

        mus = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ManifestUpdateService.cs").read_text(encoding="utf-8")
        self.assertIn("modernClient.clientVerified=false", mus)


if __name__ == "__main__":
    unittest.main()
