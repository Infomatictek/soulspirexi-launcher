# SoulspireXI — Windows & Linux Hybrid Native 3D Weapon Development Workflow (`BLK-005`)

**Task ID:** `WS3-WEAP-002`  
**Blocker:** `BLK-005` (OPEN until signature-verified 3D bone-attachment hook, live Ashita v4 verification, and Phase 6 8-race screenshots complete)  
**Authoritative Registry Pipeline:** `Infomatictek/soulspirexi/registry/weapon_configs.json` → `plugins/ashita4/data/soul-weapon-config.json` (distributed via `manifest.json`)

---

## 1. Exact Division of Work: Unraid Linux vs. Windows Gaming PC

### A. Tasks Completable Automatically on Unraid Linux (Zero Windows Runtime Required)
1. **Centralized Registry Authoring & Compilation:** Edit `registry/weapon_configs.json` and run `tools/registry_compiler.py --generate --launcher-repo <path>` to produce `soulspire_weapon_config_generated.lua` and integrity-checked `plugins/ashita4/data/soul-weapon-config.json` (zero DLL rebuild for new Soul rules).
2. **Isolated Server Image Compilation & Real-Engine Certification:** Build isolated `soulspirexi/server:cert-*` Docker images containing `patches/0001..0077` and run full real-engine `xi_test` suites (`soul_weapon_config`) without touching live prod/staging containers.
3. **Narrowly Scoped `.text` Code-Window Analysis (Zero Full Process Dumps, Zero PII):**
   - Verified on-disk retail `FFXiMain.dll` (`2,905,680` B, `sha256:d809ebe33301...`, `TimeDateStamp=0x6AE818B4`, `SizeOfImage=0x00C17000`) is staged privately at `/mnt/user/soulspire-dev/native-research/client/FFXiMain.dll` (never committed to Git). Because on-disk `.text` has `RawSize=0` (`POL1` runtime-unpacked), static `.text` disassembly uses a **narrowly scoped, opt-in Ashita v4 developer probe** (`core/weapon_render_probe.lua`, disabled by default) rather than a full process memory dump.
   - **Never bypass or reimplement PlayOnline's loader**, never dump full process memory, and never collect credentials, account IDs, character names, chat, inventory, or unrelated memory.
   - Once `/mnt/user/soulspire-dev/native-research/signatures/soul-weapon-render-probe.local.json` (`< 50 KB`, strictly bounded `.text` instruction windows normalized to `0x10000000`) is provided, `/mnt/user/soulspire-dev/native-research/disassembly/analyze_weapon_probe.py` disassembles the matched `D3DTS_WORLD` / `wep0` / `wep1` / `GrapIDTbl` sites on Unraid Linux (`objdump -m i386 -M intel`) to extract exact 24-byte ASLR-relocated signatures for `soulspire_native/hooks/layout.h` and bind `WeaponPresentationManager::evaluate()`.
4. **Windows MSVC `/W4 /WX` Compilation, `selftest.exe`, & Binary Sync:**
   - Executed automatically on GitHub Actions `windows-latest` via `.github/workflows/build-launcher.yml` (`build-soulspire-native` + `sync-soulspire-native-binary`), committing the CI-verified `plugins/ashita4/soulspire_native.dll`, `soulspire_native/dll_sync_state.json`, and updated `manifest.json` directly back to `feat/berserker-dual-great-axe` with full provenance.

### B. Tasks Strictly Requiring Your Windows Gaming PC (FFXI + Ashita v4)
1. **Run the Narrowly Scoped Developer Probe (2 Commands, Zero Process Dumps):**
   - Launch FFXI normally via **SoulspireLauncher** (Testing Channel — zero manual DLL or DAT copying).
   - In-game, run:
     - `/soulspire weapondiag on`
     - `/soulspire weapondiag probe`
     - `/soulspire weapondiag off`
   - Copy the tiny private report (`< 50 KB`, gitignored) from `<Ashita>\plugins\data\soul-weapon-render-probe.local.json` to `/mnt/user/soulspire-dev/native-research/signatures/soul-weapon-render-probe.local.json`.
   - *(Already recovered on Unraid — no need to copy)* All 7 playable race skeleton DATs (`ROM/27/82.DAT`..`56/59.DAT`) are already symlinked from `dat-overlays/flintlock-akimbo-compact/ROM` and their `0x29` bone hierarchies are extracted in `/mnt/user/soulspire-dev/native-research/skeletons/`.
