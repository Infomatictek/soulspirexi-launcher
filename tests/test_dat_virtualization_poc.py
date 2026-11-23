"""Launcher-side validation for Phase F registry-driven DAT text virtualization POC."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DAT_OVERRIDES_PATH = REPO_ROOT / "plugins" / "ashita4" / "data" / "dat-text-overrides.json"
REG_SYNC_PATH = REPO_ROOT / "registry_sync.json"


def _compute_fnv1a64(entries: list[dict]) -> str:
    h = 14695981039346656037
    mask = (1 << 64) - 1
    for e in sorted(entries, key=lambda x: (int(x["jobId"]), int(x["branch"]), int(x["kind"]), int(x["actionId"]))):
        line = (
            f"{int(e['jobId'])}:{int(e['branch'])}:{int(e['kind'])}:{int(e['actionId'])}:"
            f"{e['name']}:{e['description']}:{int(e['iconId'])}:{int(e['iconIdV2'])}\n"
        )
        for b in line.encode("ascii"):
            h ^= b
            h = (h * 1099511628211) & mask
    return f"{h:016x}"


class DatVirtualizationPocLauncherTests(unittest.TestCase):
    def test_dat_text_overrides_json_matches_registry_hash_and_fnv1a_integrity(self) -> None:
        self.assertTrue(DAT_OVERRIDES_PATH.is_file(), "Missing plugins/ashita4/data/dat-text-overrides.json")
        doc = json.loads(DAT_OVERRIDES_PATH.read_text(encoding="utf-8"))
        reg_sync = json.loads(REG_SYNC_PATH.read_text(encoding="utf-8"))

        self.assertEqual(doc["schemaVersion"], 1)
        self.assertEqual(doc["registryHash"], reg_sync["registryHash"])
        self.assertGreaterEqual(doc["overrideCount"], 160)
        self.assertEqual(doc["overrideCount"], len(doc["overrides"]))
        self.assertEqual(doc["integrityFnv1a64"], _compute_fnv1a64(doc["overrides"]))

        # Verify Soul-scoped isolation on shared spell ID 28 (WHM Zealot vs WHM Valkyrie)
        by_key = {(e["jobId"], e["branch"], e["kind"], e["actionId"]): e for e in doc["overrides"]}
        self.assertEqual(by_key[(3, 2, 1, 28)]["name"], "Dawnfire")
        self.assertEqual(by_key[(3, 3, 1, 28)]["name"], "Vigil Lance")

    def test_dat_virtualization_architecture_doc_and_native_wiring_exist(self) -> None:
        arch = (REPO_ROOT / "docs" / "dat-virtualization-architecture.md").read_text(encoding="utf-8")
        self.assertIn("Feasibility Matrix", arch)
        self.assertIn("Dynamically overridable", arch)
        self.assertIn("Requires generated DAT overlay", arch)

        hdr = (REPO_ROOT / "soulspire_native" / "dat_virtualization" / "dat_virtualization.h").read_text(encoding="utf-8")
        self.assertIn("parse_dat_text_overrides_json", hdr)
        self.assertIn("lookup_text", hdr)
        self.assertIn("integrityFnv1a64", hdr)


if __name__ == "__main__":
    unittest.main()
