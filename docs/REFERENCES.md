# Credits and third-party components

## Included code

| Component | Path | Origin | License |
| --- | --- | --- | --- |
| TG68K.C 68020 core | `rtl/vendor/tg68k/` | [TobiFlex/TG68K.C](https://github.com/TobiFlex/TG68K.C) by Tobias Gubener and contributors, commit `ade33e3`, unmodified (see `rtl/vendor/tg68k/README.md`) | LGPL-3.0-or-later |
| M37702 CPU core and M37702M2 peripherals (C75) | `rtl/vendor/m37702/` | The author's [Namco_NA1_NA2_MiSTer](https://github.com/kyledlester/Namco_NA1_NA2_MiSTer) core, with two documented local modifications (see `rtl/vendor/README.md`) | GPL-3.0-or-later |
| SDRAM controller | `rtl/vendor/sdram.sv` | [MiSTer-devel/GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer), with byte enables (via the NA-1/NA-2 core) and a refresh-interval parameter (see `rtl/vendor/README.md`) | GPL-3.0-or-later |
| CRT Adjust | `rtl/vendor/crt_adjust.sv` | MiSTer-CRT-Adjust by Umberto Parisi (rmonic79) with Andrea Bogazzi, unmodified | GPL-3.0-or-later |
| MiSTer framework | `sys/` | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | see `LICENSE.MiSTer` and file headers |

## Behavioural references

The core's NB-1 logic was written for this project. Its behaviour follows
these MAME 0.289 sources (BSD-3-Clause):

* [`src/mame/namco/namconb1.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/namco/namconb1.cpp): board, memory map, interrupts, KEYCUS and ROM definitions
* `src/mame/namco/namco_c123tmap.cpp`, `src/mame/shared/namco_c355spr.cpp`, `src/mame/namco/namco_c116.cpp`: tilemaps, sprites, palette
* `src/devices/cpu/m37710/` and `src/mame/namco/namcomcu.cpp`: the C75 (M37702) instruction set, timing and peripherals
* `src/devices/sound/c352.cpp`: C352 PCM

Other references: Jotego's `jt053246_scan.sv` (a continuous zoom accumulator for
Konami's sprite chip) for the idea behind the continuous sprite zoom, and the
author's NA-1/NA-2 core for the C75 core, the SDRAM controller and the sound-chip
sequencer structure.

## Game data

No ROMs, MCU BIOS images or other game data are included. The MRA lists MAME
part names and CRCs only.
