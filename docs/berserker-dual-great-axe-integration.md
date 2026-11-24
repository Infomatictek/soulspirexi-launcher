# SoulspireXI — Berserker Dual Great Axe Native Equipment & Visual Integration

**Task ID:** `WS3-WEAP-002` (Expanded)  
**Repositories:** `Infomatictek/soulspirexi` (`berserker_dual_great_axe`) & `Infomatictek/soulspirexi-launcher` (`feat/berserker-dual-great-axe`)  
**Canonical Native Foundation:** `soulspire_native/` (`plugins/ashita4/soulspire_native.dll`, 27 hooks, ABI v2, `DEC-015`)  
**Authoritative Registry Source:** `Infomatictek/soulspirexi/registry/weapon_configs.json` (keyed by immutable permanent Soul IDs from `registry/souls.json`, preserving frozen `registryHash: cf86aa59ff8d16c6`)  
**Generated Client Artifact (via Launcher `manifest.json`):** `plugins/ashita4/data/soul-weapon-config.json` (`schemaVersion: 1`, FNV-1a64 + FNV-1a32 integrity checked)

---

## 0. Database-Driven Native Weapon Hooks Architecture (Phase 2)

```
registry/souls.json + registry/locked_ids.json + registry/weapon_configs.json
        │
        ▼ (tools/registry_compiler.py / tools/registry_publish.py)
        ├──► Server: modules/custom/lua/soulspire_weapon_config_generated.lua
        │         └── loaded in memory by soulspire_weapon_config.lua (zero runtime SQL)
        └──► Client: plugins/ashita4/data/soul-weapon-config.json
                  └── distributed via manifest.json (SHA-256 verified)
                        ├──► soulspire_native/equipment/weapon_config_loader.h
                        │     ├── populates WeaponRuleCatalog (Hooks #22, #25, #26, #27)
                        │     └── populates WeaponPresentationManager (8-race profiles)
                        ├──► addons/ashita4/crystalsocket/weapon_config.lua & soul_appearance.lua
                        ├──► addons/ashita4/soulspire_flintlock/flintlock_state.lua
                        └──► addons/ashita4/soulspire_core/core/weapon_presentation.lua
```

- **Zero hardcoded Soul rules in native hooks:** `weapon_rules.h`, `weapon_config_loader.h`, `weapon_presentation.h`, and `soulspire_native.cpp` contain zero Soul names, job/branch rules, level gates, or weapon skill constants.
- **Fail-closed integrity:** Missing, stale (`registryHash` mismatch), schema-mismatched (`schemaVersion != 1`), or tampered (`integrityFnv1a64` / `integrityFnv1a32` mismatch) config fails closed to vanilla FFXI behavior.
- **Zero-recompile extensibility proven:** Adding a new Soul weapon rule (e.g., `drk_dps` dual Scythe reusing `dual_2h_crossed_back_x`) in `registry/weapon_configs.json` compiles both server Lua and client `soul-weapon-config.json` and activates in `WeaponRuleCatalog` + `WeaponPresentationManager` without editing or recompiling C++ or `soulspire_native.dll` (verified in `test_soul_weapon_config.py` and `soulspire_native/tests/selftest.cpp`).
- **Remaining Hardcoded Values Audit:**
  - `soulspire_native/hooks/layout.h` — `FFXiMain.dll` PE fingerprint (`TS=0x6AE818B4`, `SizeOfImage=0x00C17000`) & 49 ASLR-relocated 24-byte signatures: **Required client binary safety isolation** (explicitly separated from gameplay config).
  - `soulspire_native/core/api.h` & `weapon_config.lua` — Engine enum constants (`DUAL_1H=1`, `DUAL_2H=2`, `TWOHAND_SHIELD=3`, FFXI `SkillType` 1..12, `PlayableRace` 1..8, packet offsets `0x0051`/`0x000A`/`0x000D`/`0x1FC`, `PeerSoulRegistry::kMaxPeers=128`, `kTtlMs=120000`): **Stable FFXI protocol / C ABI constants**, not gameplay or Soul rules.
  - `modules/custom/lua/soulspire_polearm_buckler.lua` & `war_specs.lua` — Legacy `OX_POLEARM_BUCKLER` local-var combat/guard hook used by pre-`0073` C++ `CanEquipPolearmBuckler`: **Retained for backwards compatibility** alongside authoritative `war_tank` entry in `registry/weapon_configs.json`; zero conflict.
  - `addons/ashita4/soulspire_flintlock/flintlock_state.lua` — `FIREARM_SKILLS = { [26] = true }` (FFXI Marksmanship skill ID) and `0x7073` ranged-cancel packet constant: **FFXI client protocol constants**; Soul gating itself is loaded dynamically from `soul-weapon-config.json` (`rangedOnly`).
  - `soulspire_native/rendering/weapon_presentation.h` — Scale bounds `[0.25f, 2.5f]` and `kMaxBindings=256`, `kMaxProfiles=32`: **Memory/render safety bounds** preventing malformed developer calibration transforms.

