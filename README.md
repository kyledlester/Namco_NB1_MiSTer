# Namco NB-1 for MiSTer

A MiSTer FPGA core for Namco's **NB-1** arcade board (1993-1997), starting with
**Nebulas Ray**. One core (`Namco_NB1`) is written for the whole board; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the assistance of AI tooling.

**Status: beta.** Nebulas Ray is fully playable on real MiSTer hardware, with
sound, EEPROM saves, CRT output, and more.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`Namco_NB1_YYYYMMDD.rbf`) to
   **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA file from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**.
3. Put the MAME ROM zip (MAME 0.289 set `nebulray.zip`) in **`/media/fat/games/mame/`**.
   With a split or merged set, also add the C75 BIOS zip **`namcoc75.zip`**
   there. A non-merged set already includes the BIOS.
4. Load the game from the **Arcade** menu.

ROMs are not included. You must supply your own.

## Supported games

| Game | MAME set | Year | Genre | Board | Status |
| --- | --- | --- | --- | --- | --- |
| Nebulas Ray (World, NR2) | `nebulray` | 1994 | Vertical shoot 'em up | NB-1 | Full game playable |

The Japanese (NR1) and prototype Nebulas Ray sets have no MRA yet. The other
NB-1 games (Point Blank / Gun Bullet, Great Sluggers, Great Sluggers '94, Super
World Stadium '95-'97, J-League Soccer V-Shoot) are not supported yet. The
platform RTL has no per-game code, but those games need features Nebulas Ray
does not use (light guns, other protection chip modes) and have not been
tested. NB-2 games (The Outfoxies, Mach Breakers) are a different board.

More detail: [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

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
* A per-game **KEYCUS** protection chip (Nebulas Ray: C366).
* Game settings and high scores kept in an EEPROM.

## About the core

* Runs the genuine C75 MCU BIOS on an M37702 CPU core, so sound and inputs come
  from Namco's own firmware.
* One RBF for the platform. The core has no per-game code; the MRA carries a
  small board record (protection chip, cabinet orientation) and a checksum
  record the core uses to verify every ROM region after loading. See
  [docs/MRA_FORMAT.md](docs/MRA_FORMAT.md).
* Full video: all six tile layers, zoomed sprites, per-line raster effects and
  the raster interrupt.
* Sound: the C352 at MAME's sample rate, stereo, with an optional stereo mix.
* Native 15 kHz output for CRTs, with optional CRT Adjust (H-size,
  H-position, V-shift) thanks to rmonic79/MiSTer-CRT-Adjust.
* OSD options: aspect ratio, scandoubler effects, orientation (Horizontal,
  Vertical CCW, Vertical CW, Flipped), sprite zoom (Continuous / MAME), CRT
  Adjust, Service Mode, stereo mix, program cache, Reset.
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
