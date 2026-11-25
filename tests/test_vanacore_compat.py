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

    def test_modern_compat_host_aware_paths_native_plugin_layout_and_rate_limited_logging(self):
        # 1. VanaCore requires Ashita plugins under plugins/ashita/ and data under plugins/ashita/data/ + plugins/data/
        mis = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientInstallService.cs").read_text(encoding="utf-8")
        self.assertIn('Path.Combine(compatDir, "plugins", "ashita")', mis)
        self.assertIn('Path.Combine(compatDir, "plugins", "ashita", "data")', mis)

        mcg = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientConfigGenerator.cs").read_text(encoding="utf-8")
        self.assertIn("[soulspire]", mcg)
        self.assertIn("enabled={(isBaseline ? 0 : 1)}", mcg)
        self.assertNotIn('sb.AppendLine("/plugin load soulspire_native ashita");', mcg)

        # VanaCore-native vana.soulspire bridge in native_actions.lua & menu_bridge.lua (DEC-028)
        na = (REPO_ROOT / "addons" / "ashita4" / "soulspire_soul_actions" / "native_actions.lua").read_text(encoding="utf-8")
        self.assertIn("vana.soulspire", na)
        self.assertIn("replace_actions", na)
        self.assertIn("replace_visibility", na)
        mb = (REPO_ROOT / "addons" / "ashita4" / "soulspire_core" / "core" / "menu_bridge.lua").read_text(encoding="utf-8")
        self.assertIn("vana.soulspire", mb)

        # 2. Host-aware soul-weapon-config.json resolution for both Classic (../../) and VanaCore (../../../)
        cs_wc = (REPO_ROOT / "addons" / "ashita4" / "crystalsocket" / "weapon_config.lua").read_text(encoding="utf-8")
        self.assertIn("../../../plugins/ashita/data/soul-weapon-config.json", cs_wc)
        self.assertIn("../../../plugins/data/soul-weapon-config.json", cs_wc)

        fl_st = (REPO_ROOT / "addons" / "ashita4" / "soulspire_flintlock" / "flintlock_state.lua").read_text(encoding="utf-8")
        self.assertIn("../../../plugins/ashita/data/soul-weapon-config.json", fl_st)
        self.assertIn("../../../plugins/data/soul-weapon-config.json", fl_st)

        cs_lua = (REPO_ROOT / "addons" / "ashita4" / "crystalsocket" / "crystalsocket.lua").read_text(encoding="utf-8")
        self.assertIn("plugins\\\\ashita\\\\soulspire_native.dll", cs_lua)

        # 3. Capability-aware rate-limited Soul Actions logging (no per-tick spam)
        sa = (REPO_ROOT / "addons" / "ashita4" / "soulspire_soul_actions" / "soulspire_soul_actions.lua").read_text(encoding="utf-8")
        self.assertIn("state.rowLimitCapState", sa)

    def test_phase2b_native_callee_detours_soulforge_hud_and_oxmob_suppression(self):
        # 1. soulspire_native.dll must allow VanaCore's verified callee-only detours (chatfont 0x1CAD80, buttons 0x121110/0x120FF0)
        hm = (REPO_ROOT / "soulspire_native" / "hooks" / "hook_manager.h").read_text(encoding="utf-8")
        self.assertIn("0x1CAD80u", hm)
        self.assertIn("0x121110u", hm)
        self.assertIn("0x120FF0u", hm)
        diag = (REPO_ROOT / "soulspire_native" / "diagnostics" / "diagnostics.h").read_text(encoding="utf-8")
        self.assertIn("soulspire_native.log", diag)

        # 2. Launcher compat overlay syncs soulspire_talents (sibling modules for Core), soulspire_soulhud, and kazenoeye
        mis = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientInstallService.cs").read_text(encoding="utf-8")
        self.assertIn('"soulspire_talents"', mis)
        self.assertIn('"soulspire_soulhud"', mis)
        self.assertIn('"kazenoeye"', mis)

        # 3. Compat boot script loads kazenoeye before soulspire_core, loads soulspire_soulhud, and never loads standalone soulspire_talents
        mcg = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientConfigGenerator.cs").read_text(encoding="utf-8")
        self.assertIn("/addon load kazenoeye ashita", mcg)
        self.assertIn("/addon load soulspire_soulhud ashita", mcg)
        self.assertNotIn("/addon load soulspire_talents", mcg)
        self.assertLess(mcg.index("/addon load kazenoeye ashita"), mcg.index("/addon load soulspire_core ashita"))

        # 4. soulspire_core suppresses raw [OXMOB]| 0x017 transport frames so they never leak into player chat
        core = (REPO_ROOT / "addons" / "ashita4" / "soulspire_core" / "soulspire_core.lua").read_text(encoding="utf-8")
        self.assertIn("'[OXMOB]|'", core)


if __name__ == "__main__":
    unittest.main()
