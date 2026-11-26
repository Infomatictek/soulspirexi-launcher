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

        # 3. Compat boot script restores full polished Soulspire UI/HUD/Soulforge/Soul Actions (zero placeholder regression)
        mcg = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientConfigGenerator.cs").read_text(encoding="utf-8")
        self.assertIn("/addon load kazenoeye ashita", mcg)
        self.assertIn("/addon load soulspire_soulhud ashita", mcg)
        self.assertIn("/addon load soulspire_core ashita", mcg)
        self.assertIn("/addon load soulspire_soul_actions ashita", mcg)
        self.assertNotIn("/addon load soulspire_talents", mcg)
        self.assertLess(mcg.index("/addon load kazenoeye ashita"), mcg.index("/addon load soulspire_core ashita"))

        # 4. Phase C VanaCore-native soulspire_core entrypoint uses real 'present' event (never non-existent 'frame')
        vc_root = REPO_ROOT / "addons" / "vanacore" / "soulspire_core"
        for rel in [
            "soulspire_core.lua",
            "core/identity.lua",
            "core/actions.lua",
            "core/hud.lua",
            "core/soulforge.lua",
            "core/weapon_mastery.lua",
            "core/crystalsocket.lua",
            "core/flintlock.lua",
            "core/mob_status.lua",
            "tests/test_vanacore_entrypoint_lifecycle.lua",
        ]:
            self.assertTrue((vc_root / rel).is_file(), f"Missing Phase C module: {rel}")

        vc_core = (vc_root / "soulspire_core.lua").read_text(encoding="utf-8")
        self.assertIn("vana.events.on('present'", vc_core)
        self.assertNotIn("vana.events.on('frame'", vc_core)
        self.assertIn("vana.gamepad.nav", vc_core)
        self.assertIn("vana.soulspire", vc_core)
        self.assertIn("/soulactions capabilities", vc_core)
        self.assertIn("startup_report", vc_core)

        vc_sf = (vc_root / "core" / "soulforge.lua").read_text(encoding="utf-8")
        self.assertIn("resolve_node_idx", vc_sf)
        self.assertIn("PENDING_TIMEOUT_SEC", vc_sf)
        self.assertIn("vana.packets.inject", vc_sf)

        # 5. Classic fallback soulforge_state.lua also receives the WS talent allocation & pendingOp timeout fix
        sf_state = (REPO_ROOT / "addons" / "ashita4" / "soulspire_talents" / "soulforge_state.lua").read_text(encoding="utf-8")
        self.assertIn("resolveServerNodeIndex", sf_state)
        self.assertIn("pending_op_timeout", sf_state)

        # 6. soulspire_core (Ashita fallback) suppresses raw [OXMOB]| 0x017 transport frames
        core = (REPO_ROOT / "addons" / "ashita4" / "soulspire_core" / "soulspire_core.lua").read_text(encoding="utf-8")
        self.assertIn("'[OXMOB]|'", core)

    def test_full_vanacore_native_soulspire_core_has_zero_ashita_dependencies_and_polished_parity(self):
        vc_root = REPO_ROOT / "addons" / "vanacore" / "soulspire_core"
        # Polished UI, Soul Sanctum, Soulforge Constellation, 66-Soul HUD, and Core artwork must all be present
        required_files = [
            "soulspire_core.lua",
            "core/ui.lua",
            "core/imgui_constants.lua",
            "core/foundations.lua",
            "core/theme.lua",
            "core/focus.lua",
            "core/input.lua",
            "core/registry.lua",
            "core/assets.lua",
            "core/soulhud_bridge.lua",
            "data/soul-identities.json",
            "data/soul-weapon-config.json",
            "data/soul_actions.tsv",
            "data/visibility.tsv",
            "data/presentation.cfg",
            "modules/character.lua",
            "modules/weapon_mastery.lua",
            "modules/soul_talents.lua",
            "modules/abilities.lua",
            "modules/status_and_diag.lua",
            "soulforge/soulforge_state.lua",
            "soulforge/soulforge_ui.lua",
            "soulforge/premium_ui.lua",
            "soulforge/art.lua",
            "soulforge/ws_registry_generated.lua",
            "soulhud/soulhud_layout.lua",
            "soulhud/soulhud_gauge.lua",
            "soulhud/soulhud_roster_generated.lua",
            "soulhud/ox_icons.lua",
            "assets/soulspire_crest.png",
            "assets/soulforge_backdrop.png",
            "assets/character_chamber_bg.png",
        ]
        for rel in required_files:
            self.assertTrue((vc_root / rel).is_file(), f"Missing VanaCore-native parity asset/module: {rel}")

        # Zero Ashita / d3d8 / legacy DLL calls anywhere in addons/vanacore/soulspire_core/ (excluding tests/)
        forbidden_tokens = [
            "AshitaCore:",
            "AshitaCore.",
            "ashita.events.",
            "ashita.memory.",
            "ashita.packets.",
            "ashita.fs.",
            "ashita.time.",
            "require('d3d8')",
            'require("d3d8")',
            "D3DXCreateTexture",
            "GetModuleHandleA('soulspire_native.dll')",
            "GetModuleHandleA('crystaljobs.dll')",
        ]
        for lua_file in vc_root.rglob("*.lua"):
            if "tests" in lua_file.parts:
                continue
            text = lua_file.read_text(encoding="utf-8", errors="replace")
            for tok in forbidden_tokens:
                self.assertNotIn(tok, text, f"Forbidden Ashita/legacy token '{tok}' found in {lua_file.relative_to(REPO_ROOT)}")

        # ModernNative profile must disable Ashita compat & load exactly one unified VanaCore addon
        mcg = (REPO_ROOT / "SoulspireLauncher" / "Services" / "ModernClientConfigGenerator.cs").read_text(encoding="utf-8")
        self.assertIn("ClientEngineMode.ModernNative", mcg)
        self.assertIn("ashita.enabled={(isNative ? 0 : 1)}", mcg)
        self.assertIn("/addon load soulspire_core vanacore", mcg)

        # Zero Ashita-style ImGui global enum lookups (which are nil when ashita.enabled=0)
        import re
        bad_imgui_global = re.compile(r"\bImGui(?:WindowFlags|StyleVar|Col|Cond|ChildFlags)_[A-Za-z0-9_]+")
        for lua_file in vc_root.rglob("*.lua"):
            if "tests" in lua_file.parts:
                continue
            for idx, line in enumerate(lua_file.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                code = line.split("--", 1)[0]
                m = bad_imgui_global.search(code)
                self.assertIsNone(
                    m,
                    f"Ashita ImGui global '{m.group(0) if m else ''}' found in {lua_file.relative_to(REPO_ROOT)}:{idx}; use core/imgui_constants.lua",
                )

        # Native packet sync & HUD wiring in soulspire_core.lua
        vc_core = (vc_root / "soulspire_core.lua").read_text(encoding="utf-8")
        self.assertIn("character_mod:handle_packet_in(", vc_core)
        self.assertIn("character_mod:tick(", vc_core)
        self.assertIn("soulhud:handle_packet_in(", vc_core)
        self.assertNotIn("character_mod:handle_packet(", vc_core)

    def test_testing_modern_client_profiles_are_synced_and_pin_interface_fix(self):
        import json

        modern_cfg = json.loads((REPO_ROOT / "channels" / "testing" / "modern-client.json").read_text(encoding="utf-8"))
        testing_mf = json.loads((REPO_ROOT / "channels" / "testing" / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(
            testing_mf.get("modernClient"),
            modern_cfg,
            "channels/testing/modern-client.json must match channels/testing/manifest.json['modernClient'] exactly",
        )
        self.assertFalse(modern_cfg["clientVerified"])
        self.assertTrue(modern_cfg["experimentalEligible"])

        unfixed_tags = {
            "v0.9.9-soulspire-baseline.4",
            "v0.9.9-soulspire-baseline.5",
            "v0.9.9-soulspire-native.3",
            "v0.9.9-soulspire-native.4",
        }
        for profile_key in ("baseline", "compat", "native"):
            self.assertIn(profile_key, modern_cfg, f"Missing modernClient profile: {profile_key}")
            prof = modern_cfg[profile_key]
            self.assertEqual(prof["profile"], profile_key)
            self.assertFalse(prof["clientVerified"])
            self.assertTrue(prof["experimentalEligible"])
            self.assertNotIn(
                prof["tag"],
                unfixed_tags,
                f"Profile {profile_key} must not pin unfixed pre-Interface-fix VanaCore tag {prof['tag']}",
            )
            self.assertEqual(len(prof["packageSha256"]), 64)
            self.assertIn(prof["tag"], prof["packageUrl"])
            self.assertIn(prof["commitSha"], prof["packageUrl"])


if __name__ == "__main__":
    unittest.main()
