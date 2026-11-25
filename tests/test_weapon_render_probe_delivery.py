import hashlib
import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE_LUA = REPO_ROOT / "addons" / "ashita4" / "soulspire_core" / "core" / "weapon_render_probe.lua"
CORE_LUA = REPO_ROOT / "addons" / "ashita4" / "soulspire_core" / "soulspire_core.lua"
STABLE_MANIFEST = REPO_ROOT / "manifest.json"
TESTING_MANIFEST = REPO_ROOT / "channels" / "testing" / "manifest.json"
PUBLISH_TESTING_SCRIPT = REPO_ROOT / "scripts" / "publish-testing-channel.py"


def sha256_file(path: pathlib.Path) -> tuple[str, int]:
    raw = path.read_bytes()
    return hashlib.sha256(raw).hexdigest(), len(raw)


class WeaponRenderProbeDeliveryTest(unittest.TestCase):
    def test_manifests_match_disk_probe_and_core_sha256(self) -> None:
        probe_sha, probe_size = sha256_file(PROBE_LUA)
        core_sha, core_size = sha256_file(CORE_LUA)

        for manifest_path in (STABLE_MANIFEST, TESTING_MANIFEST):
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            by_source = {entry.get("sourcePath"): entry for entry in data.get("files", [])}

            probe_entry = by_source.get("addons/ashita4/soulspire_core/core/weapon_render_probe.lua")
            self.assertIsNotNone(probe_entry, f"weapon_render_probe.lua missing from {manifest_path.name}")
            self.assertEqual(probe_entry["sha256"], probe_sha, f"probe SHA-256 mismatch in {manifest_path}")
            self.assertEqual(probe_entry["size"], probe_size, f"probe size mismatch in {manifest_path}")

            core_entry = by_source.get("addons/ashita4/soulspire_core/soulspire_core.lua")
            self.assertIsNotNone(core_entry, f"soulspire_core.lua missing from {manifest_path.name}")
            self.assertEqual(core_entry["sha256"], core_sha, f"soulspire_core SHA-256 mismatch in {manifest_path}")
            self.assertEqual(core_entry["size"], core_size, f"soulspire_core size mismatch in {manifest_path}")

    def test_probe_lua_contains_mandatory_provenance_and_required_sections(self) -> None:
        text = PROBE_LUA.read_text(encoding="utf-8")
        testing_manifest = json.loads(TESTING_MANIFEST.read_text(encoding="utf-8"))
        testing_ver = testing_manifest.get("manifestVersion", "")
        self.assertTrue(testing_ver.startswith("2.2.0-testing."), f"unexpected testing manifestVersion: {testing_ver}")

        required_tokens = [
            "M.PROBE_VERSION",
            f"M.PROBE_SOURCE_COMMIT   = '{testing_ver}'",
            "M.LOADED_LUA_PATH",
            "build_unique_output_path",
            '"captureId"',
            '"generatedAtUtc"',
            '"probeVersion"',
            '"probeSourceCommit"',
            '"loadedLuaPath"',
            '"activeLauncherManifestVersion"',
            '"nativeDllVersion"',
            '"captureLabels"',
            '"requiredDiagnosticSections"',
            '"outputPath"',
            "attach_equip_model_downstream_slices",
            "0xCFA50",
            "0x29D30",
            "0x6B8_modelPart0",
        ]
        for tok in required_tokens:
            self.assertIn(tok, text, f"weapon_render_probe.lua missing required token: {tok}")

    def test_publish_testing_script_has_no_probe_override(self) -> None:
        script_text = PUBLISH_TESTING_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("weapon_render_probe", script_text)


if __name__ == "__main__":
    unittest.main()
