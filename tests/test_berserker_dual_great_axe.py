"""Regression tests for Berserker Dual Great Axe native equipment & reusable weapon presentation."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRESENTATION_JSON = ROOT / "plugins" / "ashita4" / "data" / "soul-weapon-presentation.json"
WEAPON_CONFIG_LUA = ROOT / "addons" / "ashita4" / "crystalsocket" / "weapon_config.lua"
CORE_WEAPON_PRES_LUA = ROOT / "addons" / "ashita4" / "soulspire_core" / "core" / "weapon_presentation.lua"
NATIVE_WEAPON_PRES_H = ROOT / "soulspire_native" / "rendering" / "weapon_presentation.h"
SELFTEST_CPP = ROOT / "soulspire_native" / "tests" / "selftest.cpp"
ADDONS_ROOT = ROOT / "addons" / "ashita4"

EXPECTED_RACES = (
    ("hume_male", 1),
    ("hume_female", 2),
    ("elvaan_male", 3),
    ("elvaan_female", 4),
    ("tarutaru_male", 5),
    ("tarutaru_female", 6),
    ("mithra", 7),
    ("galka", 8),
)


class BerserkerDualGreatAxeTests(unittest.TestCase):
    def test_presentation_config_schema_all_8_races_and_diagnostics_disabled_by_default(self):
        self.assertTrue(PRESENTATION_JSON.is_file(), "Missing plugins/ashita4/data/soul-weapon-presentation.json")
        doc = json.loads(PRESENTATION_JSON.read_text(encoding="utf-8"))
        self.assertEqual(doc.get("schemaVersion"), 1)
        self.assertEqual(doc.get("contract"), "SOULSPIRE_WEAPON_PRESENTATION_V1")

        # Diagnostics MUST be disabled by default
        diag = doc.get("diagnostics", {})
        self.assertIs(diag.get("enabled"), False)
        self.assertIs(diag.get("requireDevCommand"), True)

        profiles = doc.get("profiles", {})
        self.assertIn("war_berserker_dual_great_axe", profiles)
        self.assertIn("cor_flintlock_dual_pistols", profiles)

        ber = profiles["war_berserker_dual_great_axe"]
        self.assertIs(ber.get("visualCertified"), False, "Must not claim visual certification without in-game screenshots")
        gate = ber["soulGate"]
        self.assertEqual((gate["job"], gate["branch"], gate["soulKey"]), (1, 2, "berserker"))
        self.assertEqual(gate["minEffectiveLevel"], 10)
        self.assertIs(gate["failClosedWhenUnknown"], True)
        self.assertIs(gate["neverInferFromBaseJob"], True)

        eq_gate = ber["equipmentGate"]
        self.assertEqual(eq_gate["mode"], "dual_2h")
        self.assertEqual(eq_gate["mainSkills"], [6])
        self.assertEqual(eq_gate["subSkills"], [6])
        self.assertIs(eq_gate["requireDistinctItems"], True)
        self.assertIs(eq_gate["preserveActualWeaponModels"], True)

        races = ber["races"]
        self.assertEqual(len(races), 8)
        for race_key, race_id in EXPECTED_RACES:
            self.assertIn(race_key, races)
            entry = races[race_key]
            self.assertEqual(entry["raceId"], race_id)
            for stance in ("drawn", "sheathed"):
                for hand in ("main", "sub"):
                    t = entry[stance][hand]
                    for field in ("translation", "rotationDeg", "gripOffset", "scale", "weaponSeparation", "backDepth"):
                        self.assertIn(field, t)
            # Crossed-back X symmetry and depth separation
            sm = entry["sheathed"]["main"]
            ss = entry["sheathed"]["sub"]
            self.assertAlmostEqual(sm["translation"]["x"], -ss["translation"]["x"], places=4)
            self.assertGreater(sm["rotationDeg"]["roll"], 30.0)
            self.assertLess(ss["rotationDeg"]["roll"], -30.0)
            self.assertAlmostEqual(sm["rotationDeg"]["roll"], -ss["rotationDeg"]["roll"], places=4)
            self.assertGreaterEqual(ss["backDepth"] - sm["backDepth"], 0.025)

    def test_weapon_config_registers_war_berserker_dual_2h_exclusively(self):
        src = WEAPON_CONFIG_LUA.read_text(encoding="utf-8")
        self.assertIn("key = 'berserker'", src)
        self.assertIn("job = W.JOBS.WAR", src)
        self.assertIn("branch = 2", src)
        self.assertIn("mode = W.MODES.DUAL_2H", src)
        self.assertIn("main_skills = { W.SKILLS.GREAT_AXE }", src)
        self.assertIn("sub_skills  = { W.SKILLS.GREAT_AXE }", src)
        self.assertIn("function W.allows_dual_2h_sub_menu", src)

    def test_no_standalone_player_facing_berserker_addon_introduced(self):
        addon_dirs = {p.name.lower() for p in ADDONS_ROOT.iterdir() if p.is_dir()}
        for forbidden in ("soulspire_berserker", "berserker", "dual_great_axe", "soulspire_weapons"):
            self.assertNotIn(forbidden, addon_dirs, f"Must integrate into Soulspire Core/Native, not add {forbidden}")
        self.assertTrue(CORE_WEAPON_PRES_LUA.is_file())
        self.assertTrue(NATIVE_WEAPON_PRES_H.is_file())

    def test_native_selftest_covers_66_soul_exclusivity_and_weapon_presentation(self):
        st = SELFTEST_CPP.read_text(encoding="utf-8")
        self.assertIn("weapon_presentation.h", st)
        self.assertIn("weapon_presentation_checks();", st)
        self.assertIn("allowed_souls == 1u", st)
        self.assertIn("active_local_souls == 1u", st)


if __name__ == "__main__":
    unittest.main()
