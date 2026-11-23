import pathlib
import re
import struct
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE_DIR = ROOT / "soulspire_native"
CS_DIR = ROOT / "addons" / "ashita4" / "crystalsocket"
SHIPPED_DLL = ROOT / "plugins" / "ashita4" / "soulspire_native.dll"


def parse_pe32_exports(path: pathlib.Path):
    data = path.read_bytes()
    if data[:2] != b"MZ":
        raise AssertionError("Missing MZ DOS signature")
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_off : pe_off + 4] != b"PE\x00\x00":
        raise AssertionError("Missing PE signature")
    machine, num_sections, _, _, _, opt_size, chars = struct.unpack_from("<HHIIIHH", data, pe_off + 4)
    opt_off = pe_off + 24
    magic = struct.unpack_from("<H", data, opt_off)[0]
    export_rva, export_size = struct.unpack_from("<II", data, opt_off + 96)

    sections = []
    sec_off = opt_off + opt_size
    for i in range(num_sections):
        off = sec_off + i * 40
        vsize, vaddr, rsize, rptr = struct.unpack_from("<IIII", data, off + 8)
        sections.append((vaddr, max(vsize, rsize), rptr))

    def rva_to_off(rva: int) -> int:
        for vaddr, span, rptr in sections:
            if vaddr <= rva < vaddr + span:
                return rptr + (rva - vaddr)
        raise AssertionError(f"Unmapped RVA 0x{rva:x}")

    names = []
    if export_rva and export_size:
        exp_off = rva_to_off(export_rva)
        num_names = struct.unpack_from("<I", data, exp_off + 24)[0]
        names_rva = struct.unpack_from("<I", data, exp_off + 32)[0]
        names_off = rva_to_off(names_rva)
        for i in range(num_names):
            name_rva = struct.unpack_from("<I", data, names_off + i * 4)[0]
            name_off = rva_to_off(name_rva)
            end = data.index(b"\x00", name_off)
            names.append(data[name_off:end].decode("ascii"))
    return machine, magic, chars, names


