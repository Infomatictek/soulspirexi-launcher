import json
import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = (
    REPO_ROOT
    / "addons"
    / "vanacore"
    / "soulspire_core"
    / "data"
    / "soul-dynamic-spellbooks.json"
)
HUD_LAYOUT_PATH = (
    REPO_ROOT
    / "addons"
    / "vanacore"
    / "soulspire_core"
    / "soulhud"
    / "soulhud_layout.lua"
)


class DynamicSpellbookManifestTests(unittest.TestCase):
    def test_manifest_exists_and_has_24_necromancer_spells(self):
        self.assertTrue(MANIFEST_PATH.exists(), f"Missing {MANIFEST_PATH}")
        data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        self.assertEqual(data.get("schemaVersion"), "1.0.0")
        self.assertTrue(data.get("spellbookHash"))
        books = data.get("spellbooks", [])
        self.assertGreaterEqual(len(books), 1)
        necro = next((b for b in books if b.get("canonicalKey") == "necromancer"), None)
        self.assertIsNotNone(necro, "Missing necromancer spellbook")
        self.assertEqual(necro["soulId"], "blm_tank")
        self.assertEqual(necro["jobId"], 4)
        self.assertEqual(necro["branchId"], 3)
        self.assertTrue(necro["replaceBaseJobSpells"])
        self.assertTrue(necro["preserveLearnedSpells"])
        spells = necro["spells"]
        self.assertEqual(len(spells), 24)
        ids = [s["spellId"] for s in spells]
        self.assertEqual(len(ids), len(set(ids)), "Duplicate spellIds in manifest")
        for s in spells:
            self.assertNotIn(s["spellId"], range(896, 1018), "Collides with Trust/Companion range")
            self.assertNotIn(s["spellId"], (363, 364), "Collides with RUN Spellblade spells")
            self.assertEqual(s["clientMagicType"], 2)
            self.assertTrue(s["name"])
            self.assertTrue(s["description"])

    def test_necromancer_hud_has_reanimate_and_mp_and_zero_ashita(self):
        text = HUD_LAYOUT_PATH.read_text(encoding="utf-8")
        self.assertIn("REANIMATE READY", text)
        self.assertIn("thrall_mpp", text)
        self.assertIn("active_buffs", text)
        self.assertNotIn("AshitaCore", text)


if __name__ == "__main__":
    unittest.main()
