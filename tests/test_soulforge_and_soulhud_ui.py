import os
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ADDONS_DIR = ROOT / "addons" / "ashita4"


def _run_lua_suite(addon_dir: pathlib.Path, rel_test: str, expected_banner: str) -> None:
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

    luajit_bin = shutil.which("luajit")
    if not luajit_bin:
        raise unittest.SkipTest("luajit/lupa not installed in this environment")

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
    if expected_banner not in proc.stdout:
        raise AssertionError(f"Expected {expected_banner!r} in stdout:\n{proc.stdout}")


class SoulforgeAndSoulHudUITests(unittest.TestCase):
    def test_core_ui_foundations_lua_suite(self):
        _run_lua_suite(
            ADDONS_DIR / "soulspire_core",
            "tests/foundations_test.lua",
            "SoulspireXI Core UI Foundations tests passed.",
        )

    def test_soulforge_ws_talents_lua_suite(self):
        _run_lua_suite(
            ADDONS_DIR / "soulspire_talents",
            "tests/soulforge_test.lua",
            "SoulspireXI The Soulforge tests passed.",
        )

    def test_universal_soul_hud_lua_suite(self):
        _run_lua_suite(
            ADDONS_DIR / "soulspire_soulhud",
            "tests/soulhud_gauge_test.lua",
            "SoulspireXI Universal Soul HUD tests passed.",
        )


if __name__ == "__main__":
    unittest.main()