2. **Launcher-Delivered Testing Sync (Zero Manual DLL or DAT Copying):**
   - Launch **SoulspireLauncher** pointed at the Testing Channel build (produced by `build-testing-channel` in `build-launcher.yml`) or the branch manifest once promoted.
   - SoulspireLauncher automatically downloads and SHA-256-verifies `plugins/soulspire_native.dll`, `plugins/data/soul-weapon-config.json`, `addons/crystalsocket/`, `addons/soulspire_core/`, and `addons/soulspire_flintlock/` — **no manual DLL copying, manual DAT edits, or standalone player addons required**.
3. **Live Runtime Hook Verification & Equipment Menu Playtest:**
   - Log into the aligned staging server build (containing Patch `0077`) as WAR Berserker (Lv.10+), WAR Commander, WAR Spartan, unsocketed WAR, and COR Flintlock.
   - Run `/crystalsocket debug` and `/soulspire status` to confirm all native hooks installed cleanly (`init_stage=ok`), `soul-weapon-config.json` loaded, and `weaponConfigHash=85de194dbb914f94`.
   - Verify native Sub equipment menu shows Great Axes **only** on WAR Berserker, equips two different Great Axes without commands, immediately strips Sub Great Axe on Main unequip or incompatible Main swap (Patch `0077`), and leaves Flintlock & non-Berserker Souls unaffected.
4. **Live Alignment Studio Calibration & Phase 6 Visual Certification:**
   - Run `/soulspire weapondiag on` in Ashita v4 (disabled by default for all players).
   - Adjust drawn/sheathed Main & Sub transforms live across all 8 playable character models, confirm rendered weapons visibly move in-world, click **Save Calibration** (persists `plugins/data/soul-weapon-calibration.local.json` and calls `SoulspireNativeReloadConfig()`), and click **Export JSON** (`/soulspire weapondiag export`).
   - Capture Phase 6 screenshots (drawn front, drawn side, sheathed rear, sheathed side, small + large Great Axes, remote observer view) for all 8 playable models and commit finalized transforms into `registry/weapon_configs.json` before setting `visualCertified: true`.

---

## 2. Flintlock Research Reuse Summary

Existing Flintlock reverse-engineering (`docs/flintlock-dual-pistols-progress.md`, `addons/ashita4/crystalsocket/soul_appearance.lua`) established:
- **Exact FFXI Pelvis / Back Coordinate Conventions Verified In-Game:**
  - `X = 0` is the sagittal mirror plane (`left/right` mirrored as `-tx`, `-yaw`, `-roll`).
  - `+Z` is **rear** in FFXI torso/pelvis local space (`-Z` is forward), confirmed during Flintlock's forward-nudge alignment across all 7 race skeletons (`ROM/27/82.DAT` through `ROM/56/59.DAT`).
  - Race skeleton mapping (shared M/F Tarutaru rig `ROM/46/93.DAT`) is already reused verbatim in `registry/weapon_configs.json` (`dual_2h_crossed_back_x`).
- **Why Native 3D Bone-Attachment Hook Is Still Required for Berserker:**
  - Flintlock Phase 1 achieved visual dual pistols via **278 static XIPivot DAT overlays** + `GrapIDTbl` (`0x0051`/`0x000A`/`0x000D`) slot masking, which cannot independently display two arbitrary Great Axe models per-actor without global DAT mutation.
  - Once `/mnt/user/soulspire-dev/native-research/client/FFXiMain.dll` is provided, Linux static disassembly will target `FFXiMain.dll`'s character equipment mesh transform/bone-attach routine (where `GrapIDTbl` Main/Sub `wep0`/`wep1` meshes bind to skeleton bones during `RenderActor`), verify 24-byte ASLR signatures, and connect directly to the already-tested `WeaponPresentationManager::evaluate()`.
