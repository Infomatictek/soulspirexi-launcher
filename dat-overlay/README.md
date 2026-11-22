LSB-Faerie XIPivot overlay
==========================

This overlay does not replace any live FFXI install files. It contains custom
client text DATs for the SoulspireXI SCH **Call Eos** (Medic) and **Call Titania** (Sage) abilities.

Files:

- ROM/181/72.DAT: ability name table
- ROM/181/74.DAT: ability help text table
- ROM/118/114.DAT: spell/ability metadata table
- ROM/118/108.DAT: weapon/ammo item text table

Changed client-facing entries:

- ID 743 (server ability ID 231) now shows as **Call Eos** (`Calls forth Eos to heal and remove ailments.`), targeting self with matching recast ID `227`.
- ID 801 (server ability ID 289) now shows as **Call Titania** (`Calls forth Titania to enfeeble foes and unleash elemental magic.`), targeting self with matching recast ID `200`.
- Item ID 18256, **Orphic Egg**, now shows `Eos/Titania: "Refresh"+1-5`.

Server mapping:

- LandSandBoat ability ID 231 (`faerie_companion`) summons Eos (gated behind Medic crystal Lv.10+).
- LandSandBoat ability ID 289 (`faerie_titania`) summons Titania (gated behind Sage crystal Lv.10+).
- The real 5 minute cooldowns are enforced by the server ability recasts.
- Tabula Rasa is restored to normal behavior and no longer summons the faerie.
- Modus Veritas is restored to normal behavior and remains ability ID 214.

For your current custom DAT loader, copy the contents of this folder into:

C:\DATs\Soulspire

If you also want to load it with Windower XIPivot, place this folder under:

C:\Windower\Windower\addons\XIPivot\data\DATS\LSB-Faerie

Then add LSB-Faerie to XIPivot's overlay list or run:

//pivot add LSB-Faerie

For the cleanest result, enable the overlay before launching FFXI.
