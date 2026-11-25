# SoulspireXI Launcher — Automatic Self-Updater & One-Time Migration Guide

## Architecture Overview

Starting with `SoulspireLauncher` `v2.2.0` (on `feat/launcher-auto-self-updater`):

- **Zero-Admin Per-User Installation (`%LOCALAPPDATA%\SoulspireXI\Launcher\`)**:
  - `SoulspireLauncher.exe` — canonical entry point (Start Menu & Desktop shortcuts remain stable across updates).
  - `SoulspireUpdater.exe` — independently packaged, self-contained atomic updater & rollback helper.
  - `releases\<version>\` — versioned release archive (automatically retains current + previous 2 versions).
  - `rollback\SoulspireLauncher.prev.exe` — SHA-256 verified backup of the previous working executable.
  - `install-state.json` — tracks active version, previous version/hash, pending verification, and recovery state.
  - `logs\updater.log` — structured updater & rollback diagnostic log.
- **Preserved Player Data**:
  - `%APPDATA%\SoulspireXI\settings.json` (Update Channel, Production/Staging environment, Staging ports, graphics, gamepad, DPAPI-encrypted credentials, Ashita path) is **never overwritten**.
  - Existing `Ashita/` installations are preserved untouched.
- **Verified Trust Chain**:
  - Channel-isolated release metadata (`launcher-release.json`) strictly separates **Stable** (`vX.Y.Z`) from **Testing Core UI** (`vX.Y.Z-testing.core-ui.<N>`).
  - HTTPS-only allowlist (`github.com/Infomatictek/soulspirexi-launcher/releases/download/...`), streaming `.part` download with cleanup on interruption, SHA-256 verification of both ZIP and extracted `SoulspireLauncher.exe` / `SoulspireUpdater.exe`, PE header validation, ZipSlip protection, and ECDSA-P256-SHA256 signature verification (fail-closed on any mismatch or tampering).
  - `SoulspireUpdater.exe` is always staged out of the active installation directory before execution, handles Windows file locks / Defender scans with retries, performs atomic replacement (`File.Replace`), automatically rolls back if any swap step fails, and restarts `SoulspireLauncher.exe --just-updated`.
- **Staging Relay Coordination**:
  - Automatic updates defer cleanly if the Staging TCP relay (`StagingRelayService`) is running so active gameplay sessions are never severed; manual update clicks explicitly warn and require user confirmation before stopping the relay.

---

## One-Time Manual Migration (Existing Players on Pre-2.2.0 Launchers)

> **Honest Migration Note:** Earlier `SoulspireLauncher.exe` builds (`v2.1.10` and temporary GitHub Actions artifacts without `SoulspireUpdater.exe` or channel-scoped `launcher-release.json` support) cannot automatically acquire the new standalone updater, SHA-256/ECDSA package verification, or per-user versioned directory layout until updated **once**.

To migrate an existing Windows PC onto the self-updating installation (one time only):

1. Download the published **`SoulspireLauncher-win-x64.zip`** from the GitHub Release for your channel (Stable or Testing Core UI) and extract `SoulspireLauncher.exe` + `SoulspireUpdater.exe` into any temporary folder (e.g. `Downloads\SoulspireLauncher\`).
2. Run `SoulspireLauncher.exe` (no Administrator prompt required).
3. Open **Setup & Diagnostics** → click **`Install Per-User`** (installs into `%LOCALAPPDATA%\SoulspireXI\Launcher\`, preserves your existing `Ashita` folder and `%APPDATA%\SoulspireXI\settings.json`, creates Start Menu + Desktop shortcuts, and relaunches from the installed copy).
4. Delete the temporary folder in `Downloads`. From this point forward, every launcher update downloads, verifies, installs, and restarts automatically.

---

## Windows End-to-End Upgrade Verification Protocol (Older Build → Newer Build)

1. Publish an initial Testing Core UI release (e.g. `v2.2.0-testing.core-ui.1`) via GitHub Actions `workflow_dispatch` (`publish_channel=testing-core-ui`, `release_tag=v2.2.0-testing.core-ui.1`) or tag push.
2. Perform the one-time per-user installation on Windows from `v2.2.0-testing.core-ui.1`, select **Testing — SoulspireXI Core UI & Gamepad** + **Staging Server**, and verify normal launch.
3. Publish a newer Testing Core UI release (e.g. `v2.2.0-testing.core-ui.2`).
4. Start the installed `v2.2.0-testing.core-ui.1` launcher on Windows without downloading anything manually:
   - Confirm status transitions: `Checking` → `Downloading (%)` → `Verifying SHA-256` → `Installing via SoulspireUpdater` → `Restarting` → `Update completed (v2.2.0-testing.core-ui.2)`.
   - Confirm `%LOCALAPPDATA%\SoulspireXI\Launcher\releases\2.2.0-testing.core-ui.2\SoulspireLauncher.exe`, `rollback\SoulspireLauncher.prev.exe`, and `logs\updater.log` exist.
   - Confirm Update Channel (`Testing Core UI`), Server Environment (`Staging`), Ashita path, and game manifest sync are preserved.
   - Test **Setup & Diagnostics → Rollback to 2.2.0-testing.core-ui.1** and verify clean rollback + restart.
