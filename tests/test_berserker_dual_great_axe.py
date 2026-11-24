"""Regression tests for database-driven Berserker Dual Great Axe & generic native weapon hooks."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT_WC_JSON = ROOT / "plugins" / "ashita4" / "data" / "soul-weapon-config.json"
LEGACY_PRES_JSON = ROOT / "plugins" / "ashita4" / "data" / "soul-weapon-presentation.json"
WEAPON_CONFIG_LUA = ROOT / "addons" / "ashita4" / "crystalsocket" / "weapon_config.lua"
SOUL_APPEARANCE_LUA = ROOT / "addons" / "ashita4" / "crystalsocket" / "soul_appearance.lua"
FLINTLOCK_STATE_LUA = ROOT / "addons" / "ashita4" / "soulspire_flintlock" / "flintlock_state.lua"
CORE_WEAPON_PRES_LUA = ROOT / "addons" / "ashita4" / "soulspire_core" / "core" / "weapon_presentation.lua"
NATIVE_WEAPON_PRES_H = ROOT / "soulspire_native" / "rendering" / "weapon_presentation.h"
NATIVE_WC_LOADER_H = ROOT / "soulspire_native" / "equipment" / "weapon_config_loader.h"
NATIVE_SELFTEST_CPP = ROOT / "soulspire_native" / "tests" / "selftest.cpp"
REGISTRY_SYNC_JSON = ROOT / "registry_sync.json"

ALL_PLAYABLE_RACES = (
    "hume_male",
    "hume_female",
    "elvaan_male",
    "elvaan_female",
    "tarutaru_male",
    "tarutaru_female",
    "mithra",
    "galka",
)


class BerserkerDualGreatAxeTests(unittest.TestCase):
    def test_single_authoritative_client_weapon_config_json(self) -> None:
        self.assertTrue(CLIENT_WC_JSON.is_file(), "Missing plugins/ashita4/data/soul-weapon-config.json")
        self.assertFalse(
            LEGACY_PRES_JSON.exists(),
            "Superseded soul-weapon-presentation.json must be removed so no competing config exists",
        )

        doc = json.loads(CLIENT_WC_JSON.read_text(encoding="utf-8"))
        sync = json.loads(REGISTRY_SYNC_JSON.read_text(encoding="utf-8"))

        self.assertEqual(doc["schemaVersion"], 1)
        self.assertEqual(doc["registryHash"], sync["registryHash"])
        self.assertRegex(doc["integrityFnv1a64"], r"^[0-9a-f]{16}$")
        self.assertRegex(doc["integrityFnv1a32"], r"^[0-9a-f]{8}$")
        self.assertFalse(doc["diagnostics"]["enabled"], "Diagnostics MUST be disabled by default")

        # Authoritative rules include BRD Adventurer (dual_1h) and WAR Berserker (dual_2h)
        by_soul = {r["soulId"]: r for r in doc["rules"]}
        self.assertIn("war_dps", by_soul)
        self.assertIn("brd_dps", by_soul)
        ber = by_soul["war_dps"]
        self.assertEqual(ber["jobId"], 1)
        self.assertEqual(ber["branch"], 2)
        self.assertEqual(ber["mode"], "dual_2h")
        self.assertEqual(ber["modeId"], 2)
        self.assertEqual(ber["mainSkillMask"], 1 << 6)
        self.assertEqual(ber["subSkillMask"], 1 << 6)
        self.assertEqual(ber["presentationProfile"], "dual_2h_crossed_back_x")

        # Flintlock appearance mask & ranged-only migrated into same authoritative file
        masks = {m["soulId"]: m for m in doc["appearanceMasks"]}
        self.assertIn("cor_ranged_dps", masks)
        self.assertTrue(masks["cor_ranged_dps"]["hideMain"])
        self.assertTrue(masks["cor_ranged_dps"]["hideSub"])
        ranged = {g["soulId"]: g for g in doc["rangedOnly"]}
        self.assertIn("cor_ranged_dps", ranged)
        self.assertTrue(ranged["cor_ranged_dps"]["autoFacing"])

    def test_all_eight_playable_races_have_crossed_x_depth_separation_and_not_certified(self) -> None:
        doc = json.loads(CLIENT_WC_JSON.read_text(encoding="utf-8"))
        profiles = {p["id"]: p for p in doc["presentationProfiles"]}
        self.assertIn("dual_2h_crossed_back_x", profiles)
        self.assertIn("ranged_dual_pistol_overlay", profiles)

        dual = profiles["dual_2h_crossed_back_x"]
        self.assertFalse(dual["visualCertified"], "Do not claim visual certification before Phase 6 screenshots")
        self.assertTrue(dual["requiresNative3dBoneHook"])
        self.assertEqual(len(dual["races"]), 8)

        seen_keys = tuple(r["key"] for r in dual["races"])
        self.assertEqual(seen_keys, ALL_PLAYABLE_RACES)
        for idx, race in enumerate(dual["races"], start=1):
            self.assertEqual(race["raceId"], idx)
            dm, ds = race["drawnMain"], race["drawnSub"]
            sm, ss = race["sheathedMain"], race["sheathedSub"]
            for vec in (dm, ds, sm, ss):
                self.assertEqual(len(vec), 12)
                self.assertGreaterEqual(vec[9], 0.5)
                self.assertLessEqual(vec[9], 1.5)
            # Drawn mirrored symmetry on X
            self.assertAlmostEqual(dm[0], -ds[0], places=4)
            # Sheathed crossed-back X with opposing diagonal rolls & depth separation
            self.assertAlmostEqual(sm[0], -ss[0], places=4)
            self.assertGreater(sm[5], 30.0)
            self.assertLess(ss[5], -30.0)
            self.assertAlmostEqual(sm[5], -ss[5], places=3)
            self.assertGreaterEqual(ss[2] - sm[2], 0.025)
            self.assertGreaterEqual(ss[11] - sm[11], 0.025)

    def test_zero_hardcoded_soul_rules_in_native_engine_and_client_addons(self) -> None:
        # C++ weapon_presentation.h must be 100% generic (zero hardcoded Berserker constants)
        cpp = NATIVE_WEAPON_PRES_H.read_text(encoding="utf-8")
        for forbidden in ("kWarJobId", "kBerserkerBranch", "kGreatAxeSkill", "default_berserker_race_transforms"):
            self.assertNotIn(forbidden, cpp)

        # C++ loader exists and validates schemaVersion + registryHash + integrityFnv1a64
        loader_cpp = NATIVE_WC_LOADER_H.read_text(encoding="utf-8")
        for required in ("parse_weapon_config_json", "apply_weapon_calibration_json", "integrityFnv1a64", "WEAPON_CFG_BAD_INTEGRITY"):
            self.assertIn(required, loader_cpp)

        # Lua weapon_config.lua has zero hardcoded Berserker/Adventurer rules
        wc_lua = WEAPON_CONFIG_LUA.read_text(encoding="utf-8")
        self.assertNotIn("key = 'berserker'", wc_lua)
        self.assertNotIn("key = 'adventurer'", wc_lua)
        self.assertIn("soul-weapon-config.json", wc_lua)
        self.assertIn("integrityFnv1a32", wc_lua)

        # Lua soul_appearance.lua has zero hardcoded [17] Flintlock table
        app_lua = SOUL_APPEARANCE_LUA.read_text(encoding="utf-8")
        self.assertNotIn("[17] = {", app_lua)
        self.assertIn("WeaponConfig.appearance_mask_for", app_lua)

        # Lua flintlock_state.lua resolves ranged-only rules from registry config
        fl_lua = FLINTLOCK_STATE_LUA.read_text(encoding="utf-8")
        self.assertNotIn("M.COR_JOB_ID = 17", fl_lua)
        self.assertIn("soul-weapon-config.json", fl_lua)

        # Lua soulspire_core weapon_presentation.lua has zero hardcoded WAR/Berserker/Great Axe constants
        wp_lua = CORE_WEAPON_PRES_LUA.read_text(encoding="utf-8")
        for forbidden in ("M.WAR_JOB_ID", "M.BERSERKER_BRANCH", "M.GREAT_AXE_SKILL", "M.default_races"):
            self.assertNotIn(forbidden, wp_lua)
        self.assertIn("SoulspireNativeReloadConfig", wp_lua)

    def test_no_standalone_berserker_addon_introduced(self) -> None:
        addons_dir = ROOT / "addons" / "ashita4"
        berserker_addons = [p.name for p in addons_dir.iterdir() if p.is_dir() and "berserker" in p.name.lower()]
        self.assertEqual(berserker_addons, [])

    def test_native_selftest_covers_registry_loader_and_zero_recompile_proof(self) -> None:
        src = NATIVE_SELFTEST_CPP.read_text(encoding="utf-8")
        for token in (
            "parse_weapon_config_json",
            "WEAPON_CFG_BAD_REGISTRY_HASH",
            "WEAPON_CFG_BAD_INTEGRITY",
            "WEAPON_CFG_BAD_SCHEMA",
            "drk_dps",
            "weapon_presentation_checks();",
        ):
            self.assertIn(token, src)
        # Ensure zero std::strncpy (MSVC /W4 /WX C4996 guard)
        self.assertIsNone(re.search(r"\bstrncpy\b", NATIVE_WEAPON_PRES_H.read_text(encoding="utf-8")))
        self.assertIsNone(re.search(r"\bstrncpy\b", NATIVE_WC_LOADER_H.read_text(encoding="utf-8")))


if __name__ == "__main__":
    unittest.main()
