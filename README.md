# Namco NB-1 for MiSTer

<img width="450" height="580" alt="image" src="https://github.com/user-attachments/assets/d019d91a-2d38-49c6-9d95-d0900960b250" />

A MiSTer FPGA core for Namco's **NB-1** arcade board (1993-1997): **Nebulas Ray**,
**Point Blank / Gun Bullet** (with light-gun support), **Great Sluggers**, **Great Sluggers '94**,
**Super World Stadium '95 / '96 / '97** and **J-League Soccer V-Shoot**. One core (`Namco_NB1`)
is written for the whole board; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the assistance of AI tooling.

**Status: beta.** Nebulas Ray is fully playable on real MiSTer hardware, with
sound, EEPROM saves, CRT output, and more. Point Blank works with a GunCon 2 on a
CRT. The other games are new in this release and have had less testing.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`Namco_NB1_YYYYMMDD.rbf`) to
   **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA files from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**.
   For the alternative sets, copy the `_<Game>` folders from
   [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME 0.289 ROM zips in **`/media/fat/games/mame/`** (the set names are
   in the tables below). With split sets, a clone also needs its parent's zip.
   With a split or merged set, also add the C75 BIOS zip **`namcoc75.zip`**; it
   is a standard MAME device zip and most of these games need it. A non-merged
   set already includes everything.
4. Load the game from the **Arcade** menu.

ROMs are not included. You must supply your own.

## Supported games

| Game | MAME set | Year | Genre | Board | Status |
| --- | --- | --- | --- | --- | --- |
| Nebulas Ray (World, NR2) | `nebulray` | 1994 | Vertical shoot 'em up | NB-1 | Full game playable |
| Point Blank (World, GN2 Rev B, set 1) | `ptblank` | 1994 | Light-gun shooting gallery | NB-1 | Playable; GunCon 2 confirmed on CRT |
| Great Sluggers (Japan) | `gslugrsj` | 1993 | Baseball | NB-1 | New, limited testing |
| Great Sluggers '94 | `gslgr94u` | 1994 | Baseball | NB-1 | New, limited testing |
| Super World Stadium '95 (Japan) | `sws95` | 1995 | Baseball | NB-1 | New, limited testing |
| Super World Stadium '96 (Japan) | `sws96` | 1996 | Baseball | NB-1 | New, limited testing |
| Super World Stadium '97 (Japan) | `sws97` | 1997 | Baseball | NB-1 | New, limited testing |
| J-League Soccer V-Shoot (Japan) | `vshoot` | 1994 | Soccer | NB-1 | New, limited testing |

### Alternatives

These use the same core and the same board settings as the main set, with a
different ROM set.

| Game | MAME set | Year | Parent game | Status |
| --- | --- | --- | --- | --- |
| Nebulas Ray (Japan, NR1) | `nebulrayj` | 1994 | Nebulas Ray | Full game playable |
| Nebulas Ray (prototype) | `nebulrayp` | 1994 | Nebulas Ray | Full game playable |
| Point Blank (World, GN2 Rev B, set 2) | `ptblanka` | 1994 | Point Blank | New, limited testing |
| Gun Bullet (Japan, GN1) | `gunbuletj` | 1994 | Point Blank | New, limited testing |
| Gun Bullet (World, GN3 Rev B) | `gunbuletw` | 1994 | Point Blank | New, limited testing |
| Great Sluggers '94 (Japan) | `gslgr94j` | 1994 | Great Sluggers '94 | New, limited testing |
| Great Sluggers '94 (prototype?) | `gslgr94ua` | 1994 | Great Sluggers '94 | New, limited testing |

All the games except Point Blank / Gun Bullet use a joystick and up to three buttons
per player (up to four players). NB-2 games (The Outfoxies, Mach Breakers) are a
different board and are not supported.

More detail: [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Light gun (Point Blank / Gun Bullet)

The NB-1 light-gun games read two guns through an extra I/O board, which the
core emulates. Aim comes from MiSTer's light-gun support: Main_MiSTer turns a
light gun into an absolute position on a joystick's analog axes, and the core
reads player 1's gun from joystick 1 and player 2's from joystick 2.

**Namco GunCon 2 on a CRT (confirmed working):**

1. Use a 15 kHz CRT and connect the GunCon 2's yellow RCA plug to a composite
   sync signal from your MiSTer's video output (a sync tap or breakout), as for
   other MiSTer light-gun cores. Plug the gun's USB into the MiSTer.
2. In MiSTer's controller setup, map the GunCon's trigger to **Trigger**, and
   its A/B buttons to **Start** and **Coin** if you like.
3. Load Point Blank. MiSTer has default GunCon 2 calibration values, so it may
   already line up. Turn on **Crosshair** in the core's OSD to check.
4. To calibrate: open the OSD and press **F10** on a keyboard. A *Lightgun
   Calibration* screen appears. For each edge it highlights (top, bottom, left,
   right), aim at that edge of the picture and press the gun's **A** button.
   The screen says "trigger", but on a GunCon 2 the trigger closes the menu;
   use **A**. After the fourth edge the menu closes by itself and the
   calibration is saved.

**If the menu stops working after calibrating:** Main_MiSTer has a bug where a
bad calibration (for example an edge confirmed while the gun could not see the
picture, so two opposite edges get the same value) crashes the menu program.
The game keeps running, but the OSD and controllers stop responding, and it
happens again every time the game loads. To fix it, delete that game's
calibration file from the SD card and calibrate again:
`/media/fat/config/<set>_gun_cal_0b9a_016a_v2.cfg`, for example
`ptblank_gun_cal_0b9a_016a_v2.cfg` (MiSTer keeps one per MAME set name, so each
gun game is calibrated separately; `0b9a_016a` is the GunCon 2's USB ID). Calibrate on a bright screen, aim just inside each edge, and check that
the number shown has moved before pressing A.

**Other options (OSD, only shown for the gun games):**

* **Crosshair** (Off / On): a small cross where each gun points (red player 1,
  blue player 2). Off by default for real guns.
* **Gun aim P1** (Joystick / Mouse): aim player 1 with a mouse instead.

Guns that MiSTer presents the same way (Sinden, Gun4IR and similar) and plain
analog sticks also work through the joystick path. Point Blank also has its own
gun adjustment in its service menu (OSD **Service mode**).

## Improvements over MAME

MAME's `namconb1` driver (0.289) is the behavioural reference. During
development the core was compared against MAME in simulation: the C75 MCU
event-for-event, the picture pixel-for-pixel on captured scenes, and the sound
sample-for-sample. The core deliberately goes beyond MAME in two places.

### Continuous sprite zoom (default), with MAME's zoom as a fallback

Nebulas Ray scales its big multi-tile sprites (ships, the battleship, explosions)
constantly. MAME draws a zoomed sprite **one 16-pixel tile at a time**: it gives
each tile a whole-pixel share of the screen, restarts the scaling at the start of
every tile, and stretches each tile a little so that no gaps show. The result is
uneven. Columns are dropped or doubled in clumps at the tile seams (MAME can skip
up to six source columns at one seam where even scaling skips three), so scaled
sprites shimmer and "ripple" along their tile boundaries as they grow and shrink.

The core scales the **whole sprite with one continuous accumulator per axis**, so
source pixels are picked evenly across the sprite and the seams disappear.
Unzoomed sprites are drawn exactly as before.

The OSD option **Sprite zoom** selects the method:

* **Continuous** (default): the smooth single-accumulator zoom.
* **MAME**: MAME's per-tile zoom, bit-exact, as a fallback if you prefer the
  reference behaviour.

The real C355's internal zoom arithmetic is not documented anywhere. The
continuous mode is a quality improvement over MAME, not a claim about the PCB.

### The service-menu FLIP setting works

Nebulas Ray has an operator FLIP option in its test menu (a true 180° screen
rotation for cocktail or upside-down cabinet mounting). **In MAME, turning it on
flips the background but every sprite disappears**, because MAME does not emulate
the sprite chip's screen flip. The core implements it, so the whole picture flips
correctly. It works on every output (HDMI, analog / CRT, Direct Video) and is
lagless: it is part of the native picture, with no frame buffer. The MiSTer OSD
**Flipped** orientation goes through a frame buffer and adds one frame of latency.
Thus if you need to flip your screen, using the game's service menu is recommended.

## About the hardware

NB-1 is Namco's mid-1990s 32-bit board:

* Motorola **68EC020** main CPU at 24.192 MHz.
* Namco **C75** MCU, a Mitsubishi M37702 running Namco's BIOS. It handles the
  controls and drives the **C352** 32-voice PCM sound chip.
* **C123** tilemap generator (six scrolling layers), **C355** zooming sprite
  chip, **C116** palette with clipping and a raster interrupt.
* A per-game **KEYCUS** protection chip (Nebulas Ray: C366). Point Blank adds
  a light-gun I/O board.
* Game settings and high scores kept in an EEPROM.

## About the core

* Runs the genuine C75 MCU BIOS on an M37702 CPU core, so sound and inputs come
  from Namco's own firmware.
* One RBF for the platform. The core has no per-game code; the MRA carries a
  small board record (protection chip, cabinet orientation) and a checksum
  record the core uses to verify every ROM region after loading. See
  [docs/MRA_FORMAT.md](docs/MRA_FORMAT.md).
* Full video: all six tile layers, zoomed sprites, shadows, per-line raster
  effects and the raster interrupt.
* Light-gun I/O board for Point Blank / Gun Bullet (GunCon 2, other MiSTer guns,
  mouse), with an optional crosshair.
* Sound: the C352 at MAME's sample rate, stereo, with an optional stereo mix.
* Native 15 kHz output for CRTs, with optional CRT Adjust (H-size,
  H-position, V-shift) thanks to rmonic79/MiSTer-CRT-Adjust.
* OSD options: aspect ratio, scandoubler effects, orientation (Horizontal,
  Vertical CCW, Vertical CW, Flipped), sprite zoom (Continuous / MAME), gun
  aim and crosshair (gun games), CRT Adjust, Service Mode, stereo mix, program
  cache, Reset.
* EEPROM saved to the SD card as `.nvm`. MiSTer writes it when you open the
  OSD after the game has changed its settings or scores.
* An on-chip program cache for the 68EC020 keeps the shared SDRAM free for the
  video chips. OSD **Program cache: Off** falls back to a simple two-line buffer
  (slower; for comparison only).
* Timing closes at the full 96.768 MHz system clock on every clock domain.

### Known issues

* In the very heaviest scenes (for example the big battleship in the attract
  demo), the sprite chip can occasionally run out of memory time and leave a
  short piece of one sprite line undrawn for a single frame. In the captured
  test scenes this happens on a handful of lines in the heaviest frames only,
  and it is very hard to notice at full speed.
* Palette fades on the bottom two picture lines can differ slightly from MAME.
* In attract mode, at the change from one stage to the cutscene, a sustained
  high-pitched organ chord from the stage music can occasionally get stuck and
  play through the whole cutscene until the next stage starts. It shows up
  only every few attract loops.
* The light-gun calibration crash described above is in Main_MiSTer, not the
  core.

## Releases

Builds are in [`Releases/`](Releases/) as `Namco_NB1_YYYYMMDD.rbf`. The MRA
names the core without the date (`<rbf>Namco_NB1</rbf>`), and MiSTer loads
the newest dated file in `_Arcade/cores/`. You are welcome to run your own build if you'd prefer.

## Building

Quartus Prime Lite 17.0. Open `Namco_NB1.qpf` and compile; the build copies
a dated RBF into `Releases/`. See [docs/BUILDING.md](docs/BUILDING.md).

## Documentation

* [Compatibility](docs/COMPATIBILITY.md)
* [MRA format](docs/MRA_FORMAT.md)
* [Architecture](docs/ARCHITECTURE.md)
* [Building](docs/BUILDING.md)
* [Credits and third-party components](docs/REFERENCES.md)

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). The MiSTer framework in `sys/` keeps
its own notices ([LICENSE.MiSTer](LICENSE.MiSTer)); the TG68K.C 68020 core is
LGPL-3.0-or-later; the SDRAM controller and CRT Adjust are GPL-3.0-or-later.
See [docs/REFERENCES.md](docs/REFERENCES.md).

No ROMs, MCU BIOS images or other game data are included in this repository.
