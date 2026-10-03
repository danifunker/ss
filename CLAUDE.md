# SunSparcStation_MiSTer — working notes for Claude

Sun SPARCstation 5 / SPARCstation 20 (sun4m) core for MiSTer, by
Grabulosaure (upstream `github.com/Grabulosaure/ss`), being reworked for
distribution on branch `danifunker`. **Read [docs/PLAN.md](docs/PLAN.md)
first**: the current plan (plan 2, from session 10), its work items and
ground rules. [docs/REWORK.md](docs/REWORK.md) is the closed bring-up plan:
its decisions table and the session log of sessions 1-9. The newest
`RESUME-*.md` at the root is the hand-off from the last session.

## Layout

| path | what |
|---|---|
| `SunSparcStation.qpf`, `SunSparcStation5.qsf`, `SunSparcStation20.qsf` | Quartus project, two revisions (SS5: 1 CPU, 60 MHz; SS20: `SS20=true`, 3 CPUs, 55 MHz) |
| `SunSparcStation.sv` | MiSTer `emu` top: CONF_STR/OSD, `hps_io`, `ddram_arb` |
| `files.qip` | the RTL list (add new RTL here) |
| `sys/` | **verbatim** Template_MiSTer framework; never edit (revision in REWORK.md) |
| `rtl/mister/` | `ss_core.vhd` (board top: PLL, loader, SCSI muxing, DDR bridges), `plomb_avalon_mister.vhd`, `ddram_arb.sv` (+ `tb/`) |
| `rtl/cpu/` | IU, FPU, MMU/cache (`mcu_*`), SMP mux — `cpu_conf_pack.vhd` holds the build-time options |
| `rtl/sun4m/` | the chipset (was `src/ts`): `ts_core.vhd` machine top, `ts_decode.vhd` address map, ESP, LANCE, TCX/CG3, CS4231, ESCC, NVRAM, timers, interrupts, IOMMU, SCSI image bridges |
| `rtl/plomb/`, `rtl/peri/` | internal bus ("plomb"), generic peripherals |
| `tools/romdis/` | SPARC V8 disassembler, sun4m ROM analyser, OBP Forth decoder, QEMU tracer |
| `tools/sparc_link.py` | ELF32 SPARC linker for one object (LLVM has none) |
| `tools/debugarm/` | upstream's ARM-side debug monitor; `pcdump` (ours, `make pcdump`, run on the MiSTer): stops each CPU over the debug link on ttya and prints PC, registers, memory, ASI registers; can patch a word through its physical address (`-W`), store through an ASI (`-S`) and resume a CPU elsewhere (`-j`) |
| `tools/ufsread.py` | lists/extracts files from a Solaris UFS disk image (kernel modules for symbols) |
| `tests/cpu/` | bare-metal test suite that runs as the boot PROM (QEMU and core): CPU tests plus `t_chipset.S`; `expected/ss{5,20}-core-hw.log` are the hardware baselines |
| `sim/` | whole-machine Verilator simulation (GHDL 6 lowers `ss_core`); `run-cputest.sh 5\|20` must match the hardware baseline; `build.sh 20 --diag` starts with `diag-switch?` set (Sun POST); see `sim/README.md` |
| `bios/` | OpenBIOS sources (git subtree of Grabulosaure/ss_openbios); `bios/boot.rom` is the image the MiSTer runs; `scripts/build-bios.sh` builds `bios/build/boot.rom` |
| `scripts/` | `build.sh 5\|20 [--seed N]`, `deploy.sh 5\|20 [--rom F]`, `hwtest.sh 5\|20 cpu\|netbsd\|solaris` (board regressions), `console.sh` (ttya from the MiSTer), `setopt.sh` (OSD options via the .CFG), `mount.sh` (remembered disk slots), `machine.sh 5\|20` (per-machine boot.rom/CFG sets), `build-bios.sh`, `kbtype.sh` (types on the core's keyboard through mrext, e.g. at the Sun OBP's `ok`); machine settings in the gitignored `scripts/local.env` |
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
- License: GPL-2 (`LICENSE`, README "License"; user, 2026-10-02). New
  files and the rework's changes are GPL-2.0-or-later. Grabulosaure's
  files ("All rights reserved" headers) await his confirmation: do not
  change their license headers.

## Tools on this box

- **Quartus 17.0.2 Lite** in `~/intelFPGA_lite/17.0/quartus`: builds run
  here with `scripts/build.sh`. One flow at a time; don't touch the `.qsf`
  while it runs, and restore it afterwards (Quartus rewrites it).
  Lint the SV with Verilator; the VHDL is simulated through `sim/` (GHDL →
  Verilog → Verilator).
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
- **GHDL 6.0.0** in `~/.local/opt` (wrapper `~/.local/bin/ghdl`) for `sim/`.
- **SPARC cross GCC** (`sparc64-linux-gnu-`, Ubuntu packages) and `xsltproc` for
  `scripts/build-bios.sh`.
- LLVM 18 (`/usr/lib/llvm-18/bin`) assembles SPARC V8:
  `clang --target=sparc-unknown-elf -mcpu=v8`.
- iverilog + Verilator 5 for SystemVerilog benches (`rtl/mister/tb/run.sh`).
