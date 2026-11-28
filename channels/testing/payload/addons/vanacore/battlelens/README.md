# BattleLens

Optional client-side battle log formatting for SoulspireXI on VanaCore. It is not loaded by the launcher or boot script and starts **off** even when manually loaded. It changes only recognized mode-9 melee, miss, and evade display lines. Unknown, injected, system, Echo, Soul action, critical hit, skillchain, magic burst, status, and game-control-code lines pass through unchanged. No packets, server settings, or global VanaCore settings are changed.

## Use

1. In the launcher, choose **Modern Native** and check **Load optional BattleLens**. Save settings and launch the game. The launcher installs the addon files into the native profile and adds its load command to that profile's boot script. The checkbox is off by default.
2. In game, enter `/battlelens on` to opt in to formatting. `/battlelens off` restores vanilla display immediately; uncheck the launcher option to stop loading it next time. `/addon unload battlelens` removes it for the current session.

For a manual install, copy this folder to `addons/vanacore/battlelens/` in the chosen VanaCore profile and enter `/addon load battlelens vanacore` in game.

Settings are per character in VanaCore's `settings/addons/battlelens/<Character>/settings.json`. The initial `enabled` value is `false`; a player who opts in retains that choice until switching it off.

| Command | Effect |
| --- | --- |
| `/battlelens status` | Show current state |
| `/battlelens condense on|off` | Shorten recognized lines |
| `/battlelens show melee|miss|evade on|off` | Show or hide one recognized category |
| `/battlelens color melee|miss|evade 1-255|default` | Use a game chat color mode, or its original color |

`/blens` is a short alias. Filtering applies only while enabled. Unrecognized lines always retain vanilla text and color. The game client must be used to confirm visual colors and interaction with other chat addons before release.
