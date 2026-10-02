# Building the core

## Requirements

* Intel Quartus Prime Lite **17.0** (17.0.2 recommended, as for other MiSTer
  cores) with Cyclone V device support.
* About 25 minutes and 8 GB of RAM per full compile.

## Build

Open `Namco_NB1.qpf` in Quartus and run **Processing > Start Compilation**,
or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1
```

Pass `-QuartusRoot <path>` if Quartus is not installed in
`C:\intelFPGA_lite\17.0\quartus`.

Outputs:

* `output_files/Namco_NB1.rbf`, the bitstream.
* `Releases/Namco_NB1_YYYYMMDD.rbf`, a dated copy made by the post-flow
  script `scripts/release_rbf.tcl` after every full compile.

Check the timing report (`output_files/Namco_NB1.sta.summary`): all clock
domains should have non-negative setup and hold slack. The released build uses
fitter seed 5 (`Namco_NB1.qsf`). Seeds 1, 2 and 3 also close timing.

## MRA

The MRAs are generated, not hand-written (shown for `nebulray`; the clones
use `nebulrayj.json` / `nebulrayp.json` the same way, with their MRAs in
`MRA/_alternatives/_Nebulas Ray/`):

```powershell
python scripts/mra/nb1_mra.py generate --game scripts/mra/games/nebulray.json -o "MRA/Nebulas Ray (World, NR2).mra"
python scripts/mra/nb1_mra.py validate --mra "MRA/Nebulas Ray (World, NR2).mra" --game scripts/mra/games/nebulray.json
```

`validate` rebuilds the ROM stream the way MiSTer's MRA loader does and checks
it against MAME's region layout. With `--zip <nebulray.zip>` it also checks
every CRC against your own ROM set (nothing derived from the ROMs is written).
For a clone, list the clone's zip first and then the parent's:
`--zip "nebulrayj.zip|nebulray.zip"`. The prototype has different reset
vectors; add `--any-vectors` for it.
See [MRA_FORMAT.md](MRA_FORMAT.md).

## Benches

`sim/` holds two self-contained ModelSim benches that back the timing
constraints: `m22_hq2x_ce_tb.sv` (the HQ2x clock-enable cadence behind the
multicycle in `NB1.sdc`) and `m22_c75_alu_tb.sv` (the exhaustive equivalence
check for the timing changes in the M37702 core, `rtl/vendor/README.md`).
The MAME-comparison benches used during development need locally captured
MAME data and are not part of this repository.

## Install on MiSTer

1. Copy `Releases/Namco_NB1_YYYYMMDD.rbf` to `_Arcade/cores/`.
2. Copy the `MRA/*.mra` files to `_Arcade/`, and the `MRA/_alternatives/_Nebulas Ray`
   folder to `_Arcade/_alternatives/`.
3. Put `nebulray.zip` (and `nebulrayj.zip` / `nebulrayp.zip`) in `games/mame/`,
   plus `namcoc75.zip` if you use a split or merged set.

See [COMPATIBILITY.md](COMPATIBILITY.md) for ROM set notes.
