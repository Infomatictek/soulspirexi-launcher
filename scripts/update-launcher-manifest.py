#!/usr/bin/env python3
"""Regenerates the file hashes and sizes in manifest.json (or verifies in --check mode)."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path


TEXT_LF_SUFFIXES = {".lua", ".md", ".json", ".yml", ".yaml", ".py", ".cs", ".xaml", ".csproj", ".tsv", ".txt", ".csv", ".cfg", ".ini", ".conf"}

OPTIONAL_OVERLAY_METADATA: dict[str, dict[str, object]] = {
    "flintlock-akimbo-compact": {
        "name": "COR Flintlock Dual Pistols (AkimboRA v3.7 Compact 75%)",
        "description": (
            "Optional visual-only dual-pistol ranged attack and Mariner hip-holster overlay "
            "for COR Flintlock (75% compact scale, 7 player skeletons, 26 firearm models). "
            "Disabled by default to avoid affecting other Souls."
        ),
        "overlayFolder": "flintlock-akimbo-compact",
        "defaultEnabled": False,
        "soulGate": {
            "job": 17,
            "branch": 1,
            "soul": "flintlock",
        },
    },
}


def sha256_file(path: Path) -> tuple[str, int]:
    raw = path.read_bytes()
    if path.suffix.lower() in TEXT_LF_SUFFIXES and b"\r\n" in raw:
        raw = raw.replace(b"\r\n", b"\n")
        path.write_bytes(raw)
    return hashlib.sha256(raw).hexdigest(), len(raw)


def _run_read_only_check(repo_root: Path) -> int:
    verifier_path = Path(__file__).resolve().parent / "verify-launcher-manifest.py"
    spec = importlib.util.spec_from_file_location("verify_launcher_manifest", str(verifier_path))
    if not spec or not spec.loader:
        print(f"Could not load verifier: {verifier_path}", file=sys.stderr)
        return 2
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return int(mod.main([str(repo_root)]))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run read-only manifest verification without modifying manifest.json or client files.",
    )
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent
    if args.check:
        return _run_read_only_check(repo_root)

    manifest_path = repo_root / "manifest.json"
    raw_text = manifest_path.read_text(encoding="utf-8")
    for lineno, line in enumerate(raw_text.splitlines(), start=1):
        if line.startswith(("<<<<<<<", "=======", ">>>>>>>")):
            print(
                f"ERROR: Unresolved merge-conflict marker in {manifest_path} at line {lineno}. "
                "Resolve conflicts before regenerating manifest.json.",
                file=sys.stderr,
            )
            return 1

    manifest = json.loads(raw_text)

    entries: list[dict[str, object]] = []

    dat_root = repo_root / "dat-overlay" / "ROM"
    if dat_root.exists():
        for file_path in sorted(
            (p for p in dat_root.rglob("*") if p.is_file()),
            key=lambda p: p.relative_to(repo_root).as_posix().lower(),
        ):
            rel_repo = file_path.relative_to(repo_root).as_posix()
            rel_dat = file_path.relative_to(repo_root / "dat-overlay").as_posix()
            digest, size = sha256_file(file_path)
            entries.append(
                {
                    "category": "dat",
                    "sourcePath": rel_repo,
                    "targetPath": rel_dat,
                    "sha256": digest,
                    "size": size,
                }
            )

    plugins_root = repo_root / "plugins" / "ashita4"
    if plugins_root.exists():
        for file_path in sorted(
            (p for p in plugins_root.rglob("*") if p.is_file()),
            key=lambda p: p.relative_to(repo_root).as_posix().lower(),
        ):
            rel_repo = file_path.relative_to(repo_root).as_posix()
            rel_plugin = file_path.relative_to(plugins_root).as_posix()
            digest, size = sha256_file(file_path)
            entries.append(
                {
                    "category": "plugin",
                    "sourcePath": rel_repo,
                    "targetPath": rel_plugin,
                    "sha256": digest,
                    "size": size,
                }
            )

    addons_root = repo_root / "addons" / "ashita4"
    excluded_addon_suffixes = {".md", ".py", ".cs", ".cpp", ".h", ".pdb", ".cmd", ".ps1"}
    if addons_root.exists():
        for file_path in sorted(
            (p for p in addons_root.rglob("*") if p.is_file()),
            key=lambda p: p.relative_to(repo_root).as_posix().lower(),
        ):
            rel_addon_parts = file_path.relative_to(addons_root).parts
            # Never distribute internal unit tests or developer documentation to player machines
            if any(part.lower() == "tests" for part in rel_addon_parts):
                continue
            if file_path.suffix.lower() in excluded_addon_suffixes:
                continue
            rel_repo = file_path.relative_to(repo_root).as_posix()
            rel_addon = file_path.relative_to(addons_root).as_posix()
            digest, size = sha256_file(file_path)
            entries.append(
                {
                    "category": "addon",
                    "sourcePath": rel_repo,
                    "targetPath": rel_addon,
                    "sha256": digest,
                    "size": size,
                }
            )

    manifest["files"] = entries

    optional_overlays: list[dict[str, object]] = []
    optional_root = repo_root / "dat-overlays"
    if optional_root.exists():
        for overlay_dir in sorted(
            (p for p in optional_root.iterdir() if p.is_dir()),
            key=lambda p: p.name.lower(),
        ):
            rom_root = overlay_dir / "ROM"
            if not rom_root.exists():
                continue
            overlay_id = overlay_dir.name
            meta = OPTIONAL_OVERLAY_METADATA.get(
                overlay_id,
                {
                    "name": overlay_id,
                    "description": f"Optional DAT overlay ({overlay_id}).",
                    "overlayFolder": overlay_id,
                    "defaultEnabled": False,
                },
            )
            overlay_files: list[dict[str, object]] = []
            for file_path in sorted(
                (p for p in rom_root.rglob("*") if p.is_file()),
                key=lambda p: p.relative_to(repo_root).as_posix().lower(),
            ):
                rel_repo = file_path.relative_to(repo_root).as_posix()
                rel_dat = file_path.relative_to(overlay_dir).as_posix()
                digest, size = sha256_file(file_path)
                overlay_files.append(
                    {
                        "category": "dat-optional",
                        "sourcePath": rel_repo,
                        "targetPath": rel_dat,
                        "sha256": digest,
                        "size": size,
                    }
                )
            if overlay_files:
                overlay_entry: dict[str, object] = {
                    "id": overlay_id,
                    "name": meta["name"],
                    "description": meta["description"],
                    "overlayFolder": meta["overlayFolder"],
                    "defaultEnabled": bool(meta.get("defaultEnabled", False)),
                }
                if "soulGate" in meta:
                    overlay_entry["soulGate"] = meta["soulGate"]
                overlay_entry["files"] = overlay_files
                optional_overlays.append(overlay_entry)

    if optional_overlays:
        manifest["optionalOverlays"] = optional_overlays
    else:
        manifest.pop("optionalOverlays", None)

    with manifest_path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(manifest, indent=2) + "\n")
    opt_count = sum(len(o["files"]) for o in optional_overlays)  # type: ignore[arg-type]
    print(
        f"Updated {manifest_path} with {len(entries)} core file entries"
        + (f" and {opt_count} optional overlay file entries ({len(optional_overlays)} overlay(s))." if optional_overlays else ".")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
