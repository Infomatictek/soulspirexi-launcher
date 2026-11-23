# Soulspire Native — Architecture, 27-Hook Inventory & Migration Guide

> **Canonical Module**: `soulspire_native/` (`plugins/ashita4/soulspire_native.dll`)
> **Namespace**: `soulspire::native` | **ABI Version**: `2` | **Expected Hooks**: `27`
> **Supported Client Binary**: `FFXiMain.dll` (`TimeDateStamp = 0x6AE818B4`, `SizeOfImage = 0x00C17000`, `ImageBase = 0x10000000`)

---

## 1. Subsystem Architecture

Soulspire Native owns all native Win32 x86 client hooks inside `FFXiMain.dll`. Boundaries across the SoulspireXI ecosystem:

| Layer | Owner | Responsibility |
|---|---|---|
| **Authoritative Data** | Centralized Game Registry (`soulspirexi/registry/souls.json`) | Single source of truth for all 66 Soul identities, abbreviations, and generated headers/JSON. |
| **Native Client Hooks** | **Soulspire Native** (`soulspire_native.dll`) | 27 verified `FFXiMain.dll` hooks, runtime identity/config loading, Search `menu2fon` renderer, native menu action names/help text, spell visibility, equipment eligibility (`DUAL_1H`, `DUAL_2H`, `TWOHAND_SHIELD`), and future DAT virtualization. |
| **Ashita / Lua UI & Bridges** | **Soulspire Core** & Ashita addons (`crystalsocket`, `soulspire_soul_actions`, `soulspire_soulhud`, `soulspire_flintlock`, `soulspire_gear`) | LuaJIT FFI bridge (`core/native_bridge.lua`, `job_labels.lua`), packet syncing, custom ImGui UI, and player commands. |
| **Distribution & Lifecycle** | **SoulspireLauncher** (`SoulspireLauncher.exe`) | Manifest-driven updates, Ashita boot script migration (`/load soulspire_native`), retirement of obsolete `crystaljobs.dll`, and conflict detection. |

### Directory Layout

```text
soulspire_native/
  core/               # C ABI v2 (api.h), config loader (config.h), shared runtime state (state.h), Ashita plugin entrypoint (plugin.h)
  hooks/              # 49 verified FFXiMain.dll signatures + ASLR relocation (layout.h), atomic Patch & PrologueDetour (hook_manager.h)
  registry/           # Compiled 66-Soul fallback table (labels_generated.h), runtime soul-identities.json loader (runtime_identity.h)
  job_identity/       # Search/Party/Status job labels, Search row cache, TCP Search transport (job_identity.h)
  equipment/          # Soul weapon rules catalog: DUAL_1H, DUAL_2H, TWOHAND_SHIELD (weapon_rules.h)
  actions/            # ActionCatalog, VisibilityCatalog, ASCII sanitizer, helpwind formatter (action_catalog.h)
  rendering/          # Immutable 16-bank menu2fon Search sprite renderer + verified SCH 'H' glyph (menu2fon.h)
  menus/              # Menu hook descriptors & metadata (menu_hooks.h)
  resources/          # Resource lifecycle & reload coordination (resource_manager.h)
  dat_virtualization/ # Phase E/F DAT virtualization subsystem interface (dat_virtualization.h)
  diagnostics/        # Level-gated [Soulspire Native] logger (diagnostics.h)
  compatibility/      # CrystalJobs* ABI v1 forwarding shim + legacy DLL mutual-exclusion guard (crystaljobs_compat.h)
  tests/              # Standalone Win32 x86 C++ self-test suite (selftest.cpp)
  soulspire_native.cpp
  soulspire_native.def
  build.cmd
  dll_sync_state.json
```

---

## 2. Complete 27-Hook Inventory

All 27 hooks validate their exact target bytes (relocated for ASLR from preferred base `0x10000000`) before patching. If any signature mismatches or if legacy `crystaljobs.dll` is already loaded in `pol.exe`, `SoulspireNativeInitialize()` fails closed cleanly (`init_stage = 5` or `7`) without patching or corrupting `FFXiMain.dll`.

