# Compatibility

## Games

| Game | MAME set | Status |
| --- | --- | --- |
| Nebulas Ray (World, NR2) | `nebulray` | Full game playable on MiSTer hardware: attract mode, gameplay, sound, music, EEPROM saves, service mode, operator FLIP |

## Alternate sets (`MRA/_alternatives/`)

Copy the `_Nebulas Ray` folder to `_Arcade/_alternatives/` on the SD card.

| Game | MAME set | Status |
| --- | --- | --- |
| Nebulas Ray (Japan, NR1) | `nebulrayj` | Full game playable (clone of `nebulray`: different program ROMs) |
| Nebulas Ray (prototype) | `nebulrayp` | Full game playable (clone of `nebulray`: earlier program and sound data, graphics and samples on smaller ROMs) |

Not supported: Point Blank / Gun Bullet (light guns), Great Sluggers, Great
Sluggers '94, Super World Stadium '95 / '96 / '97, J-League Soccer V-Shoot. They
run on the same board, but use features Nebulas Ray does not (light guns, other
KEYCUS protection modes) and have not been tested. The NB-2 games (The Outfoxies,
Mach Breakers) use a different board with a rotate/zoom layer.

## ROM sets

* MAME **0.289** `nebulray.zip`, `nebulrayj.zip`, `nebulrayp.zip`. The MRAs list
  every file by name and CRC32.
* The clone MRAs look in the clone's zip, then the parent `nebulray.zip`, then
  `namcoc75.zip`, so split, merged and non-merged sets all work. A split clone
  set needs `nebulray.zip` next to it.
* The C75 MCU BIOS (`c75.bin`) is part of a non-merged `nebulray.zip`. With a
  split or merged set it comes from **`namcoc75.zip`**; put that zip next to the
  game zip. The MRA looks in both.
* After loading (and after every reset), the core reads every ROM region back
  from SDRAM and checks its CRC against a record in the MRA. This is a
  diagnostic of the load path; it does not stop the game.

## Settings and saves

* The game's EEPROM (settings, high scores, operator options such as FLIP) is
  saved as an `.nvm` file in `/media/fat/nvram/` (2 KiB, the same layout as
  MAME's `nvram/nebulray/eeprom`). MiSTer writes it when you open the OSD after
  the game has changed it.
* A first boot without an `.nvm` starts from a blank (erased) EEPROM, as a new
  board does, and the game sets up its defaults.

## Controls

Joystick plus three buttons, Start, Coin and Service, for up to four MiSTer
controllers. The controls always follow the game's orientation, so the stick
works the same way in every OSD orientation. Service mode is the OSD **Service
mode** switch (the board's SW1-1).