---

## 1. Phase 1 — Native Equipment Menu Audit & Repair

### Verified `FFXiMain.dll` Pipeline (`TS=0x6AE818B4`, `SizeOfImage=0x00C17000`, base `0x10000000`)

All 4 native Sub-slot equipment hooks are verified against exact 24-byte ASLR-relocated signatures in `soulspire_native/hooks/layout.h` and compiled into the canonical 27-hook `soulspire_native.dll`:

| Hook # | RVA | Function / Site | Role in Berserker Sub Great Axe Flow |
|---:|---|---|---|
| **#26** | `0x21DF85` | Sub menu list builder (`0x133795 → 0x21DDF0`) | Allows `Slots & 1` items into Sub (`eax == 2`) **only** when `active_action_soul()` confirms `WAR:berserker` (`job=1, branch=2, lvl>=10`) and `sub_skill == GREAT_AXE (6)`. |
| **#25** | `0x133D56` | `EquipMenu::TryEquipItem` DW gate (`push 0x8b`) | Allows non-vanilla DW `WAR:berserker` past the hardcoded `{NIN, THF, DNC, BLU}` gate only when Main & Sub are both Great Axes (`main_skill == 6 && sub_skill == 6`). |
| **#27** | `0x133DD3` | `EquipMenu::TryEquipItem` 2H Main gate (`push 0x99`) | Allows 2H Great Axe Main + Great Axe Sub only when `allows_2h_main_with_sub()` matches active `WAR:berserker`. |
| **#22** | `0x133E33` | `EquipMenu::TryEquipItem → CanEquipItemInSlot` (`0x133580`) | Allows Main-only (`slots == 1`) Great Axe in Sub (`slot == 1`) only when `CanEquipItemInSlot(item, 0)` passes (job, level, race, encumbrance) AND active `WAR:berserker` `DUAL_2H` rule matches. |

### Root Cause Confirmed on `main` (`e88f542`)

