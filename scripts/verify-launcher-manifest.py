#!/usr/bin/env python3
"""Read-only verification of SoulspireXI launcher manifest.json and client files.

Never rewrites manifest.json or client files on disk.
Exits 0 when valid, non-zero with actionable diagnostics on any corruption or mismatch.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

VALID_CATEGORIES = {"dat", "plugin", "addon"}
VALID_OPTIONAL_OVERLAY_CATEGORIES = {"dat-optional"}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CONFLICT_MARKER_RE = re.compile(r"^(<{7}|={7}|>{7})(?:\s|$)")

REQUIRED_TOP_LEVEL_KEYS = (
    "schemaVersion",
    "serverName",
    "defaultHost",
    "useHairpin",
    "ports",
    "repo",
    "bootstrap",
    "files",
)


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    obj: dict[str, object] = {}
    for key, val in pairs:
        if key in obj:
            raise ValueError(f"Duplicate JSON key: {key!r}")
        obj[key] = val
    return obj


def _reject_json_constant(token: str) -> object:
    raise ValueError(f"Invalid JSON constant: {token!r}")


def _validate_rel_posix_path(value: object, field_name: str, entry_idx: int, errors: list[str]) -> str | None:
    if not isinstance(value, str) or not value.strip():
        errors.append(f"files[{entry_idx}].{field_name} must be a non-empty string")
        return None
    if "\\" in value:
        errors.append(f"files[{entry_idx}].{field_name} must use POSIX forward slashes: {value!r}")
        return None
    if value.startswith("/") or ".." in value.split("/"):
        errors.append(f"files[{entry_idx}].{field_name} must be a safe relative path: {value!r}")
        return None
    return value


def expected_client_files(repo_root: Path) -> dict[str, tuple[str, str]]:
    """Return mapping of repo-relative sourcePath -> (category, targetPath) for all client payload files."""
    expected: dict[str, tuple[str, str]] = {}
    roots = [
        ("dat", repo_root / "dat-overlay" / "ROM", repo_root / "dat-overlay"),
        ("plugin", repo_root / "plugins" / "ashita4", repo_root / "plugins" / "ashita4"),
        ("addon", repo_root / "addons" / "ashita4", repo_root / "addons" / "ashita4"),
    ]
    for category, scan_root, target_base in roots:
        if not scan_root.exists():
            continue
        for file_path in sorted(
            (p for p in scan_root.rglob("*") if p.is_file()),
            key=lambda p: p.relative_to(repo_root).as_posix().lower(),
        ):
            rel_source = file_path.relative_to(repo_root).as_posix()
            rel_target = file_path.relative_to(target_base).as_posix()
            expected[rel_source] = (category, rel_target)
    return expected


def verify_manifest(repo_root: Path, manifest_path: Path | None = None) -> list[str]:
    """Verify manifest.json strictly in read-only mode. Returns a list of error strings (empty == valid)."""
    repo_root = repo_root.resolve()
    manifest_file = (manifest_path or (repo_root / "manifest.json")).resolve()
    errors: list[str] = []

    if not manifest_file.is_file():
        return [f"Manifest file not found: {manifest_file}"]

    raw_text = manifest_file.read_text(encoding="utf-8", errors="replace")

    # 1. Explicit merge-conflict marker scan before JSON parsing
    for lineno, line in enumerate(raw_text.splitlines(), start=1):
        if CONFLICT_MARKER_RE.match(line):
            errors.append(f"Merge-conflict marker detected in {manifest_file.name} at line {lineno}: {line[:80]!r}")
    if errors:
        return errors

    # 2. Strict JSON parse (rejects syntax errors, duplicate keys, NaN/Infinity)
    try:
        manifest = json.loads(
            raw_text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, ValueError) as exc:
        return [f"Invalid JSON in {manifest_file.name}: {exc}"]

    if not isinstance(manifest, dict):
        return [f"{manifest_file.name} root must be a JSON object"]

    # 3. Top-level schema structure checks
    for key in REQUIRED_TOP_LEVEL_KEYS:
        if key not in manifest:
            errors.append(f"Missing required top-level key: {key!r}")

    if manifest.get("schemaVersion") != 1:
        errors.append(f"Unsupported schemaVersion: {manifest.get('schemaVersion')!r} (expected 1)")
    if not isinstance(manifest.get("serverName"), str) or not manifest["serverName"].strip():
        errors.append("serverName must be a non-empty string")
    if not isinstance(manifest.get("defaultHost"), str) or not manifest["defaultHost"].strip():
        errors.append("defaultHost must be a non-empty string")
    if not isinstance(manifest.get("useHairpin"), bool):
        errors.append("useHairpin must be a boolean")

    ports = manifest.get("ports")
    if not isinstance(ports, dict):
        errors.append("ports must be an object")
    else:
        for port_key in ("lobby", "auth", "search"):
            val = ports.get(port_key)
            if not isinstance(val, int) or isinstance(val, bool) or val <= 0 or val > 65535:
                errors.append(f"ports.{port_key} must be an integer between 1 and 65535")

    repo_cfg = manifest.get("repo")
    if not isinstance(repo_cfg, dict):
        errors.append("repo must be an object")
    else:
        for rk in ("owner", "name", "branch", "rawBaseUrl"):
            if not isinstance(repo_cfg.get(rk), str) or not repo_cfg[rk].strip():
                errors.append(f"repo.{rk} must be a non-empty string")

    if not isinstance(manifest.get("bootstrap"), dict):
        errors.append("bootstrap must be an object")

    files = manifest.get("files")
    if not isinstance(files, list) or len(files) == 0:
        errors.append("files must be a non-empty list")
        return errors

    # 4. Per-entry validation, duplicate checks, source existence, and SHA-256 / size checks
    seen_targets: dict[tuple[str, str], int] = {}
    seen_sources: dict[str, int] = {}
    manifest_sources: dict[str, tuple[str, str]] = {}

    for idx, entry in enumerate(files):
        if not isinstance(entry, dict):
            errors.append(f"files[{idx}] must be an object")
            continue

        category = entry.get("category")
        if category not in VALID_CATEGORIES:
            errors.append(f"files[{idx}].category invalid: {category!r} (expected one of {sorted(VALID_CATEGORIES)})")

        source_path = _validate_rel_posix_path(entry.get("sourcePath"), "sourcePath", idx, errors)
        target_path = _validate_rel_posix_path(entry.get("targetPath"), "targetPath", idx, errors)

        sha256 = entry.get("sha256")
        if not isinstance(sha256, str) or not SHA256_RE.match(sha256):
            errors.append(f"files[{idx}].sha256 must be a 64-character lowercase hex digest: {sha256!r}")

        size = entry.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            errors.append(f"files[{idx}].size must be a non-negative integer: {size!r}")

        if source_path:
            src_key = source_path.lower()
            if src_key in seen_sources:
                errors.append(
                    f"Duplicate sourcePath in manifest: {source_path!r} (entries {seen_sources[src_key]} and {idx})"
                )
            else:
                seen_sources[src_key] = idx

        if category in VALID_CATEGORIES and target_path:
            tgt_key = (str(category), target_path.lower())
            if tgt_key in seen_targets:
                errors.append(
                    f"Duplicate targetPath in manifest for category {category!r}: "
                    f"{target_path!r} (entries {seen_targets[tgt_key]} and {idx})"
                )
            else:
                seen_targets[tgt_key] = idx

        if source_path and target_path and category in VALID_CATEGORIES:
            manifest_sources[source_path] = (str(category), target_path)

        if source_path and isinstance(sha256, str) and SHA256_RE.match(sha256) and isinstance(size, int):
            full_path = repo_root / source_path
            if not full_path.is_file():
                errors.append(f"Missing source file for files[{idx}]: {source_path}")
                continue
            raw_bytes = full_path.read_bytes()
            actual_size = len(raw_bytes)
            actual_sha = hashlib.sha256(raw_bytes).hexdigest()
            if actual_sha != sha256 or actual_size != size:
                crlf_hint = ""
                if b"\r\n" in raw_bytes:
                    lf_bytes = raw_bytes.replace(b"\r\n", b"\n")
                    if hashlib.sha256(lf_bytes).hexdigest() == sha256:
                        crlf_hint = " (file has CRLF line endings; normalize to LF)"
                errors.append(
                    f"Checksum/size mismatch for {source_path}: "
                    f"manifest=({sha256[:12]}..., {size}B) vs disk=({actual_sha[:12]}..., {actual_size}B){crlf_hint}"
                )

    # 5. Completeness check against client payload directories (strict for Stable; channel-aware for Testing)
    declared_channel = str(manifest.get("channel") or "stable").strip().lower()
    expected = expected_client_files(repo_root)
    if declared_channel == "testing":
        candidate_id = str(manifest.get("candidateId") or "").strip()
        candidate_prefixes = {
            "registry-24hook": "channels/testing-registry-24hook/payload/",
            "search-legacy-text": "channels/testing-search-legacy-text/payload/",
            "search-aligned-text": "channels/testing-search-aligned-text/payload/",
            "core-ui-24hook": "channels/testing-core-ui/payload/",
        }
        allowed_testing_prefix = candidate_prefixes.get(candidate_id, "channels/testing/payload/")
        for src, (cat, tgt) in sorted(manifest_sources.items()):
            in_stable = src in expected
            in_testing = src.startswith(allowed_testing_prefix)
            if not in_stable and not in_testing:
                errors.append(
                    f"Testing manifest entry points outside Stable or {allowed_testing_prefix} roots: {src}"
                )
    else:
        for src, (cat, tgt) in sorted(expected.items()):
            if src not in manifest_sources:
                errors.append(f"Client file missing from manifest.json: {src} (category={cat}, targetPath={tgt})")
            else:
                m_cat, m_tgt = manifest_sources[src]
                if (m_cat, m_tgt) != (cat, tgt):
                    errors.append(
                        f"Manifest routing mismatch for {src}: manifest=({m_cat}, {m_tgt}) vs expected=({cat}, {tgt})"
                    )

        for src in sorted(manifest_sources):
            if src not in expected:
                errors.append(f"Manifest entry points outside expected client payload roots: {src}")

    # 6. Optional DAT overlays verification (strictly read-only, zero conflicts with base dat-overlay)
    base_dat_targets = {
        tgt.lower()
        for _src, (cat, tgt) in expected.items()
        if cat == "dat"
    }
    expected_optional: dict[str, dict[str, str]] = {}
    optional_root = repo_root / "dat-overlays"
    if optional_root.exists():
        for overlay_dir in sorted((p for p in optional_root.iterdir() if p.is_dir()), key=lambda p: p.name.lower()):
            rom_root = overlay_dir / "ROM"
            if not rom_root.exists():
                continue
            ov_files: dict[str, str] = {}
            for file_path in sorted(
                (p for p in rom_root.rglob("*") if p.is_file()),
                key=lambda p: p.relative_to(repo_root).as_posix().lower(),
            ):
                ov_files[file_path.relative_to(repo_root).as_posix()] = file_path.relative_to(overlay_dir).as_posix()
            if ov_files:
                expected_optional[overlay_dir.name] = ov_files

    optional_overlays = manifest.get("optionalOverlays")
    if optional_overlays is None:
        for ov_id in sorted(expected_optional):
            errors.append(f"Optional overlay directory missing from manifest.json optionalOverlays: {ov_id}")
    elif not isinstance(optional_overlays, list):
        errors.append("optionalOverlays must be a list when present")
    else:
        seen_overlay_ids: set[str] = set()
        for ov_idx, ov in enumerate(optional_overlays):
            if not isinstance(ov, dict):
                errors.append(f"optionalOverlays[{ov_idx}] must be an object")
                continue
            ov_id = ov.get("id")
            if not isinstance(ov_id, str) or not ov_id.strip():
                errors.append(f"optionalOverlays[{ov_idx}].id must be a non-empty string")
                continue
            if ov_id in seen_overlay_ids:
                errors.append(f"Duplicate optional overlay id: {ov_id!r}")
                continue
            seen_overlay_ids.add(ov_id)

            ov_folder = ov.get("overlayFolder")
            if not isinstance(ov_folder, str) or not ov_folder.strip() or "/" in ov_folder or "\\" in ov_folder or ".." in ov_folder:
                errors.append(f"optionalOverlays[{ov_idx}].overlayFolder must be a safe folder name: {ov_folder!r}")

            if not isinstance(ov.get("defaultEnabled"), bool):
                errors.append(f"optionalOverlays[{ov_idx}].defaultEnabled must be a boolean")

            ov_files_list = ov.get("files")
            if not isinstance(ov_files_list, list) or len(ov_files_list) == 0:
                errors.append(f"optionalOverlays[{ov_idx}].files must be a non-empty list")
                continue

            seen_ov_sources: dict[str, int] = {}
            seen_ov_targets: dict[str, int] = {}
            manifest_ov_sources: dict[str, str] = {}

            for f_idx, entry in enumerate(ov_files_list):
                if not isinstance(entry, dict):
                    errors.append(f"optionalOverlays[{ov_idx}].files[{f_idx}] must be an object")
                    continue
                category = entry.get("category")
                if category not in VALID_OPTIONAL_OVERLAY_CATEGORIES:
                    errors.append(
                        f"optionalOverlays[{ov_idx}].files[{f_idx}].category invalid: {category!r} "
                        f"(expected one of {sorted(VALID_OPTIONAL_OVERLAY_CATEGORIES)})"
                    )
                source_path = _validate_rel_posix_path(
                    entry.get("sourcePath"), f"optionalOverlays[{ov_idx}].sourcePath", f_idx, errors
                )
                target_path = _validate_rel_posix_path(
                    entry.get("targetPath"), f"optionalOverlays[{ov_idx}].targetPath", f_idx, errors
                )
                sha256 = entry.get("sha256")
                if not isinstance(sha256, str) or not SHA256_RE.match(sha256):
                    errors.append(f"optionalOverlays[{ov_idx}].files[{f_idx}].sha256 invalid: {sha256!r}")
                size = entry.get("size")
                if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                    errors.append(f"optionalOverlays[{ov_idx}].files[{f_idx}].size invalid: {size!r}")

                if source_path:
                    sk = source_path.lower()
                    if sk in seen_ov_sources:
                        errors.append(f"Duplicate optional overlay sourcePath in {ov_id!r}: {source_path!r}")
                    else:
                        seen_ov_sources[sk] = f_idx

                if target_path:
                    tk = target_path.lower()
                    if tk in seen_ov_targets:
                        errors.append(f"Duplicate optional overlay targetPath in {ov_id!r}: {target_path!r}")
                    else:
                        seen_ov_targets[tk] = f_idx
                    if tk in base_dat_targets:
                        errors.append(
                            f"Optional overlay {ov_id!r} conflicts with base dat-overlay targetPath: {target_path!r}"
                        )

                if source_path and target_path:
                    manifest_ov_sources[source_path] = target_path

                if source_path and isinstance(sha256, str) and SHA256_RE.match(sha256) and isinstance(size, int):
                    full_path = repo_root / source_path
                    if not full_path.is_file():
                        errors.append(f"Missing optional overlay source file ({ov_id}): {source_path}")
                        continue
                    raw_bytes = full_path.read_bytes()
                    actual_size = len(raw_bytes)
                    actual_sha = hashlib.sha256(raw_bytes).hexdigest()
                    if actual_sha != sha256 or actual_size != size:
                        errors.append(
                            f"Optional overlay checksum/size mismatch for {source_path}: "
                            f"manifest=({sha256[:12]}..., {size}B) vs disk=({actual_sha[:12]}..., {actual_size}B)"
                        )

            expected_ov = expected_optional.get(ov_id)
            if expected_ov is None:
                errors.append(f"Manifest optionalOverlay {ov_id!r} has no matching dat-overlays/{ov_id}/ROM directory")
            else:
                for src, tgt in sorted(expected_ov.items()):
                    if src not in manifest_ov_sources:
                        errors.append(f"Optional overlay file missing from manifest.json ({ov_id}): {src}")
                    elif manifest_ov_sources[src] != tgt:
                        errors.append(
                            f"Optional overlay routing mismatch ({ov_id}) for {src}: "
                            f"manifest={manifest_ov_sources[src]!r} vs expected={tgt!r}"
                        )
                for src in sorted(manifest_ov_sources):
                    if src not in expected_ov:
                        errors.append(f"Optional overlay entry outside dat-overlays/{ov_id}/ROM: {src}")

        for ov_id in sorted(expected_optional):
            if ov_id not in seen_overlay_ids:
                errors.append(f"Optional overlay directory missing from manifest.json optionalOverlays: {ov_id}")

    # Validate coordinated registry metadata consistency when present.
    reg_meta = manifest.get("registry")
    reg_sync_path = repo_root / "registry_sync.json"
    dll_state_path = repo_root / "native" / "crystaljobs" / "dll_sync_state.json"
    if isinstance(reg_meta, dict):
        if reg_sync_path.is_file():
            reg_sync = json.loads(reg_sync_path.read_text(encoding="utf-8"))
            if reg_meta.get("hash") != reg_sync.get("registryHash"):
                errors.append(
                    f"manifest.json registry.hash ({reg_meta.get('hash')!r}) != registry_sync.json ({reg_sync.get('registryHash')!r})"
                )
        dll_entry = next(
            (e for e in manifest.get("files", []) if e.get("category") == "plugin" and str(e.get("targetPath", "")).lower().endswith("crystaljobs.dll")),
            None,
        )
        if dll_entry and reg_meta.get("nativeDllSha256") and reg_meta.get("nativeDllSha256").lower() != str(dll_entry.get("sha256", "")).lower():
            errors.append(
                f"manifest.json registry.nativeDllSha256 ({reg_meta.get('nativeDllSha256')}) != crystaljobs.dll sha256 ({dll_entry.get('sha256')})"
            )
        if declared_channel == "testing" and str(manifest.get("candidateId") or "").strip() in ("registry-24hook", "search-legacy-text", "search-aligned-text", "core-ui-24hook"):
            prov_path = (manifest_path or (repo_root / "manifest.json")).parent / "crystaljobs-provenance.json"
            runtime_loader = False
            if prov_path.is_file():
                prov_data = json.loads(prov_path.read_text(encoding="utf-8-sig"))
                runtime_loader = bool(prov_data.get("runtimeIdentityLoader")) and prov_data.get("identitySchemaVersion") == 1
                if not runtime_loader and reg_meta.get("nativeDllCompiledHash") != prov_data.get("compiledRegistryHash"):
                    errors.append(
                        f"testing candidate registry.nativeDllCompiledHash ({reg_meta.get('nativeDllCompiledHash')!r}) != crystaljobs-provenance.json ({prov_data.get('compiledRegistryHash')!r})"
                    )
            if reg_sync_path.is_file():
                reg_sync = json.loads(reg_sync_path.read_text(encoding="utf-8"))
                if runtime_loader:
                    ident_path = repo_root / "plugins" / "ashita4" / "data" / "soul-identities.json"
                    if not ident_path.is_file():
                        errors.append("runtimeIdentityLoader enabled but plugins/ashita4/data/soul-identities.json is missing")
                    else:
                        ident_doc = json.loads(ident_path.read_text(encoding="utf-8"))
                        if ident_doc.get("schemaVersion") != 1 or ident_doc.get("registryHash") != reg_sync.get("registryHash"):
                            errors.append(
                                f"soul-identities.json ({ident_doc.get('registryHash')!r}) != registry_sync.json ({reg_sync.get('registryHash')!r})"
                            )
                elif reg_meta.get("nativeDllCompiledHash") != reg_sync.get("registryHash"):
                    errors.append(
                        f"testing candidate registry.nativeDllCompiledHash ({reg_meta.get('nativeDllCompiledHash')!r}) != registry_sync.json ({reg_sync.get('registryHash')!r})"
                    )
        elif dll_state_path.is_file():
            dll_state = json.loads(dll_state_path.read_text(encoding="utf-8"))
            runtime_loader = bool(dll_state.get("runtimeIdentityLoader")) and dll_state.get("identitySchemaVersion") == 1
            if not runtime_loader and reg_meta.get("nativeDllCompiledHash") != dll_state.get("compiledRegistryHash"):
                errors.append(
                    f"manifest.json registry.nativeDllCompiledHash ({reg_meta.get('nativeDllCompiledHash')!r}) != dll_sync_state.json ({dll_state.get('compiledRegistryHash')!r})"
                )

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "repo",
        nargs="?",
        default=str(Path(__file__).resolve().parent.parent),
        help="Launcher repository root (defaults to parent of scripts/)",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="Optional explicit path to manifest.json",
    )
    parser.add_argument(
        "--strict-stable-dll",
        action="store_true",
        help="Fail if Stable manifest's crystaljobs.dll is not compiled against current registryHash and clientVerified=true.",
    )
    args = parser.parse_args(argv)

    repo_root = Path(args.repo).resolve()
    errors = verify_manifest(repo_root, manifest_path=args.manifest)
    manifest_file = (args.manifest or (repo_root / "manifest.json")).resolve()
    if args.strict_stable_dll and manifest_file.is_file():
        m = json.loads(manifest_file.read_text(encoding="utf-8"))
        reg = m.get("registry") or {}
        if reg.get("nativeDllCompiledHash") != reg.get("hash") or not reg.get("nativeDllClientVerified"):
            errors.append(
                "Strict Stable DLL gate FAILED: crystaljobs.dll must match registry.hash and have nativeDllClientVerified=true before Stable release."
            )
    if errors:
        print(f"Manifest verification FAILED with {len(errors)} error(s):", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    print(f"Manifest verification PASSED ({len(manifest['files'])} files verified, read-only).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
