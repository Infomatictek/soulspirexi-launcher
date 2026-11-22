# SoulspireXI Core — Phase 1A Audit & Native Menu Integration Findings

## 1. Existing Client & Addon Architecture Audit

All client-side Ashita v4 addons, native hooks, DAT overlays, and launcher distribution live in `Infomatictek/soulspirexi-launcher` (while server modules/patches live in `Infomatictek/soulspirexi`).

| Component | Path (`soulspirexi-launcher`) | Mechanism / Dependencies | Preserved in Phase 1A |
|---|---|---|---|
| **CrystalSocket** | `addons/ashita4/crystalsocket/` | Read-only native `MenuManager` inspection (`AshitaCore:GetPointerManager():Get('menu')` -> `storage - 0x54`) anchored to `menu    equip` / `menu    iteminfo`; custom packet `0x05D` / `0x1FC` protocol; LuaJIT FFI sync to `crystaljobs.dll` (`CrystalJobsSetState`, `CrystalJobsReplaceWeaponRules`); `key_data` + writable `key_state` input consumption; `soul_appearance.lua` weapon-hiding for COR Flintlock. | Yes (untouched) |
| **Weapon Skill Talents** | `addons/ashita4/soulspire_talents/` | Standalone ImGui UI (`premium_ui.lua`, `art.lua`, custom PNG assets in `assets/`), server protocol for WS talent allocation/evolution. | Yes (untouched) |
| **Universal Soul HUD** | `addons/ashita4/soulspire_soulhud/` | Custom ImGui gauges/buffstrip (`soulhud_layout.lua`), read-only native menu/event/interface-hidden detector (`soulhud_menu.lua`) using `FFXiMain.dll` signatures so HUD hides cleanly during menus/cutscenes. | Yes (untouched) |
| **Soul Actions** | `addons/ashita4/soulspire_soul_actions/` | Syncs 66-Soul action catalog and visibility policy to `crystaljobs.dll` (`CrystalJobsReplaceCatalog`, `CrystalJobsReplaceVisibility`), resolves macros, rewrites local & OXSI peer combat log lines. | Yes (untouched) |
| **Native Hooks (`crystaljobs.dll`)** | `native/crystaljobs/`, `plugins/ashita4/crystaljobs.dll` | 32-bit x86 Ashita v4 plugin targeting retail `FFXiMain.dll` (`TS=0x6ae818b4`, `SizeOfImage=0xC17000`, base `0x10000000`). **24 verified hooks** (21 `CALL` patches + 3 `PrologueDetour` hooks): Equipment Soul name (`menu    persona `), Search Soul labels, Magic/Ability menu names/descriptions/icons/filtering/cast-check, and **Hook #24** (`0x133D56`) native Sub-weapon Dual Wield gate. Strictly validated by 24-byte signatures in `layout.h`. | Yes (untouched, 24/24 preserved) |
| **Flintlock Dual-Pistol Support** | `addons/ashita4/soulspire_flintlock/`, `dat-overlays/flintlock-akimbo-compact/` | Flintlock-gated ranged auto-facing (`flintlock_state.lua`), reads `crystaljobs.dll` via FFI, manages opt-in XIPivot `flintlock-akimbo-compact` DAT overlay (`pivot_config.lua`). | Yes (untouched) |
| **SoulspireXI Launcher** | `SoulspireLauncher/`, `manifest.json`, `scripts/update-launcher-manifest.py` | WPF .NET desktop launcher using official dark palette (`#0B0F17`, `#131A26`, `#192233`, `#263248`, `#F1F5F9`, `#94A3B8`, `#E5B94C`, `#2DD4BF`), transactional manifest updater, and `AshitaConfigGenerator.cs` (`scripts/soulspirexi.txt`). | Extended cleanly to distribute & auto-load `soulspire_core` |

---

## 2. Native Main Menu Integration Investigation (`FFXiMain.dll`)

### Verified Blocker for Genuine Binary Insertion

1. **`FFXiMain.dll` Binary Unavailable in Linux Build Environment**:
   - The supported retail 32-bit Windows `FFXiMain.dll` binary (`TimeDateStamp = 0x6ae818b4`, `SizeOfImage = 0xC17000`, preferred base `0x10000000`, packed SHA-256 `d809ebe333019395ad43ab7ec1d94d9f58fe1f62c2ae730334f730fa8e7d48fb`) is installed on the Windows game client host and is **not present** on this Linux Unraid server.