| # | Bit | Name | FFXiMain RVA | Type | Subsystem | Purpose & Expected Behavior | Dependencies & Shared State | Automated Validation | Manual Client Validation |
|---:|---:|---|---|---|---|---|---|---|---|
| 1 | 0 | `search_recv_1` | `0x18D9F6` | CALL patch (`E8`) | JobIdentity | Intercepts `recv` inside Search TCP client to inspect Search results (`0x0003`) and populate `SearchCache`. | `Transport`, `SearchCache`, `JobIdentity` | Signature + mock hook + `selftest.exe` | Pending Windows Ashita v4 playtest |
| 2 | 1 | `search_recv_2` | `0x18DE06` | CALL patch (`E8`) | JobIdentity | Secondary Search TCP `recv` callsite for multi-packet Search result frames. | `Transport`, `SearchCache` | Signature + mock hook + `selftest.exe` | Pending Windows Ashita v4 playtest |
| 3 | 2 | `search_recv_3` | `0x18E31C` | CALL patch (`E8`) | JobIdentity | Tertiary Search TCP `recv` callsite for Search list continuations. | `Transport`, `SearchCache` | Signature + mock hook + `selftest.exe` | Pending Windows Ashita v4 playtest |
| 4 | 3 | `search_recv_4` | `0x18E435` | CALL patch (`E8`) | JobIdentity | Quaternary Search TCP `recv` callsite for trailing Search chunks. | `Transport`, `SearchCache` | Signature + mock hook + `selftest.exe` | Pending Windows Ashita v4 playtest |
| 5 | 4 | `search_row_badge` | `0x1E9210` | CALL patch (`E8`) | Rendering / JobIdentity | Replaces Search result row job badge draw with 3-glyph `menu2fon` Soul abbreviation (`[1, 8, 15]` 7px pitch). | `Menu2fonBank[16]`, `SearchCache`, `PresentationConfig` | `selftest.exe` + `test_search_presentation_spacing.py` | Pending Windows Ashita v4 playtest |
| 6 | 5 | `status_main_job` | `0x1D9754` | CALL patch (`E8`) | JobIdentity | Substitutes Status menu Main Job full Soul name (66 registry Souls). | `LocalState`, `RuntimeIdentityTable` | `selftest.exe` + registry parity tests | Pending Windows Ashita v4 playtest |
| 7 | 6 | `status_sub_job` | `0x1D9797` | CALL patch (`E8`) | JobIdentity | Substitutes Status menu Sub Job text safely without corrupting vanilla subjobs. | `LocalState`, `RuntimeIdentityTable` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 8 | 7 | `equipment_main_job` | `0x1D77E7` | CALL patch (`E8`) | JobIdentity | Substitutes Equipment screen Main Job abbreviation with active Soul abbreviation. | `LocalState`, `RuntimeIdentityTable` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 9 | 8 | `party_abbr_1` | `0x1D4039` | CALL patch (`E8`) | JobIdentity | Substitutes Party/Alliance list member job abbreviation (site 1). | `PartyCache`, `RuntimeIdentityTable` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 10 | 9 | `party_abbr_2` | `0x1D404B` | CALL patch (`E8`) | JobIdentity | Substitutes Party/Alliance list member job abbreviation (site 2). | `PartyCache`, `RuntimeIdentityTable` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 11 | 10 | `party_abbr_3` | `0x1D442B` | CALL patch (`E8`) | JobIdentity | Substitutes Party/Alliance list member job abbreviation (site 3). | `PartyCache`, `RuntimeIdentityTable` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 12 | 11 | `party_abbr_4` | `0x1D443D` | CALL patch (`E8`) | JobIdentity | Substitutes Party/Alliance list member job abbreviation (site 4). | `PartyCache`, `RuntimeIdentityTable` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 13 | 12 | `action_name_spell` | `0x1F3567` | CALL patch (`E8`) | Actions / Menus | Overrides Spell menu row display name for active Soul actions (`ActionCatalog`). | `ActionCatalog`, `LocalState` | `selftest.exe` + `test_soul_spell_dat_and_actions.py` | Pending Windows Ashita v4 playtest |
| 14 | 13 | `action_name_ja` | `0x1F3609` | CALL patch (`E8`) | Actions / Menus | Overrides Job Ability menu row display name for active Soul actions. | `ActionCatalog`, `LocalState` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 15 | 14 | `action_name_ws` | `0x1F369E` | CALL patch (`E8`) | Actions / Menus | Overrides Weapon Skill menu row display name for active Soul actions. | `ActionCatalog`, `LocalState` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 16 | 15 | `action_help_spell` | `0x22D651` | CALL patch (`E8`) | Actions / Menus | Overrides Spell helpwind description with ASCII-sanitized, wrapped Soul description. | `ActionCatalog`, `format_action_description` | `selftest.exe` + `test_soul_spell_dat_and_actions.py` | Pending Windows Ashita v4 playtest |
| 17 | 16 | `action_help_ja` | `0x22DF25` | CALL patch (`E8`) | Actions / Menus | Overrides Job Ability helpwind description. | `ActionCatalog`, `format_action_description` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 18 | 17 | `action_help_ws` | `0x22E2FB` | CALL patch (`E8`) | Actions / Menus | Overrides Weapon Skill helpwind description. | `ActionCatalog`, `format_action_description` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 19 | 18 | `action_name_macro` | `0x22D68A` | CALL patch (`E8`) | Actions / Menus | Overrides secondary/macro action name lookup for Soul spells/abilities. | `ActionCatalog`, `LocalState` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 20 | 19 | `menu_spell_elig` | `0x22E64D` | CALL patch (`E8`) | Actions / Menus | Enforces Soul-specific spell visibility/level eligibility inside Magic menu list builder. | `VisibilityCatalog`, `LocalState` | `selftest.exe` + `test_soul_spell_dat_and_actions.py` | Pending Windows Ashita v4 playtest |
| 21 | 20 | `menu_spell_row_compact` | `0x1F358F` | CALL patch (`E8`) | Actions / Menus | Compacts Magic menu row labels cleanly to `actionRowMaxChars` (default 16) without buffer overrun. | `ActionCatalog`, `PresentationConfig` | `selftest.exe` | Pending Windows Ashita v4 playtest |
| 22 | 21 | `soul_can_equip_in_slot` | `0x133E33` | CALL patch (`E8`) | Equipment | Intercepts `CanEquipItemInSlot` (`0x133580`) callsite inside Equipment validation to allow Soul-authorized `DUAL_1H`, `DUAL_2H`, and `TWOHAND_SHIELD` combinations. | `WeaponRuleCatalog`, `LocalState` | `selftest.exe` + `test_native_equipment_hook.py` | Pending Windows Ashita v4 playtest |
| 23 | 22 | `can_use_spell_detour` | `0x22CDE0` | 5-byte atomic `PrologueDetour` | Actions / Menus | Detours `CanUseSpell` prologue to evaluate `VisibilityCatalog` unlock/hide rules per active Soul and effective level. | `VisibilityCatalog`, `LocalState` | `selftest.exe` + `test_soul_spell_dat_and_actions.py` | Pending Windows Ashita v4 playtest |
| 24 | 23 | `missing_spell_bit_detour` | `0x22CB44` | 5-byte atomic `PrologueDetour` | Actions / Menus | Detours missing-spell bit check so Soul-unlocked spells display without modifying vanilla `114.DAT` levels. | `VisibilityCatalog`, `LocalState` | `selftest.exe` + `test_soul_spell_dat_and_actions.py` | Pending Windows Ashita v4 playtest |
| 25 | 24 | `soul_sub_weapon_detour` | `0x133D56` | 5-byte atomic `PrologueDetour` | Equipment | Detours Sub-slot Dual Wield trait gate (`0x8B`) to permit Soul-authorized `DUAL_1H` and `DUAL_2H` off-hand equipping. | `WeaponRuleCatalog`, `LocalState` | `selftest.exe` + `test_native_equipment_hook.py` | Pending Windows Ashita v4 playtest |
| 26 | 25 | `dual_2h_menu_detour` | `0x21DF85` | 5-byte atomic `PrologueDetour` | Equipment | Detours Equipment menu item filter (`0x21DF85`) to keep 2H weapons and shields selectable in Sub slot when authorized by active Soul rule (`DUAL_2H` / `TWOHAND_SHIELD`). | `WeaponRuleCatalog`, `LocalState` | `selftest.exe` + `test_native_equipment_hook.py` | Pending Windows Ashita v4 playtest |
| 27 | 26 | `dual_2h_equip_detour` | `0x133DD3` | 5-byte atomic `PrologueDetour` | Equipment | Detours 2H Main-hand incompatibility check (`0x99`) to permit 2H+2H (`DUAL_2H`) and 2H+Shield (`TWOHAND_SHIELD`) combinations when authorized. | `WeaponRuleCatalog`, `LocalState` | `selftest.exe` + `test_native_equipment_hook.py` | Pending Windows Ashita v4 playtest |