Although `soulspire_native.dll` on launcher `main` already contained all 27 hooks (#22, #25, #26, #27), `addons/ashita4/crystalsocket/weapon_config.lua` on `main` only synced **1 rule** (`BRD Adventurer` `DUAL_1H`). Because `WAR Berserker` (`job=1, branch=2, mode=DUAL_2H, GREAT_AXE`) was omitted from `W.RULES`, `weapon_rule_catalog.has_rules_for(1, 2)` returned `false` and Hook #26 skipped every Great Axe in the native Sub menu.

### Fix & Mandatory Exclusivity Enforcement

- Registered `WAR:berserker` (`job=1, branch=2, min_effective_level=10, mode=DUAL_2H, main_skills={GREAT_AXE}, sub_skills={GREAT_AXE}`) exclusively in `addons/ashita4/crystalsocket/weapon_config.lua`.
- **Fail-closed identity:** Unknown/unsynchronized Soul state, unsocketed `WAR` (`branch=0`), `WAR Commander` (`branch=1`), `WAR Spartan` (`branch=3`), level sync below Lv.10, and all other 65 Souls fail closed across both client (`soulspire_native` + `crystalsocket`) and server (`soulspire_weapon_config.lua` + patches `0073`/`0075`).
- **Zero blanket 2H bypass:** Great Swords, Polearms, Scythes, Great Katanas, Staves, and 1H weapons are all rejected for `DUAL_2H` (including on `WAR/NIN` subjob).

---

## 2. Phase 2 & Phase 3 — Drawn Dual Great Axe & Crossed-Back X Sheathing Architecture

### Flintlock Infrastructure Generalization Audit

Auditing COR Flintlock (`dat-overlays/flintlock-akimbo-compact/`, `addons/ashita4/soulspire_flintlock/`, `addons/ashita4/crystalsocket/soul_appearance.lua`, and `docs/flintlock-soul-specific-appearance-design.md`) confirmed:
- Flintlock's existing visual delivery relies on **278 static DAT overlays** (`defaultEnabled: false` in XIPivot) plus packet-level `GrapIDTbl` Main/Sub masking in `soul_appearance.lua`.
- Static DAT overlays cannot solve Berserker's requirement because they apply process-globally to all players equipping a Great Axe model (leaking onto WAR Commander/Spartan/DRK/etc.) and cannot independently display two arbitrary Great Axe models simultaneously without modifying hundreds of global weapon DATs.
- **Generalized Solution (No Standalone Player-Facing Addon):**
  - Unified both `war_berserker_dual_great_axe` and `cor_flintlock_dual_pistols` under one authoritative, launcher-distributed configuration schema: **`plugins/ashita4/data/soul-weapon-presentation.json`** (`SOULSPIRE_WEAPON_PRESENTATION_V1`).
  - Added reusable C++17 runtime state, 8-race transform resolver, and bounded `OXSI` peer-actor registry in **`soulspire_native/rendering/weapon_presentation.h`**.
  - Integrated runtime configuration loading, `OXSI` peer tracking, and developer-only live alignment studio directly into existing **`addons/ashita4/soulspire_core/core/weapon_presentation.lua`** (no new standalone player-facing addon).

### Animation Compatibility Audit (No Combat Coefficient Changes)

| State | Vanilla FFXI Great Axe Behavior | Dual Great Axe Runtime Adaptation Policy |
|---|---|---|
| **Idle (Disengaged)** | Single Great Axe diagonally on back (`wep1`). | **Crossed-back X formation (`sheathed_cross_x`):** Main axe head over right shoulder (handle toward left hip, `+roll`), Sub axe head over left shoulder (handle toward right hip, `-roll`), positive back-depth separation (`+0.032m..+0.044m`) to prevent shaft intersection. |
| **Walk / Run (Disengaged)** | Single back-sheathed Great Axe follows upper-spine bone. | Both crossed Great Axes ride the upper-spine attachment transform cleanly with race-tuned clearance for capes, hair, and armor. |
| **Idle / Movement (Engaged)** | 2H two-hand grip on right-hand weapon (`wep0`), no left-hand weapon. | **1H dual-wield stance adapted (`drawn_dual_2h`):** Main Great Axe attached to right hand (`drawn.main`), Sub Great Axe attached to left hand (`drawn.sub`), each preserving its independently resolved retail weapon model ID. |
| **Auto-Attack Swings** | Right-hand 2H swing only (`RIGHTATTACK`). | Independent right-hand (`RIGHTATTACK`) and left-hand (`LEFTATTACK`) 1H dual-wield swing timelines driving the attached Great Axe models without modifying Berserker's server combat coefficients (`0.72` / `0.52` / `0.58` / `0.85`). |
| **Casting** | Stock casting pose. | Stock casting pose with dual weapons lowered/retained cleanly; no floating attachments. |
| **Weapon Skills** | Stock Great Axe WS animations (e.g., Sturmwind, Raging Rush, Steel Cyclone, Upheaval). | `main_hand_great_axe_ws_preserve_sub`: Main Great Axe executes stock Great Axe WS timeline while Sub Great Axe remains cleanly anchored/sheathed for WS duration and restores on completion. |
| **Death / Zoning / Soul Switch** | Vanilla appearance. | Immediately clears active presentation override and restores stock vanilla rendering; zero lingering or duplicate weapon attachments. |

### Explicit Windows Native 3D Renderer Hook Prerequisite (`BLK-005`)

On this Unraid Linux host, neither retail `FFXiMain.dll` nor retail `ROM/*.DAT` weapon meshes are present, and no Windows Ashita v4 client can run locally (`BLK-005`). Per project governance, **zero unverified/guessed `FFXiMain.dll` 3D bone-matrix or Direct3D 8 draw-submission RVAs have been injected into `soulspire_native.dll`**.

What is **implemented & verified today**:
1. Complete native equipment menu repair (all 27 verified hooks + `weapon_config.lua` WAR Berserker `DUAL_2H` registration + 66-Soul exclusivity).
2. Complete server validation, combat profile preservation, and independent Main/Sub actual model metadata (`WC.getEquippedWeaponPresentation`).
3. Complete reusable presentation configuration (`soul-weapon-presentation.json`), C++17 `WeaponPresentationManager` + `PeerSoulRegistry` (`weapon_presentation.h`), Lua runtime + `OXSI` peer isolation, and developer-only live alignment studio (`/soulspire weapondiag`, disabled by default).
4. Safe server visual fallback (`compact_dual_axe` `(84, 84)`) preserved until the Windows native 3D bone-attachment hook is signature-verified on Windows `FFXiMain.dll`.

What **requires a Windows reverse-engineering & live Ashita v4 session** to finish 3D in-world rendering:
1. Locate and 24-byte-signature-verify `FFXiMain.dll`'s character skeleton bone-matrix / `wep0`–`wep1` D3D8 mesh submission site on Windows (`TS=0x6AE818B4`).
2. Bind that verified hook to `soulspire::native::WeaponPresentationManager::evaluate()` (consuming the exact `main_model_id`, `sub_model_id`, and `main_transform`/`sub_transform` already built and unit-tested here).
3. Switch Berserker's server `look` from fallback `compact_dual_axe` to runtime native presentation once Windows visual verification passes.

---

## 3. Phase 4 — All 8 Playable Character Models & Developer Live Alignment Controls

All 8 playable FFXI character models are configured independently in `plugins/ashita4/data/soul-weapon-presentation.json`:

| Race ID | Key | Display Name | Skeleton DAT | Drawn Scale | Sheathed Main `(x, y, z, roll°)` | Sheathed Sub `(x, y, z, roll°)` | Depth Sep |
|---:|---|---|---|---:|---|---|---:|
| 1 | `hume_male` | Hume Male | `ROM/27/82.DAT` | `0.94` | `(-0.045, 0.060, 0.145, +42.0°)` | `(+0.045, 0.060, 0.183, -42.0°)` | `0.038` |
| 2 | `hume_female` | Hume Female | `ROM/32/58.DAT` | `0.90` | `(-0.040, 0.055, 0.135, +41.0°)` | `(+0.040, 0.055, 0.171, -41.0°)` | `0.036` |
| 3 | `elvaan_male` | Elvaan Male | `ROM/37/31.DAT` | `0.96` | `(-0.050, 0.075, 0.155, +43.0°)` | `(+0.050, 0.075, 0.195, -43.0°)` | `0.040` |
| 4 | `elvaan_female` | Elvaan Female | `ROM/42/4.DAT` | `0.92` | `(-0.044, 0.068, 0.145, +42.0°)` | `(+0.044, 0.068, 0.183, -42.0°)` | `0.038` |
| 5 | `tarutaru_male` | Tarutaru Male | `ROM/46/93.DAT` | `0.78` | `(-0.032, 0.045, 0.115, +39.0°)` | `(+0.032, 0.045, 0.147, -39.0°)` | `0.032` |
| 6 | `tarutaru_female` | Tarutaru Female | `ROM/46/93.DAT` | `0.78` | `(-0.032, 0.045, 0.118, +39.0°)` | `(+0.032, 0.045, 0.150, -39.0°)` | `0.032` |
| 7 | `mithra` | Mithra | `ROM/51/89.DAT` | `0.91` | `(-0.042, 0.058, 0.142, +41.5°)` | `(+0.042, 0.058, 0.178, -41.5°)` | `0.036` |
| 8 | `galka` | Galka | `ROM/56/59.DAT` | `1.04` | `(-0.062, 0.085, 0.205, +44.0°)` | `(+0.062, 0.085, 0.249, -44.0°)` | `0.044` |

### Developer-Only Live Alignment Workflow (Disabled by Default)

- Disabled by default (`diagnostics.enabled = false` in `soul-weapon-presentation.json` and `WeaponPresentationManager`).
- Enable in-game via `/soulspire weapondiag on` (disable with `/soulspire weapondiag off`).
- Provides independent Main and Sub controls for `X/Y/Z` translation, `Pitch/Yaw/Roll`, `Grip Offset (X/Y/Z)`, `Weapon Separation`, `Back Attachment Depth`, `Scale`, sagittal `Mirror Main -> Sub`, and `Export Authoritative JSON` (`/soulspire weapondiag export`).

---

## 4. Phase 6 — Visual Review Capture Matrix (PENDING LIVE WINDOWS CLIENT)

**Visual Certification Status:** **`NOT CERTIFIED`** (`visualCertified: false`). Calculated transforms and automated tests do **NOT** constitute visual certification. Live Windows Ashita v4 screenshots are required for all 8 playable character models using both a representative **small Great Axe** (e.g., `Butterfly Axe`, `MId=94`) and a representative **large Great Axe** (e.g., `Heavy Axe` `MId=93` / `Bravura` / `Byakko's Axe`), including mixed-model dual wielding:

| Playable Model | Drawn Front | Drawn Side | Sheathed Rear | Sheathed Side | Small + Large Mixed Models | Remote Observer View |
|---|---|---|---|---|---|---|
| Hume Male | Pending | Pending | Pending | Pending | Pending | Pending |
| Hume Female | Pending | Pending | Pending | Pending | Pending | Pending |
| Elvaan Male | Pending | Pending | Pending | Pending | Pending | Pending |
| Elvaan Female | Pending | Pending | Pending | Pending | Pending | Pending |
| Tarutaru Male | Pending | Pending | Pending | Pending | Pending | Pending |
| Tarutaru Female | Pending | Pending | Pending | Pending | Pending | Pending |
| Mithra | Pending | Pending | Pending | Pending | Pending | Pending |
| Galka | Pending | Pending | Pending | Pending | Pending | Pending |