class NativeEquipmentHookTests(unittest.TestCase):
    def test_layout_contains_verified_27_hook_weapon_signatures(self):
        layout = (NATIVE_DIR / "hooks" / "layout.h").read_text(encoding="utf-8")
        self.assertIn("{0x133D56, {0x68, 0x8b, 0x00, 0x00, 0x00, 0xe8, 0x60, 0x75, 0xff, 0xff", layout)
        self.assertIn("{0x21DF85, {0x85, 0x46, 0xf4, 0x74, 0x5f, 0x8b, 0x42, 0x0c", layout)
        self.assertIn("{0x133DD3, {0x68, 0x99, 0x00, 0x00, 0x00, 0xe8, 0xe3, 0x74, 0xff, 0xff", layout)
        self.assertIn("{0x133E33, {0xe8, 0x48, 0xf7, 0xff, 0xff, 0x84, 0xc0, 0x75, 0x24, 0xfe", layout)
        self.assertIn("{0xEB5D0,  {0x8b, 0x15, 0x48, 0x0f, 0x4e, 0x10", layout)
        self.assertIn("{0x15D210, {0xb8, 0xac, 0x15, 0x00, 0x00, 0xe8, 0x76, 0x65, 0x1b, 0x00", layout)

    def test_soulspire_native_header_and_exports_define_canonical_and_compat_abi(self):
        header = (NATIVE_DIR / "core" / "api.h").read_text(encoding="utf-8")
        compat = (NATIVE_DIR / "compatibility" / "crystaljobs_compat.h").read_text(encoding="utf-8")
        for sym in (
            "SOULSPIRE_NATIVE_ABI_VERSION",
            "SOULSPIRE_NATIVE_EXPECTED_HOOKS",
            "SOULSPIRE_NATIVE_CAP_SOUL_SUB_WEAPON",
            "SOULSPIRE_NATIVE_CAP_SOUL_SUB_2H",
            "SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_1H",
            "SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H",
            "SOULSPIRE_NATIVE_WEAPON_MODE_TWOHAND_SHIELD",
            "typedef struct SoulspireNativeWeaponRule",
            "typedef struct SoulspireNativeWeaponStatus",
            "typedef struct SoulspireNativeHookDiagnostics",
            "typedef struct SoulspireNativeInterfaceInfo",
            "SoulspireNativeReplaceWeaponRules",
            "SoulspireNativeClearWeaponRules",
            "SoulspireNativeGetWeaponStatus",
            "SoulspireNativeGetHookDiagnostics",
            "SoulspireNativeGetInterfaceInfo",
            "SoulspireNativeReloadConfig",
        ):
            self.assertIn(sym, header)

        for compat_sym in (
            "CRYSTALJOBS_CAP_SOUL_SUB_WEAPON",
            "CrystalJobsReplaceWeaponRules",
            "CrystalJobsGetHookDiagnostics",
            "CrystalJobsInitialize",
        ):
            self.assertIn(compat_sym, compat)

        def_text = (NATIVE_DIR / "soulspire_native.def").read_text(encoding="utf-8")
        build_cmd = (NATIVE_DIR / "build.cmd").read_text(encoding="utf-8")
        for exp in (
            "SoulspireNativeReplaceWeaponRules@8",
            "SoulspireNativeClearWeaponRules@0",
            "SoulspireNativeGetWeaponStatus@8",
            "SoulspireNativeGetHookDiagnostics@8",
            "SoulspireNativeGetInterfaceInfo@8",
            "CrystalJobsReplaceWeaponRules@8",
            "CrystalJobsClearWeaponRules@0",
            "CrystalJobsGetWeaponStatus@8",
            "CrystalJobsGetHookDiagnostics@8",
        ):
            self.assertIn(exp, def_text)
            self.assertIn(exp, build_cmd)

    def test_soulspire_native_cpp_wires_all_27_hooks_and_relocation(self):
        cpp = (NATIVE_DIR / "soulspire_native.cpp").read_text(encoding="utf-8")
        layout = (NATIVE_DIR / "hooks" / "layout.h").read_text(encoding="utf-8")
        self.assertIn("soul_sub_weapon_detour{0x133D56", cpp)
        self.assertIn("soul_sub_menu_filter_detour{0x21DF85", cpp)
        self.assertIn("soul_sub_2h_main_detour{0x133DD3", cpp)
        self.assertIn("0x133E33", cpp)
        self.assertIn("rva == 0xEB5D0", layout)
        self.assertIn("base + 0x133D5B", cpp)
        self.assertIn("base + 0x133D65", cpp)
        self.assertIn("base + 0x6229C0", cpp)
        self.assertIn("static_assert(sizeof(SoulspireNativeWeaponRule) == 24)", cpp)
        self.assertIn("static_assert(sizeof(SoulspireNativeWeaponStatus) == 36)", cpp)
        self.assertIn("static_assert(sizeof(SoulspireNativeHookDiagnostics) == 60)", cpp)
        self.assertIn("static_assert(kExpectedHooks == 27u)", cpp)
        self.assertIn("collect_hook_state(", cpp)
        self.assertIn("SoulspireNativeGetHookDiagnostics", cpp)
        self.assertIn("SOULSPIRE_NATIVE_CAP_SOUL_SUB_WEAPON", cpp)
        self.assertIn("SOULSPIRE_NATIVE_CAP_SOUL_SUB_2H", cpp)

        selftest = (NATIVE_DIR / "tests" / "selftest.cpp").read_text(encoding="utf-8")
        self.assertIn("weapon_rule_checks();", selftest)
        self.assertIn("diag.expected_hooks == 27", selftest)
        self.assertIn("info.expected_hooks == 27", selftest)
        self.assertIn("dll_diag.expected_hooks == 27", selftest)
        self.assertIn("SoulspireNativeGetHookDiagnostics", selftest)

    def test_crystalsocket_removed_custom_equipment_picker_and_preserves_soul_ui(self):
        self.assertFalse((CS_DIR / "buckler.lua").exists(), "Legacy buckler.lua must be removed")

        ui_lua = (CS_DIR / "ui.lua").read_text(encoding="utf-8")
        for forbidden in ("##crystal_buckler", "open_buckler", "close_buckler", "SUB_NATIVE_SLOT", "WeaponConfig"):
            self.assertNotIn(forbidden, ui_lua)
        # Soul Crystal UI must remain intact
        for required in ("##crystal_socket", "##crystal_collection", "draw_crystal_tooltip", "Remove crystal"):
            self.assertIn(required, ui_lua)

        cs_lua = (CS_DIR / "crystalsocket.lua").read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"/equip%s\+sub", cs_lua), "crystalsocket.lua must not intercept /equip sub")
        self.assertIn("labels:sync_weapon_rules(native_weapon_rules)", cs_lua)

        wc_lua = (CS_DIR / "weapon_config.lua").read_text(encoding="utf-8")
        self.assertNotIn("AddOutgoingPacket", wc_lua, "weapon_config.lua must not inject raw 0x050 packets")
        self.assertIn("function W.native_rules()", wc_lua)

    def test_shipped_soulspire_native_dll_is_x86_pe32_with_all_43_exports(self):
        self.assertTrue(SHIPPED_DLL.is_file(), "Missing plugins/ashita4/soulspire_native.dll")
        machine, magic, chars, exports = parse_pe32_exports(SHIPPED_DLL)
        self.assertEqual(machine, 0x014C, "soulspire_native.dll must be Win32 x86 (IMAGE_FILE_MACHINE_I386)")
        self.assertEqual(magic, 0x010B, "soulspire_native.dll must be PE32")
        self.assertNotEqual(chars & 0x2000, 0, "soulspire_native.dll must have IMAGE_FILE_DLL characteristic")
        expected_exports = [
            "SoulspireNativeClearActiveSoul",
            "SoulspireNativeClearCatalog",
            "SoulspireNativeClearVisibility",
            "SoulspireNativeClearWeaponRules",
            "SoulspireNativeGetActionStatus",
            "SoulspireNativeGetHookDiagnostics",
            "SoulspireNativeGetIdentityDiagnostics",
            "SoulspireNativeGetInterfaceInfo",
            "SoulspireNativeGetStatus",
            "SoulspireNativeGetVisibilityStatus",
            "SoulspireNativeGetWeaponStatus",
            "SoulspireNativeInitialize",
            "SoulspireNativeReloadConfig",
            "SoulspireNativeReplaceCatalog",
            "SoulspireNativeReplaceVisibility",
            "SoulspireNativeReplaceWeaponRules",
            "SoulspireNativeSetActionRowLimit",
            "SoulspireNativeSetActiveSoul",
            "SoulspireNativeSetState",
            "SoulspireNativeShutdown",
            "SoulspireNativeUpsertAction",
            "CrystalJobsClearActiveSoul",
            "CrystalJobsClearCatalog",
            "CrystalJobsClearVisibility",
            "CrystalJobsClearWeaponRules",
            "CrystalJobsGetActionStatus",
            "CrystalJobsGetHookDiagnostics",
            "CrystalJobsGetIdentityDiagnostics",
            "CrystalJobsGetStatus",
            "CrystalJobsGetVisibilityStatus",
            "CrystalJobsGetWeaponStatus",
            "CrystalJobsInitialize",
            "CrystalJobsReplaceCatalog",
            "CrystalJobsReplaceVisibility",
            "CrystalJobsReplaceWeaponRules",
            "CrystalJobsSetActionRowLimit",
            "CrystalJobsSetActiveSoul",
            "CrystalJobsSetState",
            "CrystalJobsShutdown",
            "CrystalJobsUpsertAction",
            "expCreatePlugin",
            "expDestroyPlugin",
            "expGetInterfaceVersion",
        ]
        self.assertEqual(len(exports), 43, f"Expected 43 PE exports, found {len(exports)}: {exports}")
        self.assertEqual(sorted(exports), sorted(expected_exports))


if __name__ == "__main__":
    unittest.main()
