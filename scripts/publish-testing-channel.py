#!/usr/bin/env python3
"""Builds and verifies channels/testing/manifest.json independently of Stable manifest.json.

Never modifies Stable manifest.json or Stable plugins/addons/dat-overlay payloads.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import shutil
import sys
from pathlib import Path

TEXT_LF_SUFFIXES = {
    ".lua", ".md", ".json", ".yml", ".yaml", ".py", ".cs", ".xaml",
    ".csproj", ".tsv", ".txt", ".csv", ".cfg", ".ini", ".conf",
}


def sha256_file(path: Path) -> tuple[str, int]:
    raw = path.read_bytes()
    if path.suffix.lower() in TEXT_LF_SUFFIXES and b"\r\n" in raw:
        raw = raw.replace(b"\r\n", b"\n")
        path.write_bytes(raw)
    return hashlib.sha256(raw).hexdigest(), len(raw)


def load_module(script_path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, str(script_path))
    if not spec or not spec.loader:
        raise RuntimeError(f"Could not load module: {script_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_testing_manifest(
    repo_root: Path,
    *,
    crystaljobs_dll: Path | None,
    build_info: Path | None,
    manifest_version: str,
    server_version: str,
    server_branch: str,
    server_commit: str,
    server_image: str,
    crystaljobs_hooks: int,
    testing_notes: str,
    repo_branch: str | None = None,
    candidate: str = "default-27hook",
    provenance_json: Path | None = None,
) -> Path:
    repo_root = repo_root.resolve()
    stable_manifest_path = repo_root / "manifest.json"
    if not stable_manifest_path.is_file():
        raise FileNotFoundError(f"Stable manifest not found: {stable_manifest_path}")

    candidate_dirs = {
        "default-27hook": repo_root / "channels" / "testing",
        "registry-24hook": repo_root / "channels" / "testing-registry-24hook",
        "search-legacy-text": repo_root / "channels" / "testing-search-legacy-text",
        "search-aligned-text": repo_root / "channels" / "testing-search-aligned-text",
        "core-ui-24hook": repo_root / "channels" / "testing-core-ui",
    }
    if candidate not in candidate_dirs:
        raise ValueError(f"Unknown Testing candidate {candidate!r}; expected one of {tuple(candidate_dirs)}")
    if candidate == "default-27hook" and crystaljobs_hooks < 26:
        raise ValueError(
            "Refusing to replace the 27-hook Testing channel with a 24-hook DLL. "
            "Use --candidate registry-24hook (or search-legacy-text / search-aligned-text) to publish an isolated 24-hook candidate."
        )

    testing_dir = candidate_dirs[candidate]
    payload_root = testing_dir / "payload"
    payload_root.mkdir(parents=True, exist_ok=True)

    # Verify and stage the candidate crystaljobs.dll when provided
    staged_dll_sha: str | None = None
    if crystaljobs_dll is not None:
        dll_verifier = load_module(repo_root / "scripts" / "verify-crystaljobs-dll.py", "verify_crystaljobs_dll")
        dll_verifier.verify_dll(
            crystaljobs_dll,
            require_26_hooks=(crystaljobs_hooks >= 26),
            build_info_path=build_info,
            manifest_path=None,
        )
        dest_dll = payload_root / "plugins" / "ashita4" / "crystaljobs.dll"
        dest_dll.parent.mkdir(parents=True, exist_ok=True)
        if crystaljobs_dll.resolve() != dest_dll.resolve():
            shutil.copy2(crystaljobs_dll, dest_dll)
        staged_dll_sha, _ = sha256_file(dest_dll)

    if provenance_json is not None and provenance_json.is_file():
        shutil.copy2(provenance_json, testing_dir / "crystaljobs-provenance.json")

    stable_manifest = json.loads(stable_manifest_path.read_text(encoding="utf-8"))
    testing_manifest = copy.deepcopy(stable_manifest)

    testing_manifest["channel"] = "testing"
    testing_manifest["candidateId"] = candidate
    testing_manifest["manifestVersion"] = manifest_version
    testing_manifest["minLauncherVersion"] = "2.1.0"
    testing_manifest["serverCompatibility"] = {
        "version": server_version,
        "branch": server_branch,
        "commit": server_commit,
        "dockerImage": server_image,
        "crystalJobsHooks": crystaljobs_hooks,
        "notes": testing_notes,
    }

    if candidate in ("registry-24hook", "search-legacy-text", "search-aligned-text", "core-ui-24hook"):
        reg_sync_path = repo_root / "registry_sync.json"
        reg_sync = json.loads(reg_sync_path.read_text(encoding="utf-8")) if reg_sync_path.is_file() else {}
        prov = json.loads(provenance_json.read_text(encoding="utf-8-sig")) if (provenance_json and provenance_json.is_file()) else {}
        testing_manifest["registry"] = {
            "version": str(reg_sync.get("registryVersion") or ""),
            "hash": str(reg_sync.get("registryHash") or ""),
            "idLockStatus": str(reg_sync.get("idLockStatus") or ""),
            "nativeDllCompiledHash": str(prov.get("compiledRegistryHash") or reg_sync.get("registryHash") or ""),
            "nativeDllSha256": staged_dll_sha or str(prov.get("dllSha256") or ""),
            "nativeDllClientVerified": False,  # Never mark client-verified from CI alone
            "crystalJobsHooks": 24,
        }

    if repo_branch:
        repo_cfg = testing_manifest.setdefault("repo", {})
        owner = repo_cfg.get("owner", "Infomatictek")
        name = repo_cfg.get("name", "soulspirexi-launcher")
        repo_cfg["branch"] = repo_branch
        repo_cfg["rawBaseUrl"] = f"https://raw.githubusercontent.com/{owner}/{name}/{repo_branch}"

    # Scan channels/testing/payload overrides and replace matching Stable entries (or append new ones)
    override_roots = [
        ("dat", payload_root / "dat-overlay" / "ROM", payload_root / "dat-overlay"),
        ("plugin", payload_root / "plugins" / "ashita4", payload_root / "plugins" / "ashita4"),
        ("addon", payload_root / "addons" / "ashita4", payload_root / "addons" / "ashita4"),
    ]

    overrides: dict[tuple[str, str], dict[str, object]] = {}
    for category, scan_root, target_base in override_roots:
        if not scan_root.exists():
            continue
        for file_path in sorted(
            (p for p in scan_root.rglob("*") if p.is_file()),
            key=lambda p: p.relative_to(repo_root).as_posix().lower(),
        ):
            rel_source = file_path.relative_to(repo_root).as_posix()
            rel_target = file_path.relative_to(target_base).as_posix()
            digest, size = sha256_file(file_path)
            overrides[(category, rel_target.lower())] = {
                "category": category,
                "sourcePath": rel_source,
                "targetPath": rel_target,
                "sha256": digest,
                "size": size,
            }

    merged_files: list[dict[str, object]] = []
    consumed: set[tuple[str, str]] = set()
    for entry in testing_manifest.get("files", []):
        key = (str(entry.get("category", "")), str(entry.get("targetPath", "")).lower())
        if key in overrides:
            merged_files.append(overrides[key])
            consumed.add(key)
        else:
            merged_files.append(entry)

    for key, entry in sorted(overrides.items()):
        if key not in consumed:
            merged_files.append(entry)

    testing_manifest["files"] = merged_files

    out_path = testing_dir / "manifest.json"
    out_path.write_text(json.dumps(testing_manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    return out_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--crystaljobs-dll", type=Path, default=None, help="Verified 27-hook crystaljobs.dll to stage into Testing payload")
    parser.add_argument("--build-info", type=Path, default=None, help="Optional crystaljobs-build-info.txt for build provenance validation")
    parser.add_argument("--manifest-version", default="2.1.0-testing.1")
    parser.add_argument("--server-version", default="feat/soul-weapon-templates (b05c027 / patch 0074)")
    parser.add_argument("--server-branch", default="feat/soul-weapon-templates")
    parser.add_argument("--server-commit", default="b05c027")
    parser.add_argument("--server-image", default="soulspirexi/server:feat-soul-weapon-templates")
    parser.add_argument("--crystaljobs-hooks", type=int, default=27)
    parser.add_argument(
        "--notes",
        default="Testing channel build pairing verified 27-hook CrystalJobs (DUAL_2H + CanEquipItemInSlot Hook #27) with feat/soul-weapon-templates server.",
    )
    parser.add_argument("--repo-branch", default=None, help="Optional branch override for testing manifest rawBaseUrl")
    parser.add_argument(
        "--candidate",
        choices=("default-27hook", "registry-24hook", "search-legacy-text", "search-aligned-text", "core-ui-24hook"),
        default="default-27hook",
        help="Explicit Testing candidate track (preserves 27-hook channel and isolates each 24-hook Search/Registry candidate).",
    )
    parser.add_argument("--provenance-json", type=Path, default=None, help="Optional crystaljobs-provenance.json to bundle with candidate.")
    args = parser.parse_args(argv)

    out_path = build_testing_manifest(
        args.repo,
        crystaljobs_dll=args.crystaljobs_dll,
        build_info=args.build_info,
        manifest_version=args.manifest_version,
        server_version=args.server_version,
        server_branch=args.server_branch,
        server_commit=args.server_commit,
        server_image=args.server_image,
        crystaljobs_hooks=args.crystaljobs_hooks,
        testing_notes=args.notes,
        repo_branch=args.repo_branch,
        candidate=args.candidate,
        provenance_json=args.provenance_json,
    )
    print(f"Wrote verified Testing channel manifest: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
