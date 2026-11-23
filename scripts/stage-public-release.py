#!/usr/bin/env python3
"""Stage and strictly validate the allowlist-only public artifact tree for Infomatictek/soulspirexi-releases.

Zero source code, zero internal docs, zero unit tests, and zero secret patterns may enter the output tree.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

FORBIDDEN_EXTENSIONS: frozenset[str] = frozenset({
    ".cs", ".csproj", ".sln", ".xaml", ".cpp", ".cc", ".cxx", ".c", ".h", ".hpp",
    ".def", ".cmd", ".bat", ".ps1", ".py", ".pdb", ".env", ".key", ".pem", ".sqlite", ".db",
})

FORBIDDEN_PATH_PREFIXES: tuple[str, ...] = (
    "SoulspireLauncher/",
    "SoulspireLauncher.Tests/",
    "native/",
    "docs/",
    "scripts/",
    "tests/",
    "tools/",
    ".github/",
)

FORBIDDEN_SERVER_COMPAT_KEYS: frozenset[str] = frozenset({
    "branch", "commit", "dockerImage", "crystalJobsHooks",
})

FORBIDDEN_TEXT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("github_pat_", re.compile(r"github_pat_[A-Za-z0-9_]{10,}")),
    ("ghp_", re.compile(r"ghp_[A-Za-z0-9]{10,}")),
    ("PRIVATE KEY", re.compile(r"BEGIN (?:(?:RSA|EC|DSA|OPENSSH|PGP) )?PRIVATE KEY")),
    ("personal_email_or_handle", re.compile(r"nappypup", re.IGNORECASE)),
    ("personal_domain", re.compile(r"infomatic\.dev", re.IGNORECASE)),
    ("windows_dev_path", re.compile(r"C:\\\\(?:Users|overlordsxi|dev)\\\\", re.IGNORECASE)),
)

PUBLIC_README = """# SoulspireXI — Official Client Releases & Updates

This public repository distributes official SoulspireXI launcher binaries, verified client DAT overlays, and Ashita v4 runtime addons.

- **Website:** https://soulspirexi.com
- **Player Wiki:** https://wiki.soulspirexi.com
- **Latest Launcher Download:** [Releases](https://github.com/Infomatictek/soulspirexi-releases/releases/latest)

All managed client files are verified via SHA-256 against `manifest.json` during launcher synchronization.
"""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sanitize_manifest(manifest: dict, *, owner: str, repo_name: str, branch: str) -> dict:
    cleaned = json.loads(json.dumps(manifest))
    cleaned["repo"] = {
        "owner": owner,
        "name": repo_name,
        "branch": branch,
        "rawBaseUrl": f"https://raw.githubusercontent.com/{owner}/{repo_name}/{branch}",
    }
    compat = cleaned.get("serverCompatibility")
    if isinstance(compat, dict):
        for k in FORBIDDEN_SERVER_COMPAT_KEYS:
            compat.pop(k, None)
        cleaned["serverCompatibility"] = compat
    return cleaned


def validate_staged_tree(stage_dir: Path, *, repo_name: str) -> list[str]:
    errors: list[str] = []
    manifest_path = stage_dir / "manifest.json"
    if not manifest_path.is_file():
        return ["Missing staged manifest.json"]

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("repo", {}).get("name") != repo_name:
        errors.append(f"Staged manifest repo.name must be {repo_name!r}")
    if "soulspirexi-launcher" in json.dumps(manifest):
        errors.append("Staged manifest still references private-bound 'soulspirexi-launcher'")

    compat = manifest.get("serverCompatibility") or {}
    for bad_k in FORBIDDEN_SERVER_COMPAT_KEYS:
        if bad_k in compat:
            errors.append(f"Staged manifest serverCompatibility contains internal key: {bad_k}")

    expected_rel_paths: set[str] = {"manifest.json", "README.md"}
    all_entries = list(manifest.get("files") or [])
    for overlay in manifest.get("optionalOverlays") or []:
        all_entries.extend(overlay.get("files") or [])

    for entry in all_entries:
        src = str(entry.get("sourcePath", ""))
        expected_sha = str(entry.get("sha256", "")).lower()
        target_file = stage_dir / src
        expected_rel_paths.add(src)
        if not target_file.is_file():
            errors.append(f"Missing staged payload file: {src}")
            continue
        actual_sha = sha256_file(target_file)
        if actual_sha != expected_sha:
            errors.append(f"SHA-256 mismatch for staged file {src}")

    for p in sorted(stage_dir.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(stage_dir).as_posix()
        if rel not in expected_rel_paths:
            errors.append(f"Unallowlisted file present in public stage: {rel}")
        if any(rel.startswith(pref) for pref in FORBIDDEN_PATH_PREFIXES):
            errors.append(f"Forbidden source/internal directory in public stage: {rel}")
        if any(part.lower() == "tests" for part in Path(rel).parts):
            errors.append(f"Test file present in public stage: {rel}")
        if rel != "README.md" and p.suffix.lower() == ".md":
            errors.append(f"Developer markdown present in public stage: {rel}")
        if p.suffix.lower() in FORBIDDEN_EXTENSIONS:
            errors.append(f"Forbidden file extension in public stage: {rel}")
        if p.suffix.lower() in {".json", ".lua", ".tsv", ".txt", ".md"} and p.stat().st_size <= 10 * 1024 * 1024:
            txt = p.read_text(encoding="utf-8", errors="ignore")
            for label, pat in FORBIDDEN_TEXT_PATTERNS:
                if pat.search(txt):
                    errors.append(f"Forbidden pattern ({label}) detected in staged {rel}")

    return errors


def stage_public_release(
    repo_root: Path,
    output_dir: Path,
    *,
    owner: str = "Infomatictek",
    repo_name: str = "soulspirexi-releases",
    branch: str = "main",
) -> list[str]:
    manifest_src = repo_root / "manifest.json"
    manifest = json.loads(manifest_src.read_text(encoding="utf-8"))
    sanitized = sanitize_manifest(manifest, owner=owner, repo_name=repo_name, branch=branch)

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    all_entries = list(sanitized.get("files") or [])
    for overlay in sanitized.get("optionalOverlays") or []:
        all_entries.extend(overlay.get("files") or [])

    for entry in all_entries:
        rel = str(entry["sourcePath"])
        src_path = (repo_root / rel).resolve()
        if repo_root.resolve() not in src_path.parents or not src_path.is_file():
            return [f"Invalid or missing sourcePath: {rel}"]
        dst_path = output_dir / rel
        dst_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_path, dst_path)

    (output_dir / "manifest.json").write_text(json.dumps(sanitized, indent=2) + "\n", encoding="utf-8", newline="\n")
    (output_dir / "README.md").write_text(PUBLIC_README, encoding="utf-8", newline="\n")

    return validate_staged_tree(output_dir, repo_name=repo_name)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="Path to private launcher repository root")
    parser.add_argument("--output-dir", required=True, help="Directory to write allowlisted public release tree")
    parser.add_argument("--owner", default="Infomatictek")
    parser.add_argument("--release-repo-name", default="soulspirexi-releases")
    parser.add_argument("--branch", default="main")
    args = parser.parse_args(argv)

    errors = stage_public_release(
        Path(args.repo_root).resolve(),
        Path(args.output_dir).resolve(),
        owner=args.owner,
        repo_name=args.release_repo_name,
        branch=args.branch,
    )
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1
    print(f"OK: Staged and validated public release tree at {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