---

## 3. Stability Defects Resolved in Soulspire Native v2

1. **Shutdown NULL-jump race (Crash Fix)**: Legacy `CrystalJobsShutdown()` zeroed `soul_sub_weapon_deny_resume` and original function pointers *before* restoring hooks, allowing a concurrent client thread inside a detour to jump to `0x00000000`. Fixed by disabling the atomic `enabled` gate first, restoring all 27 patches/detours second, clearing state/TLS third, and never zeroing resume pointers.
2. **Torn 5-byte detour writes (Memory Safety Fix)**: `PrologueDetour::write_atomic5()` now uses `InterlockedCompareExchange64` (`lock cmpxchg8b`) to atomically swap bytes `[0..7]`, preventing another thread from executing a half-written `E9` jump instruction during attach/detach.
3. **Stale `soul_override` on unsocket (Soul Transition Fix)**: When CrystalSocket explicitly reports an unsocketed state (`known=true, from_bridge=true, branch=0`), `active_action_soul()` no longer falls back to a stale `soul_override` from a previous Soul.
4. **`menu2fon` sprite-bank exhaustion (Rendering Fix)**: Expanded `kMaxMenu2fonBanks` from 4 static BSS entries to 16 lazily heap-allocated immutable banks (`std::unique_ptr<Menu2fonBank>[16]`) with `menu2fon_banks_used` and `menu2fon_fallback_draws` telemetry, preventing fallback degradation across repeated D3D8 device resets and zone transitions.
5. **Long-session Search `Transport` saturation (Reconnect/Zone Fix)**: `Transport::reset()` now reclaims `next_request` across zone boundaries and `0x061` job-change packets reset `timeouts = 0`.
6. **Legacy DLL simultaneous-load conflict guard (Safety Fix)**: `SoulspireNativeInitialize()` detects if `crystaljobs.dll` is already mapped in `pol.exe` and fails closed with `init_stage = 7` (`SOULSPIRE_NATIVE_INIT_CONFLICT_LEGACY_DLL`), preventing double-patching of `FFXiMain.dll`.
7. **Hook #26 `TWOHAND_SHIELD` & Hook #25 telemetry**: Completed `TWOHAND_SHIELD` evaluation in `allows_2h_main_with_sub()` and wired allow/deny counters in `soul_allows_dual_2h_menu_item()`.
8. **Centralized Registry Hash Parity & Gated Logging**: Regenerated `soulspire_native/registry/labels_generated.h` from authoritative `registry/souls.json` (`cf86aa59ff8d16c6`, 66 Souls) and gated verbose diagnostic logs behind `soulspire_native.json` `logging.level` (default `"warn"`).

