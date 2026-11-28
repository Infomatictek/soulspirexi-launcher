#!/usr/bin/env python3
"""Add the optional BattleLens files to Testing, leaving Stable untouched."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "channels" / "testing" / "payload" / "addons" / "vanacore" / "battlelens"
MANIFEST = ROOT / "channels" / "testing" / "manifest.json"
PREFIX = "channels/testing/payload/addons/vanacore/battlelens/"


def entries() -> list[dict[str, object]]:
    result = []
    for name in ("README.md", "battlelens.lua", "rules.lua"):
        data = (SOURCE / name).read_bytes()
        result.append({
            "category": "addon",
            "sourcePath": PREFIX + name,
            "targetPath": "vanacore/battlelens/" + name,
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
        })
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check without writing")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    existing = [entry for entry in manifest["files"]
                if str(entry.get("sourcePath", "")).startswith(PREFIX)]
    expected = entries()
    if args.check:
        if existing != expected:
            print("BattleLens Testing manifest entries are out of date")
            return 1
        print("BattleLens Testing manifest entries verified")
        return 0
    manifest["files"] = [entry for entry in manifest["files"]
                         if not str(entry.get("sourcePath", "")).startswith(PREFIX)] + expected
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8", newline="\n")
    print("Updated BattleLens Testing manifest entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
