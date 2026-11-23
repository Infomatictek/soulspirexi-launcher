# SoulspireXI — Dynamic DAT Virtualization Architecture & Feasibility Audit

> **Status**: Phase E Investigation + Phase F Text-Resource Proof of Concept (`feat/dat-virtualization-poc`, branched cleanly from canonical `main` `e88f542` / `aff1c9a`).
> **Target Binary**: `FFXiMain.dll` (`TimeDateStamp = 0x6AE818B4`, `SizeOfImage = 0x00C17000`, Win32 x86)

---

## 1. How the Native FFXI Client Loads, Parses, Caches, and Consumes DAT Resources

Analysis of retail `FFXiMain.dll` and existing SoulspireXI client assets (`dat-overlay/ROM/` [8 managed DATs] and `dat-overlays/flintlock-akimbo-compact/ROM/` [278 optional 3D model DATs]) reveals four distinct resource pipelines inside FFXI:

1. **Logical File Table (`VTABLE.DAT` / `FTABLE.DAT`) → Disk I/O**:
   - The client resolves logical DAT indices through `VTABLE`/`FTABLE` into physical `ROM/<dir>/<file>.DAT` paths and opens them via Win32 `CreateFileA` / `ReadFile`.
   - External tools such as XIPivot intercept this file-path boundary to redirect opens to a shadow overlay directory without modifying original `ROM/` files.
2. **Encrypted / Bit-Rotated Fixed-Width Tables (Parsed into Memory at Startup / Menu Open)**:
   - **Spell & Ability Metadata (`ROM/118/114.DAT`)**: 100-byte bit-rotated records loaded into static/heap arrays at boot (e.g., `spell->job_levels[24]`, MP cost, cast time, recast, element, valid targets). Read by `CanShowSpell` (`0x22CDE0`), `MenuSpellElig` (`0x1021A0`), and `/ma` resolver (`0x22CA40`).
   - **Action Name & Help Text Tables (`ROM/181/72.DAT`, `73.DAT`, `74.DAT`, `75.DAT`)**: DMSG string tables read on demand when rendering `menu    magic   `, `menu    ability `, target banners (`0x10579638`), and `helpwind`.
   - **Job Names & Abbreviations (`ROM/118/105.DAT` / `menu2fon` `ROM/118/111.DAT`)**: Loaded into UI string tables and D3D8 `menu2fon` sprite sheets.
   - **Item Resource & Text Tables (`ROM/118/108.DAT` et al.)**: Streamed/indexed via `GetItemResource` (`0x15D210`) into cached `CItemResource` structs (slot bitmask, skill ID, job bitmask, level, item name/description).
   - **Status Names & Icons (`ROM/180/102.DAT`, `ROM/119/57.DAT`)**: Loaded into status icon/tooltip caches at zone/login.
3. **GPU / Direct3D8 Streamed Binary Assets (Models, Skeletons, Textures, Animations)**:
   - **Weapon/Equipment Models & Skeletons** (e.g., `ROM/100/74.DAT`–`ROM/140/*.DAT`): Streamed asynchronously when an entity enters range or equips gear, parsed into D3D8 vertex/index buffers, bone matrices, and texture surfaces, and evicted only on entity despawn or zone transition.
   - **Animation & VFX Tables**: Referenced by numeric ID from `0x028` action packets and shared globally across all actors in the zone.

---

## 2. Comparison of the Three Virtualization Approaches

