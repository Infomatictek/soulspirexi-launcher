"""Unit tests for scripts/build-launcher-release-metadata.py (channel isolation, SHA-256, ECDSA signing)."""
from __future__ import annotations

import importlib.util
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

LAUNCHER_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = LAUNCHER_ROOT / "scripts" / "build-launcher-release-metadata.py"

spec = importlib.util.spec_from_file_location("build_launcher_release_metadata", SCRIPT_PATH)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class LauncherReleaseMetadataTests(unittest.TestCase):
    def test_channel_tag_validation_enforces_stable_and_testing_isolation(self) -> None:
        mod.validate_channel_tag("stable", "v2.2.0")
        mod.validate_channel_tag("testing-core-ui", "v2.2.0-testing.core-ui.1")

        with self.assertRaises(ValueError):
            mod.validate_channel_tag("stable", "v2.2.0-testing.core-ui.1")
        with self.assertRaises(ValueError):
            mod.validate_channel_tag("stable", "v2.2.0-rc.1")
        with self.assertRaises(ValueError):
            mod.validate_channel_tag("testing-core-ui", "v2.2.0")
        with self.assertRaises(ValueError):
            mod.validate_channel_tag("testing-core-ui", "v2.2.0-testing.registry24")

    def test_build_metadata_computes_exact_hashes_and_signs_with_ecdsa(self) -> None:
        with tempfile.TemporaryDirectory(prefix="soulspire_meta_test_") as tmp:
            root = Path(tmp)
            exe_path = root / "SoulspireLauncher.exe"
            updater_path = root / "SoulspireUpdater.exe"
            zip_path = root / "SoulspireLauncher-win-x64.zip"

            exe_path.write_bytes(b"MZ" + b"L" * 2048)
            updater_path.write_bytes(b"MZ" + b"U" * 1024)
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.write(exe_path, arcname="SoulspireLauncher.exe")
                zf.write(updater_path, arcname="SoulspireUpdater.exe")

            priv_pem = None
            pub_pem = None
            if shutil.which("openssl"):
                priv_file = root / "priv.pem"
                pub_file = root / "pub.pem"
                subprocess.run(
                    ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(priv_file)],
                    check=True,
                    capture_output=True,
                )
                subprocess.run(
                    ["openssl", "ec", "-in", str(priv_file), "-pubout", "-out", str(pub_file)],
                    check=True,
                    capture_output=True,
                )
                priv_pem = priv_file.read_text(encoding="utf-8")
                pub_pem = pub_file.read_text(encoding="utf-8")

            meta = mod.build_metadata(
                channel="testing-core-ui",
                tag="v2.2.0-testing.core-ui.1",
                package_path=zip_path,
                executable_path=exe_path,
                updater_path=updater_path,
                owner="Infomatictek",
                repo="soulspirexi-launcher",
                private_key_pem=priv_pem,
            )

            self.assertEqual(meta["channel"], "testing-core-ui")
            self.assertEqual(meta["version"], "2.2.0-testing.core-ui.1")
            self.assertEqual(
                meta["downloadUrl"],
                "https://github.com/Infomatictek/soulspirexi-launcher/releases/download/v2.2.0-testing.core-ui.1/SoulspireLauncher-win-x64.zip",
            )
            self.assertEqual(len(str(meta["sha256"])), 64)
            self.assertEqual(len(str(meta["executableSha256"])), 64)
            self.assertEqual(len(str(meta["updaterSha256"])), 64)

            if priv_pem and pub_pem:
                self.assertEqual(meta["signatureAlgorithm"], "ECDSA-P256-SHA256")
                sig = str(meta["signatureBase64"])
                payload = mod.build_canonical_signing_payload(meta)
                self.assertTrue(mod.verify_payload_openssl(payload, sig, pub_pem))

                # Tampering with metadata invalidates signature
                tampered = dict(meta)
                tampered["sha256"] = "0" * 64
                self.assertFalse(mod.verify_payload_openssl(mod.build_canonical_signing_payload(tampered), sig, pub_pem))


if __name__ == "__main__":
    unittest.main()
