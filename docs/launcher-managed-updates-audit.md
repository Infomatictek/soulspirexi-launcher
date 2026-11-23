# SoulspireXI — Launcher-Managed Client Update Audit & Native Search Label Investigation

## 1. Existing Launcher Updater Audit (`ManifestUpdateService.cs`)

| Capability | Existing Status | Enhancement Added in This Branch |
|---|---|---|
| Manifest download & commit-SHA pinning | Working (`FetchManifestAsync` -> `TryResolveBranchCommitShaAsync`) | Added `ManifestRegistryMetadata` (`manifest["registry"]`) & `InstalledClientState.RegistryHash` |
| SHA-256 & size validation | Working (`VerifyStagedFile` with cache-busting retry before any live write) | Enforced `registry.nativeDllSha256` == `crystaljobs.dll` SHA-256 so mismatched DLL/Lua bundles cannot install |
| Path traversal & player settings protection | Working (`ResolveTargetFilePath`, `IsProtectedPlayerConfigPath`) | Preserved untouched |
| Atomic staging & rollback | Working (`stageRoot` + `rollbackRoot` + `RollbackAppliedFiles`) | Added pre-flight `EnsureTargetFilesWritable()` before download so locked DLLs fail fast without wasting downloads |
| Stable vs Testing channel isolation | Working (`manifest.json` vs `channels/testing/manifest.json`) | Enforced `nativeDllClientVerified == true` gate for any new registry DLL on Stable (`--strict-stable-dll` + `ValidateRegistryBundle`); Testing remains open for validation |
| 24-hook Registry DLL vs 27-hook Testing DLL | Separate channel tracks | Explicitly tagged `crystalJobsHooks: 24` in Stable registry metadata; never conflated with Testing-channel 27-hook experiments |

## 2. Native Search Label Corruption Investigation (`native/crystaljobs/crystaljobs.cpp`)

Code audit of `draw_branch` / `draw_menu2fon_label` (`native/crystaljobs/crystaljobs.cpp:151-242`) identified three concrete risk areas that **must be verified/resolved on a live Windows FFXI client** before approving a rebuilt `crystaljobs.dll` for Stable:

1. **In-Place Mutation of Shared `WAR` Sprite Tile (`crystaljobs.cpp:186-227`)**:
   - `draw_menu2fon_label` mutates `(*sheet)[1]` (the shared WAR sprite tile's `corners` at `+0xC0` and UVs at `+0x64..+0xB8`) three consecutive times inside a loop (`i = 0..2`) calling `draw_sprite(sprite, ...)`, then restores the saved bytes.
   - If FFXI's D3D8 sprite queue defers vertex reads or shares vertex buffers across consecutive `draw_sprite` calls within the same frame/list row, mutating the tile in-place can cause subsequent glyphs or adjacent Search rows to render corrupted UVs or overlapped letters.
2. **Non-Vanilla Letter UV Coordinates (`menu_glyphs[26]`, lines `153-180`)**:
   - Letters extracted from stock 3-letter job icons (`WAR..RUN`) sit on rows `v=184, 194, 214`, whereas non-vanilla letters (`J={94,161,8}`, `Q={169,161,8}`, `V={221,161,8}`, `X={244,161,8}`, `Y={3,173,8}`, `Z={13,173,8}`) use different rows on `ROM/118/111.DAT` (`menu2fon`). Any slight pixel offset on `menu2fon` causes clipped or garbled glyphs on abbreviations containing `V`, `Y`, `Z` (e.g., `CWV`, `VLK`, `WYV`, `VNG`, `VMP`, `VRD`, `BRZ`, `ZEL`, `AZB`).
3. **Digit Fallback Mismatch (`crystaljobs.cpp:192-194, 237-239`)**:
   - `draw_menu2fon_label` rejects non-`A..Z` characters and falls back to `native_text(...)` at `0.75f` scale, which has different kerning/baseline than `menu2fon`. (All 66 current canonical abbreviations are pure `A..Z`.)

**Release Safety Action**: Because this Linux host has no Windows FFXI client or `ROM/118/111.DAT` to visually inspect Search rows in-game, `native/crystaljobs/dll_sync_state.json` remains `clientVerified: false` and Stable publication remains **blocked** (`NATIVE_DLL_REBUILD_REQUIRED`) until the Search label rendering is visually verified/fixed on Windows.