| Dimension | Approach 1: In-Memory Parsed Resource Overrides (Soulspire Native Hooks) | Approach 2: Resource-Loading Interception / Virtual DAT I/O | Approach 3: Deterministic Generated DAT Overlays (Launcher-Distributed) |
|---|---|---|---|
| **Mechanism** | Hook verified client getters/renderers (`FFXiMain.dll`) and serve Soul-scoped values from immutable registry-compiled JSON snapshots in memory. | Intercept `CreateFileA`/`ReadFile` (or DAT loader) to serve synthesized/virtual DAT byte streams on the fly. | Registry Compiler deterministically builds minimal binary DAT files; SoulspireLauncher distributes & activates them in an isolated overlay directory (never overwriting vanilla `ROM/`). |
| **Per-Soul Isolation (Same ID → Different Meaning)** | **Native & Immediate** — identical spell ID `28` displays as *Dawnfire* for WHM Zealot, *Vigil Lance* for WHM Valkyrie, and vanilla *Banish* when unsocketed. | **Impossible for shared IDs** — FFXI caches loaded DATs globally; one physical DAT cannot represent two Souls simultaneously without forced cache eviction. | **Global only** — best suited for unique IDs, new custom status icons, or Soul-gated optional packs (e.g. Flintlock compact dual pistols). |
| **Hot Reload / Soul Switch** | **Instant, zero restart** — atomic pointer swap + generation bump. | **Fragile** — requires evicting FFXI's internal parsed caches and D3D8 VRAM textures, risking use-after-free crashes. | **Requires client restart or overlay reload** before FFXI opens the DAT. |
| **Memory & Binary Safety** | **Highest** when anchored on signature-verified hooks (`TS=0x6AE818B4`) with fail-closed build validation. | **Medium–High risk** — file-I/O hooks interact with Ashita, XIPivot, anti-virus, and multi-threaded streaming loaders. | **Highest runtime stability** — zero extra native hooks; pristine vanilla files preserved; checksum-verified rollback via Launcher. |
| **Maintenance Cost** | Low for text/eligibility already covered by 27 hooks; moderate if adding new binary hook sites. | High — must synthesize bit-rotated/DMSG/D3D8 binary container formats live in C++ inside a 32-bit process with tight virtual address space. | Low when driven by Python compilers in CI (`tools/registry_compiler.py`) + existing Launcher overlay pipeline. |

**Architectural Decision**: Do **not** force a single mechanism onto every DAT category. Use a **hybrid tiered architecture**:
- **Tier 1 (Primary)**: In-memory parsed overrides in Soulspire Native for all Soul-scoped text, names, descriptions, and eligibility gates (zero DAT editing, instant Soul switching, zero client restart).
- **Tier 2 (Secondary)**: Deterministic compiler-generated DAT overlays distributed through SoulspireLauncher (never overwriting vanilla `ROM/`) for binary/GPU assets that FFXI streams directly into D3D8 VRAM or parses globally at boot (icons, textures, 3D weapon/equipment models, animations).
- **Avoid**: Live in-process `CreateFileA` virtual DAT synthesis for binary GPU assets where deterministic Launcher overlays already provide safer, checksum-verified distribution and rollback.

---

## 3. Complete 13-Category DAT Virtualization Feasibility Matrix

