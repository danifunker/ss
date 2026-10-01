# sim/ — whole-machine simulation

The core is almost entirely VHDL. GHDL 6 lowers the whole of `ss_core` to one
Verilog file, and Verilator runs it with a C++ harness that plays the MiSTer
side. This is the method of the SGI Indy core (`tools/gen_r4300_verilog.sh`),
applied to the whole machine rather than to the CPU alone.

| file | what |
|---|---|
| `gen_verilog.sh 5\|20` | GHDL: `files.qip` → `generated/ss_core_ss{5,20}.v` (not committed) |
| `pll_sim.vhd` | stand-in for the framework PLL: every clock is the one reference clock |
| `sim_top.sv` | `ss_core` + `ddram_arb`, with the MiSTer side as plain ports |
| `sim_main.cpp` | the harness: DDR3, ROM download, SD blocks, RTC, ttya, video frame |
| `build.sh 5\|20 [--trace] [--diag]` | regenerate if the RTL changed, verilate, compile → `obj_ss{5,20}/Vsim_top` (`obj_ss{5,20}_trace/` with VCD support) |
| `run-cputest.sh 5\|20` | the CPU suite as the boot PROM, diffed against the **hardware** log `tests/cpu/expected/ss{5,20}-core-hw.log` |
| `vcd.py` | query a trace: `vcd.py F.vcd list REGEX`, `vcd.py F.vcd show REGEX… --from C --to C` |

## Tools

- **GHDL 6.0.0** (mcode), the official release, unpacked into
  `~/.local/opt/ghdl-mcode-6.0.0-ubuntu24.04-x86_64/`. `~/.local/bin/ghdl` is
  a two-line wrapper script: GHDL finds its libraries relative to the path it
  was run from, so a symlink does not work. Ubuntu's `ghdl-mcode` is 4.1, and
  its Verilog output has known lowering bugs (see the Indy script).
- **Verilator 5.028** (`~/.local/bin/verilator`).

## What the generator changes, and why

Quartus compiles the VHDL itself; `gen_verilog.sh` works on a copy so that
GHDL sees what Quartus synthesises:

- `--pragma synthesis_off` regions are removed. The upstream simulation code in
  them uses packages that were never published (`fpu_sim_pack`).
- `VARIABLE x : line;` declarations are dropped. They are used only in those
  regions. Quartus ignores an unused access variable, but GHDL's synthesis
  rejects it.
- Assertions are not synthesised (`--no-formal`; GHDL writes them as `$fatal`).
- `'Z'` literals become `'0'`. They are record fields the RTL leaves undriven,
  plus the unused Direct-SD pins.
- The output is read as Verilog-2005 (`+1364-2005ext+v`), because VHDL names
  such as `int` and `cross` are SystemVerilog keywords.

The generics match `SunSparcStation.sv`, plus `SIMU=1`. That skips the loader's
512 MB DRAM clear, which is one word per cycle and takes hours in simulation.
The simulated DDR starts zeroed instead. It is the only RTL difference from the
hardware build.

## Running

```bash
sim/build.sh 5
sim/obj_ss5/Vsim_top --rom tests/cpu/out/ss5-core/cputest.rom --stop "CPUTEST DONE"
```

`Vsim_top --help` lists the options. The ones used most:

- `--hd0/--hd1/--cd FILE`: disk images, served the way `hps_io` serves them.
- `--stop STR`, `--fail STR`: end the run when the console prints STR.
- `--send 'PAT=>TEXT'`: type TEXT on ttya once PAT has appeared.
- `--video`: put the console on the screen (the default is ttya);
  `--frame F.ppm` saves the last video frame.
- `--trace F.vcd --trace-from N`: a waveform, from a model built with
  `build.sh --trace` (5 min to build). Keep the window short: about 7 kB
  per cycle. GHDL renames most internal signals to `nNNNN`, but every
  entity port and named signal keeps its name, for example
  `ss_core.i_ts_core.nosmp_i_iu.pc`.
- `--ddr-log N`: print the first N DDR commands, as core addresses.

The exit status is 0 for a stop string, 1 for a fail string, 2 for the cycle
limit, and 3 for a usage error.

The loader starts the machine only when a download of at least 128 KB ends, so
the ROM is padded to that size. The harness preloads the image into DDR at
OBRAM (`0x1D00_0000`), in the byte layout the loader produces. It then sends
only the last word through `ioctl`, mounts the images, and runs.
`--full-download` sends the whole image, spaced 32 cycles per word.
`ss_core` holds `ioctl_wait` for one cycle only, not until its DDR write
completes. It relies on `hps_io`'s slow pace, so faster spacing loses words
whenever video reads keep the DDR busy. One
cycle is one `clk_sys` period. The UART bit time comes from the revision's
SYSFREQ (60 MHz on the SS5, 55 MHz on the SS20).

## Sun POST (`--diag`)

`sim/build.sh 20 --diag` builds `sim/obj_ss20_diag/`, whose NVRAM starts
with byte 1 (`diag-switch?`) = 0xFF, so the official PROM runs its POST and
prints from its first instructions:

```bash
sim/obj_ss20_diag/Vsim_top --rom SS20-OBP-2.25.rom --cycles 400M --progress --log sim/out/obp20-diag.log
```

The banner comes after about 2.1 s of machine time (two 1 s keyboard
timeouts), so about 120M cycles. The POST catalogue is
`docs/rom-disassembly/ss20-obp-2.25/post-tests.md`.

## Speed

About 60 kHz for the SS5 on this box (6 cores, one model thread), which is
roughly 1/1000 of real time. The CPU suite takes 14M cycles, about 4
minutes, and prints exactly what the board prints. That is what the model
is for: CPU and chipset debugging on short runs, with waveforms. Booting an
OS is a job for the hardware.

## Differences from the board

- **One clock.** The SS20's 65 MHz video clock runs at `clk_sys`, like every
  other clock.
- **Memory.** No DRAM clear (SIMU). The DDR sits in the MiSTer's FPGA window
  (byte `0x2000_0000` up); `ss_core` inverts word-address bits 25:17. DDR latency is a fixed 8 cycles to the
  first beat, with up to 8 reads outstanding. `--ddr-stress` adds random
  waitrequest.
- **Disks.** SD requests are answered after 40 cycles. On the board, Main takes
  far longer.
- **Assertions.** They are not checked.
