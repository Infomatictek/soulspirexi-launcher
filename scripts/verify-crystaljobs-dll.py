#!/usr/bin/env python3
"""Strict Win32 PE32, export, 26-hook, metadata, and manifest validator for crystaljobs.dll."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

STALE_24_HOOK_SHA256 = "8e10ac388d13531c1d8e3572af1cab196a96d9d61a43f4ce0194960cfc3133e3"

REQUIRED_EXPORTS = (
    "CrystalJobsInitialize",
    "CrystalJobsShutdown",
    "CrystalJobsGetStatus",
    "CrystalJobsSetState",
    "CrystalJobsReplaceCatalog",
    "CrystalJobsUpsertAction",
    "CrystalJobsClearCatalog",
    "CrystalJobsSetActiveSoul",
    "CrystalJobsClearActiveSoul",
    "CrystalJobsGetActionStatus",
    "CrystalJobsSetActionRowLimit",
    "CrystalJobsReplaceVisibility",
    "CrystalJobsClearVisibility",
    "CrystalJobsGetVisibilityStatus",
    "CrystalJobsReplaceWeaponRules",
    "CrystalJobsClearWeaponRules",
    "CrystalJobsGetWeaponStatus",
    "CrystalJobsGetHookDiagnostics",
    "expGetInterfaceVersion",
    "expCreatePlugin",
    "expDestroyPlugin",
)

# Binary-verified FFXiMain.dll signature prefixes embedded in 27-hook crystaljobs.dll
# (absent in the legacy 24-hook binary).
HOOK_25_SIG_PREFIX = bytes([0x85, 0x46, 0xF4, 0x74, 0x5F, 0x8B, 0x42, 0x0C])  # RVA 0x21DF85
HOOK_26_SIG_PREFIX = bytes([0x68, 0x99, 0x00, 0x00, 0x00, 0xE8, 0xE3, 0x74, 0xFF, 0xFF])  # RVA 0x133DD3
HOOK_27_SIG_PREFIX = bytes([0xE8, 0x48, 0xF7, 0xFF, 0xFF, 0x84, 0xC0, 0x75, 0x24, 0xFE])  # RVA 0x133E33


def _rva_to_offset(rva: int, sections: list[tuple[int, int, int, int]]) -> int:
    for vaddr, vsize, raw_ptr, raw_size in sections:
        span = max(vsize, raw_size)
        if vaddr <= rva < vaddr + span:
            return raw_ptr + (rva - vaddr)
    raise ValueError(f"RVA 0x{rva:X} does not map into any PE section")


def parse_pe32_dll_exports(data: bytes) -> list[str]:
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise ValueError("Missing MZ DOS header")

    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_off + 24 > len(data) or data[pe_off : pe_off + 4] != b"PE\x00\x00":
        raise ValueError("Missing PE\\0\\0 signature")

    machine, num_sections, _ts, _sym, _nsym, opt_size, chars = struct.unpack_from("<HHIIIHH", data, pe_off + 4)
    if machine != 0x014C:
        raise ValueError(f"Expected x86 PE32 machine 0x014C, got 0x{machine:04X}")
    if (chars & 0x2000) == 0:
        raise ValueError(f"Expected IMAGE_FILE_DLL (0x2000) characteristic, got 0x{chars:04X}")

    opt_off = pe_off + 24
    opt_magic = struct.unpack_from("<H", data, opt_off)[0]
    if opt_magic != 0x010B:
        raise ValueError(f"Expected PE32 optional header magic 0x010B, got 0x{opt_magic:04X}")

    export_rva, export_size = struct.unpack_from("<II", data, opt_off + 96)
    if export_rva == 0 or export_size == 0:
        raise ValueError("PE has no Export Directory Table")

    sec_off = opt_off + opt_size
    sections: list[tuple[int, int, int, int]] = []
    for i in range(num_sections):
        off = sec_off + i * 40
        vsize, vaddr, raw_size, raw_ptr = struct.unpack_from("<IIII", data, off + 8)
        sections.append((vaddr, vsize, raw_ptr, raw_size))

    exp_off = _rva_to_offset(export_rva, sections)
    num_names = struct.unpack_from("<I", data, exp_off + 24)[0]
    names_rva = struct.unpack_from("<I", data, exp_off + 32)[0]
    names_off = _rva_to_offset(names_rva, sections)

    exports: list[str] = []
    for i in range(num_names):
        name_rva = struct.unpack_from("<I", data, names_off + i * 4)[0]
        name_off = _rva_to_offset(name_rva, sections)
        end = data.index(b"\x00", name_off)
        exports.append(data[name_off:end].decode("ascii"))
    return exports


def parse_build_info(path: Path) -> dict[str, str]:
    info: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        info[k.strip()] = v.strip()
    return info


def verify_dll(
    dll_path: Path,
    *,
    require_26_hooks: bool = True,
    build_info_path: Path | None = None,
    expected_commit: str | None = None,
    manifest_path: Path | None = None,
    reject_sha256: list[str] | None = None,
) -> dict[str, object]:
    if not dll_path.is_file():
        raise ValueError(f"DLL not found: {dll_path}")

    data = dll_path.read_bytes()
    if len(data) < 4096:
        raise ValueError(f"DLL unexpectedly small ({len(data)} bytes): {dll_path}")

    sha256 = hashlib.sha256(data).hexdigest().lower()
    exports = parse_pe32_dll_exports(data)

    missing_exports = [name for name in REQUIRED_EXPORTS if name not in exports]
    if missing_exports:
        raise ValueError(f"Missing required PE exports ({len(missing_exports)}): {', '.join(missing_exports)}")
    if len(exports) < len(REQUIRED_EXPORTS):
        raise ValueError(f"Expected at least {len(REQUIRED_EXPORTS)} exports, got {len(exports)}")

    rejected = {h.lower() for h in (reject_sha256 or [])}
    if require_26_hooks:
        rejected.add(STALE_24_HOOK_SHA256)
    if sha256 in rejected:
        raise ValueError(f"Refusing stale/rejected crystaljobs.dll SHA-256: {sha256}")

    has_hook_25 = HOOK_25_SIG_PREFIX in data
    has_hook_26 = HOOK_26_SIG_PREFIX in data
    has_hook_27 = HOOK_27_SIG_PREFIX in data
    if require_26_hooks and (not has_hook_25 or not has_hook_26 or not has_hook_27):
        raise ValueError(
            f"DLL does not contain 27-hook DUAL_2H signatures "
            f"(hook_25_0x21DF85={has_hook_25}, hook_26_0x133DD3={has_hook_26}, hook_27_0x133E33={has_hook_27})"
        )

    commit_sha: str | None = None
    if build_info_path is not None:
        if not build_info_path.is_file():
            raise ValueError(f"Build metadata file missing: {build_info_path}")
        info = parse_build_info(build_info_path)
        meta_sha = info.get("crystaljobs_dll_sha256", "").lower()
        meta_size = info.get("crystaljobs_dll_size", "")
        commit_sha = info.get("commit_sha", "")
        if meta_sha != sha256:
            raise ValueError(f"Build metadata SHA-256 mismatch: metadata={meta_sha!r} actual={sha256!r}")
        if meta_size != str(len(data)):
            raise ValueError(f"Build metadata size mismatch: metadata={meta_size!r} actual={len(data)}")
        if expected_commit and commit_sha.lower() != expected_commit.lower():
            raise ValueError(f"Source revision mismatch: metadata={commit_sha!r} expected={expected_commit!r}")

    if manifest_path is not None:
        if not manifest_path.is_file():
            raise ValueError(f"Manifest file missing: {manifest_path}")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        entries = [
            f for f in manifest.get("files", [])
            if f.get("sourcePath") == "plugins/ashita4/crystaljobs.dll"
        ]
        if len(entries) != 1:
            raise ValueError(f"Expected 1 manifest entry for plugins/ashita4/crystaljobs.dll, found {len(entries)}")
        entry = entries[0]
        if str(entry.get("sha256", "")).lower() != sha256:
            raise ValueError(
                f"Manifest SHA-256 drift for crystaljobs.dll: manifest={entry.get('sha256')!r} dll={sha256!r}"
            )
        if int(entry.get("size", -1)) != len(data):
            raise ValueError(
                f"Manifest size drift for crystaljobs.dll: manifest={entry.get('size')!r} dll={len(data)}"
            )

    return {
        "path": str(dll_path),
        "size": len(data),
        "sha256": sha256,
        "export_count": len(exports),
        "has_26_hook_sigs": has_hook_25 and has_hook_26 and has_hook_27,
        "commit_sha": commit_sha,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dll", type=Path, help="Path to crystaljobs.dll")
    parser.add_argument("--build-info", type=Path, default=None, help="Path to crystaljobs-build-info.txt")
    parser.add_argument("--expected-commit", type=str, default=None, help="Expected git commit SHA")
    parser.add_argument("--manifest", type=Path, default=None, help="Path to manifest.json to cross-check")
    parser.add_argument("--reject-sha256", action="append", default=[], help="Reject specific stale SHA-256")
    parser.add_argument("--allow-24-hook", action="store_true", help="Disable 26-hook signature check (testing only)")
    args = parser.parse_args(argv)

    try:
        summary = verify_dll(
            args.dll,
            require_26_hooks=not args.allow_24_hook,
            build_info_path=args.build_info,
            expected_commit=args.expected_commit,
            manifest_path=args.manifest,
            reject_sha256=args.reject_sha256,
        )
    except Exception as exc:
        print(f"ERROR: crystaljobs.dll verification failed: {exc}", file=sys.stderr)
        return 1

    print(
        f"Verified x86 PE32 crystaljobs.dll: size={summary['size']} bytes, "
        f"sha256={summary['sha256']}, exports={summary['export_count']}, "
        f"26_hook_sigs={summary['has_26_hook_sigs']}, commit={summary['commit_sha'] or 'n/a'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
