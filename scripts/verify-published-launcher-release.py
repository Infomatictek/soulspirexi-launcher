#!/usr/bin/env python3
"""End-to-end public verifier for a published SoulspireXI Launcher GitHub Release.

Uses ZERO credentials or tokens: fetches the public GitHub Release metadata, downloads
launcher-release.json and SoulspireLauncher-win-x64.zip, verifies ECDSA-P256 signature
against keys/soulspire-launcher-release-v1.pub.pem, verifies ZIP & extracted binary
SHA-256 + PE headers, and confirms Stable (/releases/latest) remains untouched when
verifying a Testing release.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
META_SCRIPT = REPO_ROOT / "scripts" / "build-launcher-release-metadata.py"

spec = importlib.util.spec_from_file_location("build_launcher_release_metadata", META_SCRIPT)
assert spec is not None and spec.loader is not None
meta_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(meta_mod)


def fetch_json(url: str) -> dict[str, object]:
    req = urllib.request.Request(url, headers={"User-Agent": "SoulspireXI-Release-Verifier/1.0"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status} fetching {url}")
        return json.loads(resp.read().decode("utf-8"))


def download_file(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "SoulspireXI-Release-Verifier/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status} downloading {url}")
        with dest.open("wb") as fh:
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                fh.write(chunk)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify a published SoulspireXI Launcher GitHub Release.")
    parser.add_argument("--tag", required=True, help="Release tag to verify (e.g. v2.2.0-testing.core-ui.1)")
    parser.add_argument("--expected-channel", required=True, choices=["stable", "testing-core-ui", "testing"])
    parser.add_argument("--owner", default="Infomatictek")
    parser.add_argument("--repo", default="soulspirexi-launcher")
    parser.add_argument("--public-key", type=Path, default=REPO_ROOT / "keys" / "soulspire-launcher-release-v1.pub.pem")
    parser.add_argument("--expected-stable-tag", default="v2.1.0", help="Confirm /releases/latest stays untouched for non-stable tags.")
    args = parser.parse_args(argv)

    rel_api = f"https://api.github.com/repos/{args.owner}/{args.repo}/releases/tags/{args.tag}"
    release = fetch_json(rel_api)
    if release.get("draft"):
        raise RuntimeError(f"Release {args.tag} is a draft!")

    is_prerelease = bool(release.get("prerelease"))
    if args.expected_channel == "stable" and is_prerelease:
        raise RuntimeError(f"Expected stable release, but {args.tag} is marked prerelease=true")
    if args.expected_channel != "stable" and not is_prerelease:
        raise RuntimeError(f"Expected prerelease for {args.expected_channel}, but {args.tag} is marked prerelease=false!")

    assets = {a["name"]: a for a in release.get("assets", []) if isinstance(a, dict)}
    for required in ("launcher-release.json", "SoulspireLauncher-win-x64.zip", "SoulspireLauncher.exe", "SoulspireUpdater.exe"):
        if required not in assets:
            raise RuntimeError(f"Release {args.tag} missing required asset: {required}")
    if "OverlordsLauncher.exe" in assets:
        raise RuntimeError(f"Release {args.tag} contains forbidden legacy OverlordsLauncher.exe!")

    with tempfile.TemporaryDirectory(prefix="soulspire_rel_verify_") as tmp:
        root = Path(tmp)
        meta_path = root / "launcher-release.json"
        zip_path = root / "SoulspireLauncher-win-x64.zip"
        download_file(str(assets["launcher-release.json"]["browser_download_url"]), meta_path)
        download_file(str(assets["SoulspireLauncher-win-x64.zip"]["browser_download_url"]), zip_path)

        extract_dir = root / "extracted"
        extract_dir.mkdir()
        with zipfile.ZipFile(zip_path, "r") as zf:
            names = [Path(n).name for n in zf.namelist()]
            if "OverlordsLauncher.exe" in names:
                raise RuntimeError("ZIP archive contains forbidden legacy OverlordsLauncher.exe!")
            zf.extractall(extract_dir)

        exe_path = extract_dir / "SoulspireLauncher.exe"
        updater_path = extract_dir / "SoulspireUpdater.exe"
        if not exe_path.is_file() or exe_path.read_bytes()[:2] != b"MZ":
            raise RuntimeError("Extracted SoulspireLauncher.exe missing or invalid PE header!")
        if not updater_path.is_file() or updater_path.read_bytes()[:2] != b"MZ":
            raise RuntimeError("Extracted SoulspireUpdater.exe missing or invalid PE header!")

        meta = meta_mod.verify_metadata_file(
            metadata_path=meta_path,
            public_key_path=args.public_key,
            package_path=zip_path,
            executable_path=exe_path,
            updater_path=updater_path,
            owner=args.owner,
            repo=args.repo,
        )
        if meta["channel"] != args.expected_channel:
            raise RuntimeError(f"Channel mismatch: expected {args.expected_channel}, got {meta['channel']}")

    if args.expected_channel != "stable" and args.expected_stable_tag:
        latest_stable = fetch_json(f"https://api.github.com/repos/{args.owner}/{args.repo}/releases/latest")
        if latest_stable.get("tag_name") != args.expected_stable_tag:
            raise RuntimeError(
                f"Stable /releases/latest changed unexpectedly! Expected {args.expected_stable_tag}, got {latest_stable.get('tag_name')}"
            )

    print(
        f"PUBLISHED RELEASE VERIFIED OK: {args.tag} "
        f"(channel={args.expected_channel}, prerelease={is_prerelease}, "
        f"zip_sha256={str(meta['sha256'])[:12]}..., exe_sha256={str(meta['executableSha256'])[:12]}..., "
        f"signature=ECDSA-P256-VERIFIED)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
