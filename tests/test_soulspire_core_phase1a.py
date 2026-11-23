import hashlib
import os
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE_DIR = ROOT / "addons" / "ashita4" / "soulspire_core"
LAUNCHER_CREST = ROOT / "SoulspireLauncher" / "Assets" / "app.png"
CORE_CREST = CORE_DIR / "assets" / "soulspire_crest.png"


class SoulspireCorePhase1ATests(unittest.TestCase):
    def test_lua_unit_suite_passes(self):
        test_file = CORE_DIR / "tests" / "soulspire_core_test.lua"
        self.assertTrue(test_file.is_file(), "Missing soulspire_core_test.lua")
        try:
            from lupa.luajit21 import LuaRuntime  # type: ignore[import-not-found]
        except ImportError:
            LuaRuntime = None

        if LuaRuntime is not None:
            prev_cwd = os.getcwd()
            try:
                os.chdir(str(CORE_DIR))
                LuaRuntime().execute(f"dofile({str(test_file)!r})")
            finally:
                os.chdir(prev_cwd)
            return

        luajit_bin = shutil.which("luajit")
        if not luajit_bin:
            self.skipTest("luajit/lupa not installed in this step; covered by run_soul_lua_tests.py")

        proc = subprocess.run(
            [luajit_bin, str(test_file)],
            cwd=str(CORE_DIR),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"soulspire_core LuaJIT tests failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}",
        )
        self.assertIn("SoulspireXI Core Phase 1A tests passed.", proc.stdout)

    def test_verified_crest_asset_matches_launcher_app_png(self):
        self.assertTrue(LAUNCHER_CREST.is_file(), "Missing SoulspireLauncher/Assets/app.png")
        self.assertTrue(CORE_CREST.is_file(), "Missing soulspire_core/assets/soulspire_crest.png")
        self.assertEqual(
            hashlib.sha256(LAUNCHER_CREST.read_bytes()).hexdigest(),
            hashlib.sha256(CORE_CREST.read_bytes()).hexdigest(),
            "soulspire_crest.png must match verified SoulspireLauncher/Assets/app.png",
        )

    def test_launcher_config_generator_loads_soulspire_core_and_preserves_existing_addons(self):
        gen = (ROOT / "SoulspireLauncher" / "Services" / "AshitaConfigGenerator.cs").read_text(
            encoding="utf-8"
        )
        for required in (
            '"/addon load soulspire_core"',
            '"/addon unload soulspire_core"',
            '"/load soulspire_native"',
            '"/addon load crystalsocket"',
            '"/addon load soulspire_talents"',
            '"/addon load soulspire_soulhud"',
            '"/addon load soulspire_soul_actions"',
            '"/addon load soulspire_flintlock"',
        ):
            self.assertIn(required, gen, f"AshitaConfigGenerator.cs missing {required}")

    def test_phase1a_audit_doc_exists_and_identifies_fallback_honestly(self):
        doc = ROOT / "docs" / "phase1a-native-menu-audit.md"
        self.assertTrue(doc.is_file(), "Missing docs/phase1a-native-menu-audit.md")
        text = doc.read_text(encoding="utf-8")
        self.assertIn("FFXiMain.dll", text)
        self.assertIn("native-styled fallback", text.lower())
        self.assertIn("crystaljobs.dll", text)


if __name__ == "__main__":
    unittest.main()