2. **No Main Menu Table / Dispatch RVAs in Existing `crystaljobs.dll` Signatures**:
   - All 43 signature entries in `native/crystaljobs/layout.h` cover Equipment status (`menu    persona `), Search, Magic (`menu    magic   `), Ability/WS (`menu    ability `), spell cast lookup (`0x22CDE0`), and Equipment Sub-weapon Dual Wield (`0x133D56`).
   - None cover FFXI's top-level Main Menu (`menu    mnu1` / `menu    mnu2`) entry construction table, row count/bounds, label resource lookup, or confirm-selection dispatch jump table.
3. **Zero-Guessing Policy**:
   - Per SoulspireXI native engineering standards, RVAs, 24-byte machine-code signatures, and register/stack ABIs for `FFXiMain.dll` must **never** be guessed, and `plugins/ashita4/crystaljobs.dll` must be built and selftested on Windows MSVC x86 via CI.

### Phase 1A Implementation Decision: Clearly Identified Native-Styled Fallback

Because genuine `FFXiMain.dll` main-menu insertion is blocked without Windows-side disassembly of the actual binary, Phase 1A implements a **clearly identified native-styled fallback** (`addons/ashita4/soulspire_core/`):

- **Reuses Verified Read-Only `MenuManager` Inspection**: Uses the exact memory layout already proven in `crystalsocket/menu.lua` (`AshitaCore:GetPointerManager():Get('menu')` -> `storage - 0x54`) to detect when FFXI's top-level Main Menu (`menu    mnu1`, `menu    mnu2`, `menu    mainmenu`, `menu    submain`) is open and active, read its screen bounds `(left, top, right, bottom)`, and dock a native-styled **Soulspire** entry directly beneath it via Ashita's `scaling` module.
- **Explicitly Labeled as Fallback**: Both the UI header (`Native-Styled Main Menu Fallback`) and `/soulspire status` (`mode=native-styled-fallback`) transparently identify the integration mode.
- **Full Keyboard, Controller, and Mouse Support**:
  - Keyboard (`key_data` + writable `key_state` buffer consumption) and Controller (`xinput_button` + `dinput_button` + DirectInput POV hat) with per-input ownership tracking so consumed presses never leak into FFXI's native menus.
  - Focus handoff (`Tab` or `L1/R1` / `LB/RB` while the FFXI Main Menu is open, or clicking the docked **Soulspire** entry) opens the minimal SoulspireXI Core Hub with all 7 modular sections (`Soul Crystals`, `Weapon Skill Talents`, `Soul Mastery`, `Combat Records`, `Expeditions`, `Player Guides`, `Settings`).
  - Direct toggle fallback via `/soulspire` (alias `/ss`).
- **Built-in Live Diagnostics for Future Native Upgrade**: `/soulspire debug` dumps the live `MenuManager` window list (form names, coordinates, cursor index) on the Windows client to accelerate future native `FFXiMain.dll` investigation if genuine binary insertion is pursued in a later phase.

---

## 3. Compatibility & Safety Verification

- **Equipment Menu (`menu    equip`) & Hook #24**: `MenuBridge:main_menu_context()` strictly matches only top-level main menu forms (`menu    mnu1`, `menu    mnu2`, `menu    mainmenu`, `menu    submain`). When `menu    equip` is open, `soulspire_core` renders nothing and passes 100% of inputs through to `crystalsocket` and native FFXI.
- **`crystaljobs.dll`**: Completely untouched (all 24 hooks and 21 PE exports preserved).
- **Gameplay / Balance / Server Rules**: Zero server files modified; no packets sent or intercepted except read-only zone-change (`0x00A` / `0x00B`) focus cleanup.

---

## 4. Future Windows-Side Path to Genuine Native Insertion (Optional Phase 1B)

If genuine binary insertion into `FFXiMain.dll`'s Main Menu is desired later:
1. Run `/soulspire debug` on the Windows client while Main Menu Page 1 & Page 2 are open to confirm exact form names and window structs.
2. Disassemble the unpacked supported `FFXiMain.dll` (`TS=0x6ae818b4`, `SizeOfImage=0xC17000`) around the `menu    mnu1` form constructor, row-label table, and `OnConfirm` dispatch switch.
3. Add verified 24-byte signatures to `native/crystaljobs/layout.h` and expose a read/trigger callback in `crystaljobs.dll` that `soulspire_core` can detect and switch to automatically (`mode=native-hook`), keeping the Phase 1A Core Hub, registry, and focus state machine unchanged.