---

## 4. CrystalJobs → Soulspire Native Migration & Compatibility

### Temporary Backwards Compatibility
- **PE Exports**: `soulspire_native.dll` exports all 21 canonical `SoulspireNative*` functions, all 19 legacy `CrystalJobs*` forwarding shims, and 3 Ashita v4 plugin entrypoints (`expCreatePlugin`, `expDestroyPlugin`, `expGetInterfaceVersion`) = **43 total exports**.
- **Configuration**: Reads `plugins/ashita4/data/soulspire_native.json` first and falls back to `plugins/ashita4/data/crystaljobs-presentation.json` if only the legacy file exists.
- **Launcher Upgrade Safety**:
  - `AshitaConfigGenerator` strips legacy `/load crystaljobs` and `/unload crystaljobs` lines and writes `/load soulspire_native`.
  - `ManifestUpdateService.RemoveRetiredPlugins()` automatically deletes obsolete `plugins/crystaljobs.dll` and `plugins/data/crystaljobs-presentation.json` on sync/upgrade.
  - `FfxiInstallDetector` detects and reports an explicit `FAIL` conflict if both `soulspire_native.dll` and `crystaljobs.dll` are simultaneously present/loaded.

### Dependent Feature Branch Migration Plan

After Soulspire Native lands on `main`, active feature branches must consume the canonical foundation rather than maintaining divergent `native/crystaljobs/` copies:

| Branch | Repo | Action Required |
|---|---|---|
| `feat/soul-weapon-templates` | `soulspirexi-launcher` | Rebase/merge from `main`; drop branch-local `native/crystaljobs/` edits (Hooks #25–#27 are now canonical in `soulspire_native/`). Keep only `weapon_config.lua` rule additions using `WC.MODES.DUAL_2H` / `TWOHAND_SHIELD`. |
| `feat/crystalsocket-29-soul-icons` | `soulspirexi-launcher` | Merge `main`; adopt `soulspire_native.dll` load path in `crystalsocket.lua` / `job_labels.lua` (no conflict with Soul icon PNG assets). |
| `feat/soul-identity-registry-integration` / `feat/runtime-soul-identity-and-spacing` | `soulspirexi-launcher` & `soulspirexi` | Already superseded by `main`; archive/close branches after confirming no unmerged commits remain. |
| `feat/dat-virtualization-poc` | `soulspirexi-launcher` & `soulspirexi` | Branch fresh from post-merge `main` and extend `soulspire_native/dat_virtualization/` + `tools/registry_compiler.py`. |
