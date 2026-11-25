#!/usr/bin/env python3
"""Generate and verify authenticated launcher-release.json metadata for SoulspireXI Launcher.

Strict channel isolation:
  - stable: only non-prerelease tags (e.g. v2.2.0)
  - testing-core-ui: prerelease tags containing -testing.core-ui (e.g. v2.2.0-testing.core-ui.1)
  - testing: prerelease tags containing -testing / -rc / -beta

Canonical signing payload matches LauncherPackageVerifier.BuildCanonicalSigningPayload()
in SoulspireLauncher/Services/LauncherPackageVerifier.cs byte-for-byte.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

SUPPORTED_CHANNELS = {"stable", "testing-core-ui", "testing"}
SIGNATURE_ALGORITHM = "ECDSA-P256-SHA256"


def resolve_openssl() -> str:
    found = shutil.which("openssl")
    if found:
        return found
    for candidate in (
        r"C:\Program Files\Git\usr\bin\openssl.exe",
        r"C:\Program Files\Git\mingw64\bin\openssl.exe",
        r"C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
    ):
        if Path(candidate).is_file():
            return candidate
    raise FileNotFoundError("openssl executable not found on PATH or standard Windows Git/OpenSSL locations.")


def sha256_file(path: Path) -> tuple[str, int]:
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest().lower(), size


def build_canonical_signing_payload(meta: dict[str, object]) -> bytes:
    def norm(key: str) -> str:
        val = meta.get(key)
        return "" if val is None else str(val).strip()

    lines = [
        f"schemaVersion={int(meta.get('schemaVersion', 1))}",
        f"channel={norm('channel').lower()}",
        f"version={norm('version')}",
        f"tag={norm('tag')}",
        f"packageType={norm('packageType').lower()}",
        f"assetName={norm('assetName')}",
        f"downloadUrl={norm('downloadUrl')}",
        f"sha256={norm('sha256').lower()}",
        f"size={int(meta.get('size', 0))}",
        f"executableName={norm('executableName')}",
        f"executableSha256={norm('executableSha256').lower()}",
        f"updaterName={norm('updaterName')}",
        f"updaterSha256={norm('updaterSha256').lower()}",
        f"minUpgradeFromVersion={norm('minUpgradeFromVersion')}",
    ]
    return "\n".join(lines).encode("utf-8")


def validate_channel_tag(channel: str, tag: str) -> None:
    if channel not in SUPPORTED_CHANNELS:
        raise ValueError(f"Unsupported channel: {channel}")
    cleaned = tag.strip()
    if not cleaned or not cleaned.startswith("v"):
        raise ValueError(f"Release tag must start with 'v': {tag!r}")
    lower = cleaned.lower()
    is_prerelease = any(tok in lower for tok in ("-testing", "-rc", "-beta", "-alpha"))
    if channel == "stable" and is_prerelease:
        raise ValueError(f"Stable channel cannot publish prerelease tag: {tag!r}")
    if channel == "testing-core-ui" and "-testing.core-ui" not in lower:
        raise ValueError(f"testing-core-ui channel requires '-testing.core-ui' in tag: {tag!r}")


def validate_download_url(url: str, owner: str, repo: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise ValueError(f"Download URL must use HTTPS: {url}")
    if parsed.netloc.lower() != "github.com":
        raise ValueError(f"Download URL host must be github.com: {url}")
    prefix = f"/{owner}/{repo}/releases/download/"
    if not parsed.path.lower().startswith(prefix.lower()):
        raise ValueError(f"Download URL must target permanent GitHub Release assets ({prefix}...): {url}")


def sign_payload_openssl(payload: bytes, private_key_pem: str) -> str:
    with tempfile.TemporaryDirectory(prefix="soulspire_sign_") as tmpdir:
        tmp = Path(tmpdir)
        key_path = tmp / "key.pem"
        payload_path = tmp / "payload.bin"
        sig_path = tmp / "sig.der"
        key_path.write_text(private_key_pem, encoding="utf-8")
        payload_path.write_bytes(payload)
        proc = subprocess.run(
            [resolve_openssl(), "dgst", "-sha256", "-sign", str(key_path), "-out", str(sig_path), str(payload_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"openssl sign failed: {proc.stderr.strip()}")
        return base64.b64encode(sig_path.read_bytes()).decode("ascii")


def verify_payload_openssl(payload: bytes, signature_b64: str, public_key_pem: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="soulspire_verify_") as tmpdir:
        tmp = Path(tmpdir)
        pub_path = tmp / "pub.pem"
        payload_path = tmp / "payload.bin"
        sig_path = tmp / "sig.der"
        pub_path.write_text(public_key_pem, encoding="utf-8")
        payload_path.write_bytes(payload)
        sig_path.write_bytes(base64.b64decode(signature_b64))
        proc = subprocess.run(
            [resolve_openssl(), "dgst", "-sha256", "-verify", str(pub_path), "-signature", str(sig_path), str(payload_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode == 0


def build_metadata(
    *,
    channel: str,
    tag: str,
    package_path: Path,
    executable_path: Path,
    updater_path: Path | None,
    owner: str,
    repo: str,
    min_upgrade_from: str = "2.1.0",
    release_notes: str = "",
    private_key_pem: str | None = None,
    key_id: str = "soulspire-launcher-release-v1",
) -> dict[str, object]:
    validate_channel_tag(channel, tag)
    if not package_path.is_file():
        raise FileNotFoundError(f"Package not found: {package_path}")
    if not executable_path.is_file():
        raise FileNotFoundError(f"Executable not found: {executable_path}")
    if executable_path.name.lower() != "soulspirelauncher.exe":
        raise ValueError(f"Executable must be named SoulspireLauncher.exe, got {executable_path.name}")

    pkg_sha, pkg_size = sha256_file(package_path)
    exe_sha, _ = sha256_file(executable_path)
    updater_sha = None
    updater_name = None
    if updater_path is not None and updater_path.is_file():
        updater_sha, _ = sha256_file(updater_path)
        updater_name = updater_path.name

    version = tag.lstrip("vV")
    asset_name = package_path.name
    package_type = "zip" if asset_name.lower().endswith(".zip") else "exe"
    download_url = f"https://github.com/{owner}/{repo}/releases/download/{tag}/{asset_name}"
    release_url = f"https://github.com/{owner}/{repo}/releases/tag/{tag}"
    validate_download_url(download_url, owner, repo)

    meta: dict[str, object] = {
        "schemaVersion": 1,
        "channel": channel,
        "version": version,
        "tag": tag,
        "publishedAtUtc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "minUpgradeFromVersion": min_upgrade_from,
        "packageType": package_type,
        "assetName": asset_name,
        "downloadUrl": download_url,
        "sha256": pkg_sha,
        "size": pkg_size,
        "executableName": executable_path.name,
        "executableSha256": exe_sha,
        "updaterName": updater_name,
        "updaterSha256": updater_sha,
        "releaseUrl": release_url,
        "releaseNotes": release_notes,
        "signatureAlgorithm": SIGNATURE_ALGORITHM if private_key_pem else None,
        "signatureBase64": None,
        "signatureKeyId": key_id if private_key_pem else None,
    }

    if private_key_pem:
        payload = build_canonical_signing_payload(meta)
        meta["signatureBase64"] = sign_payload_openssl(payload, private_key_pem)

    return meta


def verify_metadata_file(
    *,
    metadata_path: Path,
    public_key_path: Path,
    package_path: Path | None = None,
    executable_path: Path | None = None,
    updater_path: Path | None = None,
    owner: str = "Infomatictek",
    repo: str = "soulspirexi-launcher",
) -> dict[str, object]:
    if not metadata_path.is_file():
        raise FileNotFoundError(f"Metadata file not found: {metadata_path}")
    if not public_key_path.is_file():
        raise FileNotFoundError(f"Trusted public key file not found: {public_key_path}")

    meta = json.loads(metadata_path.read_text(encoding="utf-8"))
    if not isinstance(meta, dict):
        raise ValueError("launcher-release.json root must be a JSON object")

    channel = str(meta.get("channel") or "").strip().lower()
    tag = str(meta.get("tag") or "").strip()
    validate_channel_tag(channel, tag)
    validate_download_url(str(meta.get("downloadUrl") or ""), owner, repo)

    sig_alg = str(meta.get("signatureAlgorithm") or "").strip()
    sig_b64 = str(meta.get("signatureBase64") or "").strip()
    if sig_alg != SIGNATURE_ALGORITHM:
        raise ValueError(f"Missing or unsupported signatureAlgorithm (expected {SIGNATURE_ALGORITHM}, got {sig_alg!r})")
    if not sig_b64:
        raise ValueError("Missing signatureBase64: refusing to accept unsigned launcher release metadata.")

    pub_pem = public_key_path.read_text(encoding="utf-8")
    payload = build_canonical_signing_payload(meta)
    if not verify_payload_openssl(payload, sig_b64, pub_pem):
        raise ValueError("ECDSA-P256-SHA256 signature verification FAILED against trusted public key.")

    if package_path is not None:
        actual_sha, actual_size = sha256_file(package_path)
        if actual_sha != str(meta.get("sha256") or "").lower():
            raise ValueError(f"Package SHA-256 mismatch: expected {meta.get('sha256')}, got {actual_sha}")
        if actual_size != int(meta.get("size") or 0):
            raise ValueError(f"Package size mismatch: expected {meta.get('size')}, got {actual_size}")

    if executable_path is not None:
        actual_exe_sha, _ = sha256_file(executable_path)
        if actual_exe_sha != str(meta.get("executableSha256") or "").lower():
            raise ValueError(f"Executable SHA-256 mismatch: expected {meta.get('executableSha256')}, got {actual_exe_sha}")

    if updater_path is not None and meta.get("updaterSha256"):
        actual_upd_sha, _ = sha256_file(updater_path)
        if actual_upd_sha != str(meta.get("updaterSha256") or "").lower():
            raise ValueError(f"Updater SHA-256 mismatch: expected {meta.get('updaterSha256')}, got {actual_upd_sha}")

    return meta


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build & verify SoulspireXI launcher-release.json metadata.")
    parser.add_argument("--verify-only", type=Path, default=None, help="Verify an existing launcher-release.json fail-closed.")
    parser.add_argument("--channel", choices=sorted(SUPPORTED_CHANNELS), default=None)
    parser.add_argument("--tag", default=None)
    parser.add_argument("--package", type=Path, default=None)
    parser.add_argument("--executable", type=Path, default=None)
    parser.add_argument("--updater", type=Path, default=None)
    parser.add_argument("--owner", default="Infomatictek")
    parser.add_argument("--repo", default="soulspirexi-launcher")
    parser.add_argument("--min-upgrade-from", default="2.1.0")
    parser.add_argument("--release-notes", default="")
    parser.add_argument("--private-key-env", default="SOULSPIRE_RELEASE_SIGNING_PRIVATE_KEY_PEM")
    parser.add_argument("--require-signature", action="store_true", help="Fail closed if signing key is missing.")
    parser.add_argument("--verify-public-key", type=Path, default=None, help="Cross-verify generated or existing signature against PEM public key.")
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    if args.verify_only is not None:
        if args.verify_public_key is None:
            print("ERROR: --verify-only requires --verify-public-key.", file=sys.stderr)
            return 2
        try:
            meta = verify_metadata_file(
                metadata_path=args.verify_only,
                public_key_path=args.verify_public_key,
                package_path=args.package,
                executable_path=args.executable,
                updater_path=args.updater,
                owner=args.owner,
                repo=args.repo,
            )
            print(
                f"VERIFIED OK: {args.verify_only} (channel={meta['channel']}, tag={meta['tag']}, "
                f"keyId={meta.get('signatureKeyId')}, sha256={str(meta['sha256'])[:12]}...)"
            )
            return 0
        except Exception as exc:
            print(f"ERROR: Release metadata verification failed: {exc}", file=sys.stderr)
            return 1

    if not args.channel or not args.tag or args.package is None or args.executable is None or args.output is None:
        print("ERROR: --channel, --tag, --package, --executable, and --output are required when generating metadata.", file=sys.stderr)
        return 2

    private_key_pem = os.environ.get(args.private_key_env, "").strip() or None
    if args.require_signature and not private_key_pem:
        print(
            f"ERROR: Refusing to build release metadata without signing credentials ({args.private_key_env} is missing or empty).",
            file=sys.stderr,
        )
        return 1

    meta = build_metadata(
        channel=args.channel,
        tag=args.tag,
        package_path=args.package,
        executable_path=args.executable,
        updater_path=args.updater,
        owner=args.owner,
        repo=args.repo,
        min_upgrade_from=args.min_upgrade_from,
        release_notes=args.release_notes,
        private_key_pem=private_key_pem,
    )

    if args.verify_public_key is not None and meta.get("signatureBase64"):
        pub_pem = args.verify_public_key.read_text(encoding="utf-8")
        if not verify_payload_openssl(build_canonical_signing_payload(meta), str(meta["signatureBase64"]), pub_pem):
            print(
                f"ERROR: Generated signature does NOT match trusted public key {args.verify_public_key}! "
                "Check that SOULSPIRE_RELEASE_SIGNING_PRIVATE_KEY_PEM matches the committed public key.",
                file=sys.stderr,
            )
            return 1
    elif args.require_signature and not meta.get("signatureBase64"):
        print("ERROR: --require-signature specified but signatureBase64 is empty.", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    sig_status = "SIGNED+VERIFIED" if meta.get("signatureBase64") else "unsigned-ci-only"
    print(f"Wrote {args.output} ({sig_status}, channel={meta['channel']}, tag={meta['tag']}, sha256={str(meta['sha256'])[:12]}...)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
