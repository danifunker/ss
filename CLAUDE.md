# SunSparcStation_MiSTer — working notes for Claude

Sun SPARCstation 5 / SPARCstation 20 (sun4m) core for MiSTer, by
Grabulosaure (upstream `github.com/Grabulosaure/ss`), being reworked for
distribution on branch `danifunker`. **Read [docs/REWORK.md](docs/REWORK.md)
first**: the multi-session plan, its status table and the session log.

## Layout

| path | what |
|---|---|
| `SunSparcStation.qpf`, `SunSparcStation5.qsf`, `SunSparcStation20.qsf` | Quartus project, two revisions (SS5: 1 CPU, 65 MHz; SS20: `SS20=true`, 3 CPUs, 50 MHz) |
| `SunSparcStation.sv` | MiSTer `emu` top: CONF_STR/OSD, `hps_io`, `ddram_arb` |
| `files.qip` | the RTL list (add new RTL here) |
| `sys/` | **verbatim** Template_MiSTer framework; never edit (revision in REWORK.md) |
| `rtl/mister/` | `ss_core.vhd` (board top: PLL, loader, SCSI muxing, DDR bridges), `plomb_avalon_mister.vhd`, `ddram_arb.sv` (+ `tb/`) |
| `rtl/cpu/` | IU, FPU, MMU/cache (`mcu_*`), SMP mux — `cpu_conf_pack.vhd` holds the build-time options |
| `rtl/sun4m/` | the chipset (was `src/ts`): `ts_core.vhd` machine top, `ts_decode.vhd` address map, ESP, LANCE, TCX/CG3, CS4231, ESCC, NVRAM, timers, interrupts, IOMMU, SCSI image bridges |
| `rtl/plomb/`, `rtl/peri/` | internal bus ("plomb"), generic peripherals |
| `tools/romdis/` | SPARC V8 disassembler, sun4m ROM analyser, OBP Forth decoder, QEMU tracer |
| `tools/sparc_link.py` | ELF32 SPARC linker for one object (LLVM has none) |
| `tools/debugarm/` | upstream's ARM-side debug monitor |
| `tests/cpu/` | bare-metal CPU test suite that runs as the boot PROM (QEMU and core) |
| `docs/` | plan, gap analyses, `rom-disassembly/` of the Sun PROMs |
| `scratch/` | reference PDFs (+ `text/` extractions) and Sun ROM images; gitignored, never commit |

## Rules

- `rtl/sun4m/scsi_mist.vhd`, `scsi_mist_cdrom.vhd`, `scsi_sd.vhd` and
  `ts_lance.vhd` are **generated** from the `.vhs` microcode by the Ruby
  scripts `asm_*.rb` (run in that directory). Edit the `.vhs`, regenerate.
- Comments in the upstream RTL are French; keep new comments English.
- Sun PROM images (`scratch/SparcStation/*.bin`, `*.ROM`) are Sun/Oracle
  copyright: never commit them. The core boots OpenBIOS (`boot.rom` from
  `github.com/Grabulosaure/ss_openbios`).
- The upstream RTL has no license file yet (REWORK phase 0); do not add or
  change license headers.

## Tools on this box

- No Quartus here: builds happen on another machine. Lint the SV with
  Verilator; the VHDL has no simulator yet (GHDL/nvc not installed).
- `qemu-system-sparc` 8.2 runs the real SS5/SS20 PROMs and the CPU suite
  (`tests/cpu/run-qemu.sh`). QEMU has known V8 deviations
  (`tests/cpu/README.md`); it is a reference, not ground truth.
- LLVM 18 (`/usr/lib/llvm-18/bin`) assembles SPARC V8:
  `clang --target=sparc-unknown-elf -mcpu=v8`.
- iverilog + Verilator 5 for SystemVerilog benches (`rtl/mister/tb/run.sh`).
