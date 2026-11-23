# SoulspireXI — Runtime Soul Identity Registry & Configurable Native Label Spacing

## 1. Objective

Decouple the 66-Soul display names and 3-letter abbreviations from the compiled `crystaljobs.dll` binary, and replace hardcoded `pos * 8` glyph positioning in the native `menu2fon` Search renderer with configurable, glyph-width-aware tracking — without adding any new Ashita addon, competing registry, or standalone updater.

## 2. Canonical Data Flow

```text
Infomatictek/soulspirexi/registry/souls.json   (Single Source of Truth)
        │
        ▼  tools/registry_compiler.py --generate --launcher-repo <launcher>
Infomatictek/soulspirexi-launcher/
  ├── plugins/ashita4/data/soul-identities.json           (Generated runtime identity table, schema v1)
  ├── plugins/ashita4/data/crystaljobs-presentation.json  (Versioned spacing config, schema v1)
  ├── native/crystaljobs/labels_generated.h               (Compiled fallback table only)
  └── registry_sync.json                                  (Coordinated registry metadata)
        │
        ▼  scripts/update-launcher-manifest.py / publish-testing-channel.py
SoulspireLauncher (Update/Sync — SHA-256 verified, atomic staging & rollback)
        │
        ▼  Installs to <AshitaPath>\plugins\data\
crystaljobs.dll (24 hooks, verified SoA tile+0xC0 menu2fon fix)
  └── Loads <dll_dir>\data\soul-identities.json + crystaljobs-presentation.json
      once at CrystalJobsInitialize() into an immutable snapshot.
```

## 3. Compatibility Contract Separation

- **Identity Content Hash (`registryHash`):** Deterministic hash of `registry/souls.json` + `registry/entities.json`. Changes whenever any Soul display name or abbreviation changes. Verified against `plugins/ashita4/data/soul-identities.json` and `registry_sync.json`.
- **Protocol / Schema Version (`identitySchemaVersion: 1`, `runtimeIdentityLoader: true`):** Embedded in `crystaljobs.dll` provenance and `dll_sync_state.json`. Changes only when the binary/JSON contract changes. When `runtimeIdentityLoader: true` and `identitySchemaVersion == 1`, presentation-only Soul renames do **not** require a native DLL rebuild.

## 4. Runtime Identity File (`plugins/ashita4/data/soul-identities.json`)

- Installed alongside `crystaljobs.dll` under `<AshitaPath>\plugins\data\soul-identities.json`.
- Resolved strictly via `GetModuleFileNameW(pinned_hmodule)` (never current working directory).
- Validated strictly by `crystaljobs.dll` before activation:
  - File size `<= 64 KiB`
  - `schemaVersion == 1`
  - `soulCount == 66` and exactly 66 entries covering all `(jobId 1..22, branch 1..3)` pairs with zero duplicates
  - Every `abbr` is strictly 3 uppercase ASCII letters (`[A-Z]{3}`), unique across all 66 Souls
  - Every `name` is non-empty printable ASCII (`1..31` bytes)
  - `registryHash` is 16 lowercase hex chars; `integrityFnv1a64` matches the in-process FNV-1a-64 digest of the 66 sorted entries
- On any missing/invalid file, `crystaljobs.dll` logs a clear warning via `OutputDebugStringA`, records the fallback reason in diagnostics, and falls back seamlessly to the compiled `labels_generated.h` table.

## 5. Configurable Native `menu2fon` Spacing (`plugins/ashita4/data/crystaljobs-presentation.json`)

- Schema v1:
  ```json
  {
    "schemaVersion": 1,
    "searchBadge": {
      "trackingPx": -1,
      "offsetXPx": 0,
      "useGlyphWidths": true
    }
  }
  ```
- Layout calculation for a 3-letter abbreviation `c0, c1, c2` with `menu_glyphs` widths `w0, w1, w2`:
  - `x0 = clamp(offsetXPx, -2, 3)`
  - `step(w) = (useGlyphWidths ? w : 8) + clamp(trackingPx, -2, 2)`
  - `x1 = max(x0 + 4, x0 + step(w0))`
  - `x2 = max(x1 + 4, x1 + step(w1))`
  - If `x2 + w2 > 23`, shift the trio left by `(x2 + w2 - 23)` clamped to `x0 >= -2` so it never crowds the level digits at `+23`.
  - Setting `trackingPx: 0, offsetXPx: 0, useGlyphWidths: false` reproduces legacy `pos * 8` spacing without recompiling the DLL.
- **Immutable Sprite Bank Safety:** `Menu2fonBank` indexes immutable `GlyphSlot`s by `(x0 - kMinGlyphX0, letter)` across `x0 ∈ [-2, 21]` (`24 × 26` slots), guaranteeing every `(x0, letter)` quad (`SoA x[4]/y[4]` at `tile+0xC0` and UVs) is written once and never mutated after submission to FFXI.
