"""Regression tests for client DAT spell eligibility, visibility policy, and helpwind text safety."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DAT_114 = ROOT / "dat-overlay/ROM/118/114.DAT"
SOUL_ACTIONS_TSV = ROOT / "addons/ashita4/soulspire_soul_actions/data/soul_actions.tsv"
VISIBILITY_TSV = ROOT / "addons/ashita4/soulspire_soul_actions/data/visibility.tsv"
SOULSPIRE_NATIVE_CPP = ROOT / "soulspire_native/soulspire_native.cpp"
ACTIONS_H = ROOT / "soulspire_native/actions/action_catalog.h"


def _rol(byte: int, shift: int) -> int:
    return ((byte << shift) | (byte >> (8 - shift))) & 0xFF


def _decode_dat_spell_job_level(dat_bytes: bytes, spell_id: int, job_id: int) -> int:
    off = 0x28730 + spell_id * 100
    raw = dat_bytes[off : off + 100]
    for shift in range(8):
        rec_id = _rol(raw[0], shift) | (_rol(raw[1], shift) << 8)
        if rec_id == spell_id and _rol(raw[99], shift) == 0xFF:
            lo = _rol(raw[0x0E + job_id * 2], shift)
            hi = _rol(raw[0x0E + job_id * 2 + 1], shift)
            return lo | (hi << 8)
    raise AssertionError(f"Could not decode spell {spell_id} in 114.DAT")


class SoulSpellClientAuditTests(unittest.TestCase):
    def test_restored_vanilla_spell_levels_in_114_dat(self):
        dat = DAT_114.read_bytes()
        # All 32 previously lowered DRK/RDM/NIN/BLU entries + Utsusemi: Ni (339) must match vanilla.
        vanilla_expected = {
            # DRK (job 8)
            (242, 8): 61, (246, 8): 62, (266, 8): 43, (268, 8): 35, (275, 8): 45, (277, 8): 71,
            # RDM (job 5)
            (312, 5): 58, (313, 5): 56, (314, 5): 54, (315, 5): 52, (316, 5): 50, (317, 5): 60,
            (473, 5): 82, (493, 5): 95, (511, 5): 96,
            # NIN (job 13)
            (320, 13): 15, (323, 13): 15, (326, 13): 15, (329, 13): 15, (332, 13): 15,
            (335, 13): 15, (338, 13): 12, (339, 13): 37, (344, 13): 23, (347, 13): 19,
            # BLU (job 16)
            (581, 16): 16, (593, 16): 58, (632, 16): 67, (658, 16): 76,
            (662, 16): 79, (681, 16): 89, (690, 16): 94, (692, 16): 95,
            # Intentionally retained RUN (job 22) custom/backport definitions
            (363, 22): 10, (364, 22): 55, (477, 22): 75,
        }
        for (spell_id, job_id), expected_lvl in vanilla_expected.items():
            self.assertEqual(
                _decode_dat_spell_job_level(dat, spell_id, job_id),
                expected_lvl,
                f"Spell {spell_id} job {job_id} expected level {expected_lvl}",
            )

    def test_visibility_policy_has_no_duplicates_and_covers_all_required_souls(self):
        seen = set()
        rules = {}
        for line in VISIBILITY_TSV.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            soul, kind, action_id, min_lvl, rule = line.split("\t")
            key = (soul, kind, int(action_id))
            self.assertNotIn(key, seen, f"Duplicate visibility rule for {key}")
            seen.add(key)
            rules[key] = (int(min_lvl), rule)

        dat = DAT_114.read_bytes()

        def effective_spell_allowed(soul, main_job, main_lvl, sub_job, sub_lvl, spell_id):
            if soul is not None and (soul, "spell", spell_id) in rules:
                min_lvl, rule = rules[(soul, "spell", spell_id)]
                if rule == "hidden" or main_lvl < min_lvl:
                    return False
                return True
            main_req = _decode_dat_spell_job_level(dat, spell_id, main_job)
            sub_req = _decode_dat_spell_job_level(dat, spell_id, sub_job) if sub_job else 65535
            return main_lvl >= main_req or sub_lvl >= sub_req

        # Terramancer (GEO 21): Shallow Fault (160) @10, Deep Fault (161) @30
        self.assertTrue(effective_spell_allowed("terramancer", 21, 10, 13, 5, 160))
        self.assertTrue(effective_spell_allowed("terramancer", 21, 30, 13, 15, 161))
        self.assertFalse(effective_spell_allowed("terramancer", 21, 29, 13, 14, 161))
        # Wrong Soul (Diviner GEO10/30) does not inherit Terramancer unlocks
        self.assertFalse(effective_spell_allowed("diviner", 21, 10, 0, 0, 160))
        self.assertFalse(effective_spell_allowed("diviner", 21, 30, 0, 0, 160))

        # WAR20/NIN10 subjob leak checks
        self.assertFalse(effective_spell_allowed(None, 1, 20, 13, 10, 339))
        self.assertFalse(effective_spell_allowed(None, 1, 20, 13, 10, 338))
        # Legitimate vanilla subjob access preserved (WAR24/NIN12 -> Utsusemi: Ichi)
        self.assertTrue(effective_spell_allowed(None, 1, 24, 13, 12, 338))

        # Shinobi (NIN 13): Utsusemi: Ichi @10, Ni @37 (including downsync 37->36)
        self.assertTrue(effective_spell_allowed("shinobi", 13, 10, 0, 0, 338))
        self.assertFalse(effective_spell_allowed("shinobi", 13, 36, 0, 0, 339))
        self.assertTrue(effective_spell_allowed("shinobi", 13, 37, 0, 0, 339))

        # Kagemusha (NIN 13): all 10 Ninjutsu @10; switching to Shinobi at Lv.25 revokes 339 & 329
        for sid in (320, 323, 326, 329, 332, 335, 338, 339, 344, 347):
            self.assertTrue(effective_spell_allowed("kagemusha", 13, 10, 0, 0, sid))
            self.assertFalse(effective_spell_allowed("kagemusha", 13, 9, 0, 0, sid))
        self.assertFalse(effective_spell_allowed("shinobi", 13, 25, 0, 0, 339))
        self.assertFalse(effective_spell_allowed("shinobi", 13, 25, 0, 0, 329))

        # Dreadnought (DRK 8): Drain II (246) & Dread Spikes (277) @10; Absorb-VIT (268) vanilla 35; wrong Soul Reaper blocked
        self.assertTrue(effective_spell_allowed("dreadnought", 8, 10, 0, 0, 246))
        self.assertTrue(effective_spell_allowed("dreadnought", 8, 10, 0, 0, 277))
        self.assertFalse(effective_spell_allowed("dreadnought", 8, 9, 0, 0, 246))
        self.assertFalse(effective_spell_allowed("dreadnought", 8, 10, 0, 0, 268))
        self.assertFalse(effective_spell_allowed("reaper", 8, 10, 0, 0, 246))
        self.assertFalse(effective_spell_allowed(None, 1, 20, 8, 10, 246))

        # Crimson Duelist (RDM 5): follows vanilla RDM progression; no Lv.10 Enfire II/Haste II leak
        self.assertFalse(effective_spell_allowed("crimsonduelist", 5, 10, 0, 0, 312))
        self.assertTrue(effective_spell_allowed("crimsonduelist", 5, 58, 0, 0, 312))
        self.assertFalse(effective_spell_allowed("crimsonduelist", 5, 75, 0, 0, 511))
        self.assertFalse(effective_spell_allowed(None, 1, 20, 5, 10, 312))

        # Magus (BLU 16): baseline healing/utility spells @10; wrong Soul Warmage & /BLU subjob blocked
        for sid in (530, 542, 578, 581, 592, 593, 623, 632, 647, 658, 662, 681, 690, 692):
            self.assertTrue(effective_spell_allowed("magus", 16, 10, 0, 0, sid))
            self.assertFalse(effective_spell_allowed("magus", 16, 9, 0, 0, sid))
        self.assertFalse(effective_spell_allowed("warmage", 16, 10, 0, 0, 593))
        self.assertFalse(effective_spell_allowed(None, 1, 20, 16, 10, 581))

        # Spellblade (RUN 22): Runic Bolt (363) @10, Runic Sever (364) @55; Inquisitor/Lifebinder hidden
        self.assertTrue(effective_spell_allowed("spellblade", 22, 10, 0, 0, 363))
        self.assertFalse(effective_spell_allowed("spellblade", 22, 54, 0, 0, 364))
        self.assertTrue(effective_spell_allowed("spellblade", 22, 55, 0, 0, 364))
        self.assertFalse(effective_spell_allowed("inquisitor", 22, 75, 0, 0, 363))
        self.assertFalse(effective_spell_allowed("lifebinder", 22, 75, 0, 0, 364))
        self.assertTrue(effective_spell_allowed("inquisitor", 22, 75, 0, 0, 477))

        # Ordinary vanilla jobs (no active Soul)
        self.assertFalse(effective_spell_allowed(None, 8, 60, 0, 0, 242))
        self.assertTrue(effective_spell_allowed(None, 8, 61, 0, 0, 242))
        self.assertFalse(effective_spell_allowed(None, 16, 57, 0, 0, 593))
        self.assertTrue(effective_spell_allowed(None, 16, 58, 0, 0, 593))

    def test_soul_actions_tsv_is_pure_ascii_printable(self):
        lines = SOUL_ACTIONS_TSV.read_text(encoding="utf-8").splitlines()
        bad = []
        for idx, line in enumerate(lines, start=1):
            if not line or line.startswith("#"):
                continue
            for ch in line:
                code = ord(ch)
                if ch != "\t" and (code < 0x20 or code > 0x7E):
                    bad.append((idx, ch, hex(code)))
        self.assertEqual(bad, [], f"Non-ASCII/control characters in soul_actions.tsv: {bad}")

    def test_visibility_policy_has_terramancer_shinobi_kagemusha_rules(self):
        rows = set()
        for line in VISIBILITY_TSV.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            rows.add(tuple(line.split("\t")))
        self.assertIn(("terramancer", "spell", "159", "10", "unlock"), rows)
        self.assertIn(("terramancer", "spell", "160", "10", "unlock"), rows)
        self.assertIn(("terramancer", "spell", "161", "30", "unlock"), rows)
        self.assertIn(("shinobi", "spell", "338", "10", "unlock"), rows)
        self.assertIn(("shinobi", "spell", "339", "37", "unlock"), rows)
        self.assertIn(("kagemusha", "spell", "339", "10", "unlock"), rows)

    def test_soulspire_native_detours_can_use_spell_and_formats_descriptions(self):
        cpp = SOULSPIRE_NATIVE_CPP.read_text(encoding="utf-8")
        hdr = ACTIONS_H.read_text(encoding="utf-8")
        self.assertIn("can_use_spell_detour{0x22CDE0", cpp)
        self.assertIn("missing_spell_bit_detour{0x22CB44", cpp)
        self.assertIn("d->install(base, tramp_out)", cpp)
        self.assertIn("detour_at(j)->restore()", cpp)
        self.assertIn("{0x22E64D, reinterpret_cast<void*>(&menu_spell_elig_hook)}", cpp)
        self.assertIn("original_spell_elig = reinterpret_cast<uintptr_t>(base + 0x1021A0)", cpp)
        self.assertIn("format_action_description(", cpp)
        self.assertIn("format_action_description(", hdr)
        self.assertIn("ch < 0x20u || ch >= 0x7Fu", hdr)


if __name__ == "__main__":
    unittest.main()
