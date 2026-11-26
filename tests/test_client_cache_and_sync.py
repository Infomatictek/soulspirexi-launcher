"""Automated verification of SoulspireXI Core client cache, SHA-256 verification,
sync protocols, packet coexistence, and launcher manifests."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

LAUNCHER_ROOT = Path(__file__).resolve().parent.parent


def _run_lua_suite(addon_dir: Path, rel_test: str, expected_banner: str | None = None) -> None:
    test_file = addon_dir / rel_test
    if not test_file.is_file():
        raise AssertionError(f"Missing Lua test file: {test_file}")

    try:
        from lupa.luajit21 import LuaRuntime  # type: ignore[import-not-found]
    except ImportError:
        LuaRuntime = None

    if LuaRuntime is not None:
        prev_cwd = os.getcwd()
        try:
            os.chdir(str(addon_dir))
            LuaRuntime().execute(f"dofile({str(test_file)!r})")
        finally:
            os.chdir(prev_cwd)
        return

    luajit_bin = shutil.which("luajit") or shutil.which("lua") or shutil.which("lua5.1")
    if not luajit_bin:
        raise unittest.SkipTest("luajit/lupa not installed in this step; covered by run_soul_lua_tests.py")

    proc = subprocess.run(
        [luajit_bin, str(test_file)],
        cwd=str(addon_dir),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"{rel_test} failed (rc={proc.returncode}):\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    if expected_banner and expected_banner not in proc.stdout:
        raise AssertionError(f"Expected {expected_banner!r} in stdout:\n{proc.stdout}")


class TestClientCacheAndSync(unittest.TestCase):
    def test_core_cache_and_sync_luajit_suite(self) -> None:
        _run_lua_suite(
            LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_core",
            "tests/cache_and_sync_test.lua",
            "CACHE_SYNC_TEST_OK",
        )

    def test_sync_reliability_stress_luajit_suite(self) -> None:
        _run_lua_suite(
            LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_core",
            "tests/sync_reliability_test.lua",
            "SYNC_RELIABILITY_OK",
        )

    def test_character_state_reactive_luajit_suite(self) -> None:
        _run_lua_suite(
            LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_core",
            "tests/character_state_test.lua",
            "CHARACTER_STATE_TEST_OK",
        )

    def test_mouse_lifecycle_luajit_suite(self) -> None:
        _run_lua_suite(
            LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_core",
            "tests/mouse_lifecycle_test.lua",
            "PASS: all 12 SoulspireXI Core mouse/cursor lifecycle regression scenarios passed!",
        )

    def test_existing_soulspire_core_suite_passes(self) -> None:
        _run_lua_suite(
            LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_core",
            "tests/soulspire_core_test.lua",
            "SoulspireXI Core Unified UI & Gamepad tests passed.",
        )

    def test_existing_standalone_soulforge_suite_passes(self) -> None:
        _run_lua_suite(
            LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_talents",
            "tests/soulforge_test.lua",
            "SoulspireXI The Soulforge tests passed.",
        )

    def test_manifests_and_cache_integrity_verify_cleanly(self) -> None:
        for mf in (
            LAUNCHER_ROOT / "manifest.json",
            LAUNCHER_ROOT / "channels" / "testing" / "manifest.json",
            LAUNCHER_ROOT / "channels" / "testing-core-ui" / "manifest.json",
        ):
            proc = subprocess.run(
                [sys.executable, str(LAUNCHER_ROOT / "scripts" / "verify-launcher-manifest.py"), str(LAUNCHER_ROOT), "--manifest", str(mf)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"verify-launcher-manifest failed for {mf}:\n{proc.stdout}\n{proc.stderr}")

    def test_verify_manifest_rejects_mismatched_registry_native_dll_sha256(self) -> None:
        import tempfile

        testing_manifest = json.loads(
            (LAUNCHER_ROOT / "channels" / "testing" / "manifest.json").read_text(encoding="utf-8")
        )
        dll_entry = next(
            f for f in testing_manifest["files"]
            if f.get("category") == "plugin" and f.get("targetPath", "").replace("\\", "/").endswith("soulspire_native.dll")
        )
        self.assertEqual(
            testing_manifest["registry"]["nativeDllSha256"].lower(),
            dll_entry["sha256"].lower(),
            "channels/testing/manifest.json registry.nativeDllSha256 must match soulspire_native.dll entry",
        )
        testing_manifest["registry"]["nativeDllSha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as td:
            bad_manifest = Path(td) / "manifest.json"
            bad_manifest.write_text(json.dumps(testing_manifest, indent=2), encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(LAUNCHER_ROOT / "scripts" / "verify-launcher-manifest.py"), str(LAUNCHER_ROOT), "--manifest", str(bad_manifest)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc.returncode, 0, "Verifier must reject mismatched registry.nativeDllSha256")
            self.assertIn("registry.nativeDllSha256", proc.stdout + proc.stderr)

    def test_testing_core_ui_staging_server_config_and_stable_isolation(self) -> None:
        testing_manifest = json.loads(
            (LAUNCHER_ROOT / "channels" / "testing-core-ui" / "manifest.json").read_text(encoding="utf-8")
        )
        staging = testing_manifest.get("stagingServer")
        self.assertIsInstance(staging, dict)
        self.assertEqual(staging.get("host"), "192.168.86.117")
        self.assertFalse(staging.get("useHairpin"))
        self.assertEqual(staging.get("localLoopbackHost"), "127.0.0.1")
        self.assertEqual(
            staging.get("ports"),
            {
                "auth": 55231,
                "data": 55230,
                "view": 55001,
                "search": 55002,
                "profile": 51221,
                "profileIrc": 51241,
                "map": 55230,
            },
        )

        stable_manifest = json.loads((LAUNCHER_ROOT / "manifest.json").read_text(encoding="utf-8"))
        self.assertNotIn("stagingServer", stable_manifest)
        self.assertEqual(stable_manifest.get("defaultHost"), "play.soulspirexi.com")


if __name__ == "__main__":
    unittest.main()
