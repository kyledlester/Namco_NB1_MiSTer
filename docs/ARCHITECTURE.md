# Architecture

The core is written for the NB-1 **platform**: all game-specific facts come in
through the MRA ([MRA_FORMAT.md](MRA_FORMAT.md)). MAME 0.289's `namconb1` driver
is the behavioural reference; the source comments tag facts as MAME-confirmed,
MAME-source, measured or inferred, and name the development notes they came
from (those notes are not part of this repository).

## Clocks

Everything runs on one system clock, `clk_sys` = **96.768 MHz** = 2 x the
board's 48.384 MHz crystal, with clock enables (`nb1_clock_enables.sv`):

| Enable | Rate | Used by |
| --- | --- | --- |
| `ce_cpu` | 24.192 MHz (/4) | 68EC020 pacing |
| `ce_c75` | 16.128 MHz (/6) | C75 MCU |
| `ce_pix` | 6.048 MHz (/16) | video raster, 384 x 264, 288 x 224 visible, 59.659 Hz |
| `ce_c352` | 24.192 MHz (/4) | C352 (84 kHz output samples, `clk_sys`/1152) |

## Block overview

```
 MRA/ioctl --> rom_loader --> nb1_memory (SDRAM, fixed-priority clients) <-- c123_render (tiles)
                  |                ^   ^   ^                               <-- c355_render (sprites)
          board_config / check     |   |   +-- mem_mux2 <-- C75 data + C352 voice ROM
                                   |   +------ prog_cache (68EC020 program, 512 x 8 B)
 68EC020 (TG68K.C) -- nb1_cpu -- nb1_main_bus -- work/shared RAM, C116, C123, C355 RAM, EEPROM, KEYCUS, IRQ
                                                        | shared RAM (dual port)
                                              C75 (M37702 + BIOS) -- ports/inputs, A-D, timers -- C352
 video_timing -> c123_render + c355_render -> video_out (priority mix, C116 palette/clip) -> native_flip
             -> crt_adjust -> MiSTer arcade_video / screen_rotate
```

## Main CPU

* `rtl/vendor/tg68k/` is TG68K.C in 68020 mode, unmodified. `nb1_cpu.sv` wraps
  it: it captures each bus cycle and paces the CPU to the real 68EC020's clock
  with a credit scheduler, so game speed matches the board while the TG68K
  kernel runs at `clk_sys`.
* `nb1_main_bus.sv` decodes the address map (`nb1_cpu_map_pkg.sv`). The class
  of the next access is decoded one clock early from the kernel's address, and
  device reads complete from a register, which is how the core closes timing at
  96.768 MHz.
* Program fetches go through a two-line buffer and a 512-line program cache
  (`nb1_prog_cache.sv`). This keeps the SDRAM free for the video chips.
* `nb1_main_irq.sv`: VBL and the C116 raster (POS) interrupt, autovectored as
  on the board. `nb1_cpu_raster.sv` gives the CPU the raster timing it expects
  (two lines ahead of the video output, as MAME measures).
* `nb1_keycus.sv`: the C3xx KEYCUS protection chip, configured by the board
  record.

## C75 MCU and sound

* `rtl/vendor/m37702/`: the M37702 CPU core and on-chip peripherals from the
  author's Namco NA-1/NA-2 core, with two documented local modifications
  (`rtl/vendor/README.md`). `nb1_c75.sv` adds the NB-1 glue: the C75 BIOS, the
  shared RAM window, the data ROM, the input ports and the C352.
* `nb1_c75_irq.sv`: the C75's 60 Hz INT0/INT2, as in MAME.
* `nb1_inputs.sv`: the MiSTer joysticks and OSD switches to the C75 port bytes.
* `nb1_c352.sv`: the C352 (32 voices, 8-bit linear / mu-law, loops, phase
  inversion), following MAME's `c352.cpp`. Voice-ROM reads share the C75's
  memory port (`nb1_mem_mux2.sv`).

## Video

* `nb1_c123_render.sv`: six C123 tilemap layers (scroll, flip, per-line state),
  line-buffered from SDRAM one line ahead.
* `nb1_c355_render.sv`: C355 sprites (priority, flips, clipping, zoom). The
  zoom walker has two modes: MAME's per-tile zoom and the continuous
  accumulator (OSD **Sprite zoom**). The C355 screen flip that MAME lacks is
  implemented here too.
* `nb1_video_out.sv`: priority mix and the C116 palette, clip window and
  output.
* `nb1_native_flip.sv`: the MiSTer OSD **Flipped** orientation, a 180-degree
  frame flip through DDR3 (one frame of latency). `nb1_crt_adjust.sv` wraps
  CRT Adjust. `nb1_orientation.sv` combines the OSD orientation with the game's
  orientation from the board record, for both the picture and the controls.

## Memory and loading

* `nb1_memory.sv`: the SDRAM front end, with fixed-priority clients (C75,
  program cache, tiles, sprites, ROM checker) on the MiSTer SDRAM controller
  (`rtl/vendor/sdram.sv`).
* `nb1_rom_loader.sv`: the ioctl ROM stream into SDRAM (stream offset = SDRAM
  address). `nb1_rom_check.sv` verifies every region against the MRA's check
  record.
* `nb1_eeprom.sv` + `nb1_nvram.sv`: the 28C16 EEPROM and its save/restore
  through MiSTer NVRAM.

`nb1_m2_overlay.sv`, `nb1_m3_overlay.sv` and `nb1_test_pattern.sv` are
development diagnostics. They are listed in the project but not instantiated
in the release.

## Timing

`NB1.sdc` constrains the design. Every clock domain has positive setup and hold
slack. There are two multicycle exceptions, each with its proof in the SDC
comment: TG68K kernel -> captured bus address / predecode (the capture happens
two clocks after an enable edge), and the framework HQ2x blender (enabled at
most every fourth clock, verified by `sim/m22_hq2x_ce_tb.sv`).
