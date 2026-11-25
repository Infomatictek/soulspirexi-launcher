# SoulspireXI Core — Native Main Menu Integration & Verified Blocker Record

## Integration Mode

SoulspireXI Core (`addons/ashita4/soulspire_core/`) uses an **isolated, reversible native-styled fallback** integrated cleanly with FFXI's existing Main Menu:

1. **Read-Only Native Hook Probe**: On load, `core/menu_bridge.lua` probes `crystaljobs.dll` (via safe `pcall` FFI) for an optional verified native main-menu export (`CrystalJobsGetMainMenuBridge`).
2. **Graceful Fallback**: When unsupported (the current verified 24-hook `crystaljobs.dll` baseline), Core automatically activates `mode=native-styled-fallback`:
   - Reuses the verified read-only `MenuManager` layout (`AshitaCore:GetPointerManager():Get('menu')` -> `storage - 0x54`, identical to `crystalsocket/menu.lua`).
   - Strictly matches only top-level Main Menu forms (`menu    mnu1`, `menu    mnu2`, `menu    mainmenu`, `menu    submain`), guaranteeing zero interference with `menu    equip` (`crystalsocket`) or any of the 24 existing `crystaljobs.dll` hooks.
   - Docks a native-styled **Soulspire** entry to the Main Menu supporting `LB/RB` / `Tab` focus handoff, `A` / `Enter` / Click to open, and `B` / `Esc` to return cleanly to FFXI.
   - If `MenuManager` is unavailable on an unsupported client, degrades gracefully to `mode=standalone` (`/soulspire` / `/ss`).
3. **Strict Gamepad & Keyboard Isolation**: While Core is open, `xinput_button`, `xinput_state`, `dinput_button`, `dinput_state`, `key_data`, and `key_state` consume all controller/menu/movement inputs so nothing reaches the underlying FFXI world, restoring normal controls immediately when Core closes, zones (`0x00A`/`0x00B`), logs out (`0x00D`), or disconnects.

## Documented Blocker for Genuine Binary Main-Menu Row Insertion (`FFXiMain.dll`)

- **Retail `FFXiMain.dll` Binary Unavailable on Linux Host**: Direct binary insertion of a new row into `menu    mnu1` requires Windows-side disassembly of the unpacked retail 32-bit `FFXiMain.dll` (`TS=0x6ae818b4`, `SizeOfImage=0xC17000`) to obtain verified RVAs, 24-byte signatures, row-count bounds, and `OnConfirm` dispatch hooks.
- **No Guessing / Zero Memory Risk**: Existing 24 hooks in `crystaljobs.dll` are preserved completely untouched.
- **Client Validation Pending**: Live Windows Ashita v4 gameplay testing (Main Menu dock alignment, XInput/DirectInput controller feel, zoning/logout transitions, and Soulforge/CrystalSocket live server sync) must be executed on a Windows FFXI client.
