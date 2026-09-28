# SunSparcStation_MiSTer — working notes for Claude

Sun SPARCstation 5 / SPARCstation 20 (sun4m) core for MiSTer, by
Grabulosaure (upstream `github.com/Grabulosaure/ss`), being reworked for
distribution on branch `danifunker`. **Read [docs/REWORK.md](docs/REWORK.md)
first**: the multi-session plan, its status table and the session log. The
newest `RESUME-*.md` at the root is the hand-off from the last session.

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
| `tests/cpu/` | bare-metal CPU test suite that runs as the boot PROM (QEMU and core); `expected/ss5-core-hw.log` is the hardware baseline |
| `scripts/` | `build.sh 5\|20`, `deploy.sh 5\|20 [--rom F]`, `console.sh` (ttya from the MiSTer), `setopt.sh` (OSD options via the .CFG), `mount.sh` (remembered disk slots); machine settings in the gitignored `scripts/local.env` |
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

- **Quartus 17.0.2 Lite** in `~/intelFPGA_lite/17.0/quartus`: builds run
  here with `scripts/build.sh`. One flow at a time; don't touch the `.qsf`
  while it runs. The VHDL has no simulator yet (GHDL/nvc not installed);
  lint the SV with Verilator.
- **Test MiSTer:** `192.168.99.92` (root, default ssh key), set in
  `scripts/local.env`. mrext screenshots: `curl -X POST
  http://192.168.99.92:8182/api/screenshots`.
- **QEMU 11.1.1:** `~/.local/qemu-11.1.1/bin/qemu-system-sparc`, built
  from source. Use it rather than Ubuntu's 8.2.2, which can't install
  Solaris and has an `sdiv` bug. It runs the real SS5/SS20 PROMs and the CPU
  suite (`QEMU=... tests/cpu/run-qemu.sh`). QEMU has known V8 deviations
  (`tests/cpu/README.md`); it is a reference, not ground truth.
- **Test disk images:** NetBSD 11 and Solaris 8, built as in
  [docs/disk-images.md](docs/disk-images.md). They are in
  `scratch/images/`, with raw copies on the NAS
  (`Sun-Solaris/SparcStation-Images/`).
- LLVM 18 (`/usr/lib/llvm-18/bin`) assembles SPARC V8:
  `clang --target=sparc-unknown-elf -mcpu=v8`.
- iverilog + Verilator 5 for SystemVerilog benches (`rtl/mister/tb/run.sh`).
