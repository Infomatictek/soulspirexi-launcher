"""Automated verification of SoulspireXI Core client cache, SHA-256 verification,
sync protocols, packet coexistence, and launcher manifests."""
from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path

LAUNCHER_ROOT = Path(__file__).resolve().parent.parent


def _find_lua_bin() -> str:
    for cand in ("luajit", "lua", "lua5.1"):
        if shutil.which(cand):
            return cand
    raise RuntimeError("No LuaJIT/Lua interpreter found on PATH")


class TestClientCacheAndSync(unittest.TestCase):
    def test_core_cache_and_sync_luajit_suite(self) -> None:
        lua_bin = _find_lua_bin()
        core_dir = LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_core"
        proc = subprocess.run(
            [lua_bin, "tests/cache_and_sync_test.lua"],
            cwd=str(core_dir),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, f"cache_and_sync_test.lua failed:\nSTDOUT:{proc.stdout}\nSTDERR:{proc.stderr}")
        self.assertIn("CACHE_SYNC_TEST_OK", proc.stdout)

    def test_existing_soulspire_core_suite_passes(self) -> None:
        lua_bin = _find_lua_bin()
        core_dir = LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_core"
        proc = subprocess.run(
            [lua_bin, "tests/soulspire_core_test.lua"],
            cwd=str(core_dir),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, f"soulspire_core_test.lua failed:\nSTDOUT:{proc.stdout}\nSTDERR:{proc.stderr}")

    def test_existing_standalone_soulforge_suite_passes(self) -> None:
        lua_bin = _find_lua_bin()
        tal_dir = LAUNCHER_ROOT / "addons" / "ashita4" / "soulspire_talents"
        proc = subprocess.run(
            [lua_bin, "tests/soulforge_test.lua"],
            cwd=str(tal_dir),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, f"soulforge_test.lua failed:\nSTDOUT:{proc.stdout}\nSTDERR:{proc.stderr}")

    def test_manifests_and_cache_integrity_verify_cleanly(self) -> None:
        for mf in (LAUNCHER_ROOT / "manifest.json", LAUNCHER_ROOT / "channels" / "testing-core-ui" / "manifest.json"):
            proc = subprocess.run(
                ["python3", str(LAUNCHER_ROOT / "scripts" / "verify-launcher-manifest.py"), str(LAUNCHER_ROOT), "--manifest", str(mf)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"verify-launcher-manifest failed for {mf}:\n{proc.stdout}\n{proc.stderr}")


if __name__ == "__main__":
    unittest.main()
