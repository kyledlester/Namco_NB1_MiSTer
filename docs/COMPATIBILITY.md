# Compatibility

## Games

| Game | MAME set | Status |
| --- | --- | --- |
| Nebulas Ray (World, NR2) | `nebulray` | Full game playable on MiSTer hardware: attract mode, gameplay, sound, music, EEPROM saves, service mode, operator FLIP |
| Point Blank (World, GN2 Rev B, set 1) | `ptblank` | Playable; light gun confirmed with a GunCon 2 on a CRT (see the README) |
| Great Sluggers (Japan) | `gslugrsj` | New, limited testing |
| Great Sluggers '94 | `gslgr94u` | New, limited testing |
| Super World Stadium '95 (Japan) | `sws95` | New, limited testing |
| Super World Stadium '96 (Japan) | `sws96` | New, limited testing |
| Super World Stadium '97 (Japan) | `sws97` | New, limited testing |
| J-League Soccer V-Shoot (Japan) | `vshoot` | New, limited testing |

The new games were checked against MAME in simulation before release: memory
use, interrupts, protection chip, CPU instruction use, and four captured scenes
per game replayed pixel-exact through the core's video pipeline.

## Alternate sets (`MRA/_alternatives/`)

Copy the `_<Game>` folders to `_Arcade/_alternatives/` on the SD card.

| Game | MAME set | Status |
| --- | --- | --- |
| Nebulas Ray (Japan, NR1) | `nebulrayj` | Full game playable (clone of `nebulray`: different program ROMs) |
| Nebulas Ray (prototype) | `nebulrayp` | Full game playable (clone of `nebulray`: earlier program and sound data, graphics and samples on smaller ROMs) |
| Point Blank (World, GN2 Rev B, set 2) | `ptblanka` | New, limited testing (clone of `ptblank`) |
| Gun Bullet (Japan, GN1) | `gunbuletj` | New, limited testing (clone of `ptblank`) |
| Gun Bullet (World, GN3 Rev B) | `gunbuletw` | New, limited testing (clone of `ptblank`) |
| Great Sluggers '94 (Japan) | `gslgr94j` | New, limited testing (clone of `gslgr94u`, different KEYCUS) |
| Great Sluggers '94 (prototype?) | `gslgr94ua` | New, limited testing (clone of `gslgr94u`, different KEYCUS); MRA file `Great Sluggers '94 (prototype).mra` |

Not supported: the NB-2 games (The Outfoxies, Mach Breakers) use a different
board with a rotate/zoom layer.

## ROM sets

* MAME **0.289** sets (names in the tables above). The MRAs list every file by
  name and CRC32.
* The clone MRAs look in the clone's zip, then the parent's zip, then
  `namcoc75.zip`, so split, merged and non-merged sets all work. A split clone
  set needs its parent's zip next to it.
* The C75 MCU BIOS (`c75.bin`) is part of a non-merged game zip. With a split or
  merged set it comes from **`namcoc75.zip`** (a standard MAME device zip); put
  it next to the game zips. The MRAs look in both.
* Point Blank / Gun Bullet load MAME's default EEPROM (gun calibration and
  settings) from the game zip on first start.
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