| # | Resource Category | FFXI Consumption Path | Classification | Recommended Mechanism | Soul-Scoped Safe? | Current Status & Remaining Manual DAT Dependencies |
|---:|---|---|---|---|---|---|
| 1 | **Job names & abbreviations** | `menu2fon` (`ROM/118/111.DAT`), Status/Equipment/Party/Search UI | **Dynamically overridable** | In-memory override (`JobIdentity` + `soul-identities.json`) | Yes (66 Souls) | **Implemented in `main`** (`soulspire_native.dll` Hooks #1–#12). Zero manual DAT edits. |
| 2 | **Soul-specific spell names** | `menu    magic   ` (`0x22E4F5`), target banner (`0x22DED1`) | **Dynamically overridable** | In-memory override (`DatVirtualizationManager` + `dat-text-overrides.json`) | Yes | **Implemented in Phase F POC** (direct from `registry/entities.json`, zero manual DAT edits). |
| 3 | **Job ability names** | `menu    ability ` (`0x226129`), target banner (`0x225916`) | **Dynamically overridable** | In-memory override (`DatVirtualizationManager` + `dat-text-overrides.json`) | Yes | **Implemented in Phase F POC**. Replaces manual edits to `ROM/181/72.DAT` for Soul-scoped JAs (`Call Eos`/`Call Titania` still retained in base overlay for non-native fallback until verified in-game). |
| 4 | **Weapon skill names** | `menu    ability ` (`0x226129`), target banner (`0x225916`) | **Dynamically overridable** | In-memory override (`DatVirtualizationManager` + `dat-text-overrides.json`) | Yes | **Implemented in Phase F POC**. Zero manual DAT edits. |
| 5 | **Descriptions & help text** | `helpwind` (`0x22E245`, `0x225F5D`), ASCII-sanitized formatter | **Dynamically overridable** | In-memory override (`DatVirtualizationManager` + `dat-text-overrides.json`) | Yes | **Implemented in Phase F POC**. Replaces manual edits to `ROM/181/74.DAT` for Soul actions. |
| 6 | **Spell costs & recast information** | `ROM/118/114.DAT` (`SpellResource`), server recast packets (`0x0B9`/`0x063`) | **Overridable with cache invalidation** | Hybrid: authoritative server recast packets + in-memory `helpwind`/overlay cost text; native MP-cost field hook only if verified | Partial (shared IDs) | Recast timers are server-driven; description text dynamically states real Soul %MP/recast. Native `SpellResource.mp_cost` field remains vanilla unless explicitly hooked per-Soul. |
| 7 | **Job & level eligibility** | `ROM/118/114.DAT` (`job_levels[24]`), `CanUseSpell` (`0x22CDE0`), `MenuSpellElig` (`0x22E64D`), missing-bit (`0x22CB44`) | **Dynamically overridable** | In-memory override (`VisibilityCatalog`, Hooks #20, #23, #24) | Yes (level-sync aware) | **Implemented in `main`**. Already eliminated 32 manual `ROM/118/114.DAT` edits; only 3 RUN backport records remain in `114.DAT`. |
| 8 | **Item names & descriptions** | `CItemResource` (`0x15D210`, `ROM/118/108.DAT`), cached per item ID in `FFXiMain` | **Overridable with cache invalidation** | Phase 2 target: in-memory item-text getter hook OR deterministic generated item-text DAT overlay for unique custom items | Global per unique Item ID | **Manual DAT dependency remains** for `Orphic Egg` (`ROM/118/108.DAT`) until item-text hook or deterministic DAT compiler lands. |
| 9 | **Equipment restrictions** | `EquipMenu::TryEquipItem` (`0x133D56`, `0x133DD3`, `0x133E33`), `SubMenuFilter` (`0x21DF85`) | **Dynamically overridable** | In-memory override (`WeaponRuleCatalog`, Hooks #22, #25, #26, #27) | Yes (`DUAL_1H`, `DUAL_2H`, `TWOHAND_SHIELD`) | **Implemented in `main`**. Zero manual item-DAT slot/job bitmask edits required. |
| 10 | **Menu labels** | Static UI form strings (`menu    mnu1`, `menu    equip`) & `helpwind` headers | **Overridable with cache invalidation** | In-memory UI draw hooks (verified per form) or Soulspire Core ImGui panels | Yes | Equipment/Status/Party/Search labels dynamic in `main`; custom Hub menu owned by `soulspire_core`. |
| 11 | **Icons & textures** | D3D8 texture surfaces (`ROM/119/57.DAT`, `ROM/118/111.DAT`) uploaded to VRAM | **Requires generated DAT overlay** | Deterministic generated DAT overlay via Launcher (`tools/gen_status_registry.py` / icon compiler) + runtime icon-ID remapping (`0x22E51B`, `0x22614E`) for existing atlas icons | Icon ID remap = dynamic; new pixel art = global overlay | **Manual/generated DAT dependency remains** for custom status icons (`ROM/119/57.DAT`, `ROM/180/102.DAT`). |
| 12 | **Weapon & equipment models** | Streamed D3D8 mesh/skeleton DATs (`ROM/100..140/*.DAT`) | **Requires generated DAT overlay** | Deterministic generated optional DAT overlays distributed & toggled via SoulspireLauncher (`dat-overlays/`, never touching vanilla `ROM/`) | Per-client optional pack (Soul-gated in Launcher) | **Generated overlay dependency remains** (278 Flintlock compact akimbo DATs in `dat-overlays/flintlock-akimbo-compact/`). |
| 13 | **Animation references** | `0x028` action packets + global skeleton/VFX DAT tables | **Unsupported or unsafe** (for live per-caster runtime virtualization) | Server-selected existing animation IDs or deterministic Launcher DAT overlays; **do not** mutate shared VFX tables live | Unsafe to virtualize live across multiple casters | Explicitly deferred until dedicated two-client packet/VFX research proves zero desync. |

---

## 4. Target Registry-Driven Pipeline (Phase F)

```text
Centralized Game Registry (soulspirexi/registry/souls.json + entities.json)
        |
        v
Registry Compiler (soulspirexi/tools/registry_compiler.py)
  |-- Emits plugins/ashita4/data/soul-identities.json     (66 Souls, FNV-1a verified)
  |-- Emits plugins/ashita4/data/dat-text-overrides.json  (160+ Soul action names/descriptions, FNV-1a verified)
  |-- Emits addons/ashita4/soulspire_soul_actions/data/soul_actions.tsv (Ashita Lua parity)
  |-- Future: Deterministic status/item DAT overlay generator (never edits vanilla ROM/)
        |
        v
SoulspireLauncher Distribution (manifest.json SHA-256 verification + atomic staging + rollback)
        |
        v
Soulspire Native Resource Manager (soulspire_native/resources/resource_manager.h)
  |-- Reads soulspire_native.json, soul-identities.json, dat-text-overrides.json
  |-- Validates schemaVersion + integrityFnv1a64 (fail-closed to vanilla on error)
  |-- Publishes immutable snapshots via atomic release/acquire pointers
  |-- Supports hot reload via SoulspireNativeReloadConfig() without client restart
        |
        v
DatVirtualizationManager (soulspire_native/dat_virtualization/dat_virtualization.h)
  |-- Keyed strictly by active confirmed (job, branch, kind, action_id)
  |-- Instant cache invalidation on Soul switch (zero stale Soul identities)
  |-- Precedence: Explicit runtime Lua catalog > Registry DatVirtualizationManager > Pristine Vanilla DAT
        |
        v
Native FFXI Client (Magic/Ninjutsu, Job Ability, Weapon Skill menus, target banner, helpwind)
```

### Non-Negotiable Safety Guarantees
1. **Zero In-Place Vanilla Mutation**: Original FFXI `ROM/` DATs are never opened for write or altered in place.
2. **Pristine Vanilla Fallback**: When no Soul is socketed, when `modules.datVirtualization` is disabled in `soulspire_native.json`, or when `dat-text-overrides.json` is missing/corrupt, lookups return `nullptr` and FFXI renders its original vanilla DAT string.
3. **Server Authority Preserved**: Client virtualization only alters presentation (names, descriptions, icons) and local menu eligibility matching server-authoritative rules; real gameplay execution always dispatches canonical vanilla action IDs and is enforced by the server.
4. **No Manual Player Commands**: `SoulspireNativeInitialize()` automatically loads `plugins/ashita4/data/dat-text-overrides.json` on startup, so players never need to run slash commands or manually reload addons after a Launcher update.

---

## 5. Recommended Implementation Order

1. **Phase F.1 (Complete in this POC)**: Registry-compiled `dat-text-overrides.json` -> `DatVirtualizationManager` for Soul-scoped Spell, Job Ability, and Weapon Skill names/descriptions (zero manual DAT edits).
2. **Phase F.2 (Next)**: Migrate `visibility.tsv` into `registry/entities.json` -> `plugins/ashita4/data/dat-visibility-rules.json` loaded directly by `ResourceManager` so Soul spell/ability unlock rules require zero Lua TSV push or `114.DAT` edits (and retire the remaining 3 RUN `114.DAT` edits if desired).
3. **Phase F.3**: Deterministic Python DAT compiler in `tools/` for `ROM/180/102.DAT` (custom status text), `ROM/119/57.DAT` (custom status icons), and `ROM/118/108.DAT` (custom item text like Orphic Egg), run in CI and distributed via SoulspireLauncher's isolated overlay pipeline — eliminating the last manual DAT edits in `dat-overlay/ROM/`.
4. **Phase F.4**: Investigate read-only in-memory item-description hook (`CItemResource`) if Soul-scoped item descriptions (same item ID differing by active Soul) are ever needed.
