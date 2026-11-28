import hashlib
import json
import struct
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
COMPANIONS_JSON = REPO_ROOT / "addons" / "vanacore" / "soulspire_core" / "data" / "soul-companions.json"
CRYSTALS_DIR = REPO_ROOT / "addons" / "vanacore" / "soulspire_core" / "assets" / "crystals"
TESTING_MANIFEST = REPO_ROOT / "channels" / "testing" / "manifest.json"
NEUTRAL_ICON = CRYSTALS_DIR / "echo_neutral.png"


def read_png_header(path: Path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a valid PNG"
    width, height, bit_depth, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, bit_depth, color_type, len(data), hashlib.sha256(data).hexdigest()


class EchoPartyIconsTest(unittest.TestCase):
    def test_all_66_souls_have_unique_valid_square_png_icons(self):
        payload = json.loads(COMPANIONS_JSON.read_text(encoding="utf-8"))
        companions = payload.get("companions", [])
        self.assertEqual(len(companions), 66, "Expected all 66 canonical Souls in soul-companions.json")

        seen_assets = set()
        seen_keys = set()
        for entry in companions:
            key = entry.get("canonicalKey", "")
            icon_asset = entry.get("iconAsset", "")
            self.assertTrue(key, f"Missing canonicalKey in {entry}")
            self.assertNotIn(key, seen_keys, f"Duplicate canonicalKey: {key}")
            seen_keys.add(key)

            self.assertTrue(
                icon_asset.startswith("assets/crystals/") and icon_asset.endswith(".png"),
                f"Unexpected iconAsset for {key}: {icon_asset}",
            )
            self.assertNotIn(icon_asset, seen_assets, f"Soul {key} shares non-unique iconAsset {icon_asset}")
            seen_assets.add(icon_asset)

            png_path = REPO_ROOT / "addons" / "vanacore" / "soulspire_core" / icon_asset
            self.assertTrue(png_path.is_file(), f"Missing icon PNG for {key}: {png_path}")
            w, h, _bd, color_type, size, _sha = read_png_header(png_path)
            self.assertGreaterEqual(w, 32, f"{png_path.name} too small ({w}x{h})")
            self.assertEqual(w, h, f"{png_path.name} must preserve 1:1 aspect ratio ({w}x{h})")
            if color_type == 3:
                self.assertIn(b"tRNS", png_path.read_bytes(), f"{png_path.name} (indexed) must include tRNS transparency")
            else:
                self.assertIn(color_type, (4, 6), f"{png_path.name} must preserve alpha transparency")
            self.assertGreater(size, 100)

        self.assertEqual(len(seen_assets), 66)

    def test_neutral_echo_fallback_icon_present_and_in_testing_manifest(self):
        self.assertTrue(NEUTRAL_ICON.is_file(), "Missing neutral Echo fallback icon echo_neutral.png")
        w, h, _bd, color_type, size, sha = read_png_header(NEUTRAL_ICON)
        self.assertEqual((w, h), (64, 64))
        self.assertEqual(color_type, 6, "echo_neutral.png must be RGBA with transparency")

        manifest = json.loads(TESTING_MANIFEST.read_text(encoding="utf-8"))
        by_target = {e.get("targetPath"): e for e in manifest.get("files", [])}
        target = "vanacore/soulspire_core/assets/crystals/echo_neutral.png"
        self.assertIn(target, by_target, "echo_neutral.png must be tracked in channels/testing/manifest.json")
        self.assertEqual(by_target[target].get("sha256"), sha)
        self.assertEqual(by_target[target].get("size"), size)


if __name__ == "__main__":
    unittest.main()
