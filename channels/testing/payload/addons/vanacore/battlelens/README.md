# BattleLens

Optional client-side battle log formatting for SoulspireXI on VanaCore. The launcher leaves it **off by default**. Checking its option loads and activates it automatically on the next launch. It changes only recognized mode-9 melee, miss, and evade display lines. Unknown, injected, system, Echo, Soul action, critical hit, skillchain, magic burst, status, and game-control-code lines pass through unchanged. No packets, server settings, or global VanaCore settings are changed.

## Use

1. In the launcher, choose **Modern Native** and check **Enable optional BattleLens battle log**. Save settings and launch the game. BattleLens is active without an in-game command. The checkbox is off by default.
2. Uncheck the option to restore vanilla chat on the next launch. `/battlelens off` restores vanilla display immediately for the current session; `/addon unload battlelens` removes it for that session.

For a manual install, copy this folder to `addons/vanacore/battlelens/` in the chosen VanaCore profile and enter `/addon load battlelens vanacore` in game.

Filter and color settings are per character in VanaCore's `settings/addons/battlelens/<Character>/settings.json`. The launcher applies its checked state when the addon loads, including before character login. A manual load starts off until `/battlelens on` is entered.

| Command | Effect |
| --- | --- |
| `/battlelens status` | Show current state |
| `/battlelens condense on|off` | Shorten recognized lines |
| `/battlelens show melee|miss|evade on|off` | Show or hide one recognized category |
| `/battlelens color melee|miss|evade 1-255|default` | Use a game chat color mode, or its original color |

`/blens` is a short alias. Filtering applies only while enabled. Unrecognized lines always retain vanilla text and color. The game client must be used to confirm visual colors and interaction with other chat addons before release.
