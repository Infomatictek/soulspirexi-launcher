"""Automated verification for runtime Search badge spacing and 66-Soul identity parity."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
IDENTITIES_PATH = REPO_ROOT / "plugins" / "ashita4" / "data" / "soul-identities.json"
PRESENTATION_PATH = REPO_ROOT / "plugins" / "ashita4" / "data" / "crystaljobs-presentation.json"

MENU_GLYPH_WIDTHS = {
    "A": 7, "B": 8, "C": 8, "D": 8, "E": 7, "F": 8, "G": 8, "H": 7, "I": 8,
    "J": 8, "K": 8, "L": 7, "M": 8, "N": 8, "O": 7, "P": 8, "Q": 8, "R": 8,
    "S": 8, "T": 7, "U": 8, "V": 8, "W": 8, "X": 8, "Y": 8, "Z": 8,
}


def compute_layout(abbr: str, tracking_px: int, offset_x_px: int, use_glyph_widths: bool) -> tuple[list[int], int]:
    ws = [MENU_GLYPH_WIDTHS[c] for c in abbr]
    x = [offset_x_px, 0, 0]
    for i in range(2):
        step = max(4, (ws[i] if use_glyph_widths else 8) + tracking_px)
        x[i + 1] = x[i] + step
    right_edge = x[2] + ws[2]
    if right_edge > 24:
        shift = min(right_edge - 24, x[0] - (-2))
        if shift > 0:
            x = [v - shift for v in x]
        max_x2 = 24 - ws[2]
        if x[2] > max_x2:
            x[2] = max_x2
            mid = x[0] + (x[2] - x[0]) // 2
            if x[1] > mid:
                x[1] = mid
    return x, x[2] + ws[2]


class SearchPresentationSpacingTests(unittest.TestCase):
    def test_presentation_config_eliminates_narrow_glyph_overlap_and_preserves_gmb_bkw(self):
        cfg = json.loads(PRESENTATION_PATH.read_text(encoding="utf-8"))
        self.assertEqual(cfg["schemaVersion"], 1)
        badge = cfg["searchBadge"]
        self.assertEqual(badge["trackingPx"], -1)
        self.assertEqual(badge["offsetXPx"], 0)
        self.assertFalse(badge["useGlyphWidths"])

        for abbr in ("HEL", "GMB", "BKW", "GOE", "THV", "FLT", "KEN", "IRN", "SEI"):
            xs, right_edge = compute_layout(abbr, badge["trackingPx"], badge["offsetXPx"], badge["useGlyphWidths"])
            self.assertEqual(xs, [0, 7, 14], f"{abbr} must use uniform 7px pitch [0, 7, 14]")
            self.assertGreaterEqual(xs[1] - xs[0], 7)
            self.assertGreaterEqual(xs[2] - xs[1], 7)
            self.assertLessEqual(right_edge, 22, f"{abbr} right edge {right_edge} must stay clear of +23 level digits")

    def test_all_66_souls_unique_and_within_search_bounds(self):
        ident = json.loads(IDENTITIES_PATH.read_text(encoding="utf-8"))
        cfg = json.loads(PRESENTATION_PATH.read_text(encoding="utf-8"))["searchBadge"]
        self.assertEqual(ident["schemaVersion"], 1)
        self.assertEqual(ident["soulCount"], 66)
        self.assertEqual(len(ident["souls"]), 66)

        seen: set[str] = set()
        for entry in ident["souls"]:
            abbr = entry["abbr"]
            self.assertEqual(len(abbr), 3)
            self.assertTrue(abbr.isalpha() and abbr.isupper())
            self.assertNotIn(abbr, seen)
            seen.add(abbr)
            xs, right_edge = compute_layout(abbr, cfg["trackingPx"], cfg["offsetXPx"], cfg["useGlyphWidths"])
            self.assertEqual(xs, [0, 7, 14])
            self.assertLessEqual(right_edge, 22)


if __name__ == "__main__":
    unittest.main()
