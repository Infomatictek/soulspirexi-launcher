# SoulspireXI Launcher (`Infomatictek/soulspirexi-launcher`) — AI Agent Guide

## Authoritative Context Recovery

Before making changes, recover full cross-repository project context from the Project Control Center in **`Infomatictek/soulspirexi`**:

- Primary recovery doc: `docs/project/AI_CONTEXT_RECOVERY.md`
- Active tasks & WIP cap (max 3): `docs/project/ACTIVE_TASKS.md`
- Open blockers: `docs/project/BLOCKERS.md`
- Architecture decisions (`DEC-001`–`DEC-028`): `docs/project/DECISIONS.md`
- Native client migration architecture: `docs/architecture/CLIENT_MODERN_001_VANACORE_NATIVE_ARCHITECTURE.md`

## Repository Role & Canonical Rules

- **Purpose:** Official `SoulspireLauncher` (`.NET` / WinForms + `SoulspireUpdater`), client manifests (`Stable` & `Testing`), Ashita v4 addons, VanaCore-native unified `addons/vanacore/soulspire_core/` (`4.0.0-vanacore`), and canonical `soulspire_native/` (`soulspire_native.dll`).
- **Canonical Channels (`DEC-019`, `DEC-024`, `DEC-027`):**
  - `Stable` (`manifest.json`, `v2.1.8`) and `Testing` (`channels/testing/manifest.json` on `main`, `v2.2.3-testing.*`) are the only user-facing channels.
  - Never promote unverified changes (`clientVerified: false` / `nativeDllClientVerified: false`) to `Stable`.
  - Keep `channels/testing/modern-client.json` strictly synchronized with `channels/testing/manifest.json["modernClient"]` across `baseline`, `compat`, and `native`.
  - Preserve `ECDSA-P256-SHA256` release signing (`keys/soulspire-launcher-release-v1.pub.pem`), SHA-256 verification, and `--password-stdin` credential handling (never pass plaintext passwords on CLI).
- **Zero-Ashita Native Direction (`DEC-028`):**
  - `addons/vanacore/soulspire_core/` must have zero `AshitaCore`, `ashita.*`, `d3d8`, `soulspire_native.dll`, or `crystaljobs.dll` references, enforced by `tests/test_vanacore_compat.py` and `[addons] ashita.enabled=0`.
- **Mandatory Local Checks Before Push:**
  - `python3 -m unittest discover -s tests -p "test_*.py" -v`
  - `python3 scripts/verify-launcher-manifest.py`
  - `python3 scripts/verify-launcher-manifest.py --manifest channels/testing/manifest.json`
