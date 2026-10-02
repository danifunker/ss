# SunSparcStation_MiSTer — rework plan

The goal is to get this core, Grabulosaure's SPARCstation 5 / SPARCstation 20
(sun4m) core, ready for **real distribution on MiSTer**: the standard
MiSTer-devel layout and framework, a clear hardware story, networking that
works for an ordinary MiSTer owner, a test suite that proves the CPU, and
documentation a new user can follow.

The work spans many sessions. This file is the plan and the hand-off: it says
what each phase delivers, how we know a phase is done, where the work stands, and
which decisions are still open. **Read the status table and the session log
first.**

- Branch: `danifunker` (cut from `main` at `ef5ef21`, 2026-09-28).
- New core name: **SunSparcStation_MiSTer** (see [Naming](#naming-decision-open)).
- Reference material: `scratch/SparcStation/` (gitignored). The PDFs' text is
  extracted to `scratch/SparcStation/text/*.txt` for grepping. Three PDFs are
  image-only scans with no text layer and need OCR before they can be searched:
  `SuperSparc.pdf`, `STP50_DataSheet.pdf` and `HC1.1.2.pdf`.

## Status

| Phase | What | State |
|---|---|---|
| 0 | Distribution blockers (license, ROM redistribution) | **GPL-2** (user, 2026-10-02): `LICENSE` and the README's License section; the rework's own work is GPL-2.0-or-later; Grabulosaure's files keep their notice until he confirms (asked 2026-09-30, no answer yet) |
| 1 | Disassembly of the SS5 and SS20 boot PROMs; POST self-test catalogue; CPU test suite | **disassembly done** ([rom-disassembly/](rom-disassembly/README.md): machine code, POST catalogues, Forth dictionaries, device trees, FCode); CPU suite: ISA tests + Swift MMU registers done, more POST-derived hardware tests to lift (1f) |
| 2 | Hardware gap analysis (what a real SS5/SS20 has that the core lacks), prioritised | **done**: [HARDWARE_GAPS.md](HARDWARE_GAPS.md); P0/P1 list awaiting the user (§9 there) |
| 3 | Re-layout to the Template_MiSTer standard, rename to SunSparcStation | **done, built and booted** (SS5 and SS20): see [Bring-up](#bring-up-stage-0-results-session-1) |
| 4 | Implementation gap analysis (what the core has, but gets wrong or leaves out) | **done**: [IMPLEMENTATION_GAPS.md](IMPLEMENTATION_GAPS.md) over four audits in `impl-gaps/`; the real-OBP work plan is [design/sun-obp-boot.md](design/sun-obp-boot.md) |
| 5 | Execute, in the stage order below (bring-up, simulation, platform foundations, real OBP, Main services, device fixes, SS20/MP, diag POST, release) | **Focus: the SS20** (the SS5 may be cut). SS5 at 60 MHz, SS20 at 55 MHz, both closed. Fable's three `rtl/cpu` fixes (`b775165`) verified on the board (session 5): NetBSD 11 to a shell, and **Solaris 8 under the official Sun OBP 2.25 with no in-memory patch, 3 CPUs**. **NVRAM saved to the SD card** (TOD-6, OSD "NVRAM"): the OBP keeps its settings, and `hwtest.sh 20 solaris-obp` boots Solaris unattended in 4 minutes. The **memory corruption under sustained disk I/O with the caches on** (Solaris with 1 or 3 CPUs, NetBSD) is **fixed** (session 6: `mcu_multi_ext.vhd` released the CPU side on every gap between the DDR beats of a line fill; `sim --ddr-gaps` reproduces the board's bus; rbf `scratch/SunSparcStation20-fillfix-s3.rbf`, on the board: suite 65/0/0, memstress, and 40 minutes each of Solaris with one and three CPUs and of NetBSD under the disk stress). Hand-off: [RESUME-20261002.md](../RESUME-20261002.md) |
| 6 | Test infrastructure: simulation, CPU suite on hardware, OS boot regressions | `scripts/hwtest.sh` (CPU suite, NetBSD, Solaris under OpenBIOS, **Solaris under the Sun PROM with a saved NVRAM**); CPU suite on the board: **SS20 63/0/0, SS5 53/0/0** (`9a99e4b` + tests, session 5), simulation = board (session 6 adds `t_cache3.S`: **SS20 65/0/0 on the board** = simulation, with and without `--ddr-gaps`; SS5 55 in simulation, its board baseline to re-record); `memstress` (board-only RAM stress, 3 CPUs) passes; `sim/run-nvram.sh`; `sim/build.sh --diag` runs Sun's POST; `tools/debugarm/pcdump` reads and patches CPU state on the board |
| 7 | Release engineering: rbfs, `releases/`, user docs, MiSTer distribution | not started |

Phases 1 and 2 are analysis and write only under `docs/` and `tools/`, so they
can run side by side. Phase 3 moves every RTL file, so it waits until the
phase 2 report exists: that report cites `src/…` paths. Phase 4 builds on
phases 1–3.

---

## Phase 0 — distribution blockers (needs the user)

1. **The license.** Nearly every VHDL file carries this header:

   > This source file is copyrighted. Read the "lic.txt" file before use.
   > Experimental version. No warranty of any sort. All rights reserved.

   The repository has no `lic.txt` and no `LICENSE`. A few files have no
   header (for example `ss_core.vhd`, `plomb_avalon_mister.vhd`,
   `ts_cs4231a.vhd` and `scsi_mist*.vhd`). `sys/` is GPL-2+ (MiSTer framework)
   and the upstream `ss.sv` carries a GPL-2+ header. MiSTer-devel distribution
   needs an explicit open license. **Action:** ask Grabulosaure (upstream
   `github.com/Grabulosaure/ss`, `dev@temlib.org`) what license applies, and
   add `LICENSE` plus fixed headers once it is agreed. Nobody should relicense
   the files on their own.
   **Intended (user, 2026-09-30): GPL, like other MiSTer cores** (GPL-2+
   would match `sys/` and upstream's own `ss.sv` header). The user is asking
   Grabulosaure directly; until he confirms, no `LICENSE` file or header
   changes.
   Upstream still had no license on 2026-09-30 (GitHub reports none; last
   push 2026-07-23), nor on 2026-10-02.
   **Decided (user, 2026-10-02): GPL-2, "standard with MiSTer cores",
   after almost a week without an answer.** Done: `LICENSE` (GPL-2 text)
   and a License section in the README: `sys/` GPL-2.0+, OpenBIOS and its
   FCode GPL-2.0, the rework's own files and changes GPL-2.0+. Only the
   copyright holder can license Grabulosaure's files (headers "All rights
   reserved"), so they keep their notice and the README says his
   confirmation is pending; their headers stay unchanged. MiSTer-devel
   distribution still needs his confirmation (or a rewrite of his files).
2. **Sun PROM images and their disassembly.** The Sun OBP ROMs are Sun/Oracle
   copyright. The images stay in `scratch/` (gitignored) and are never
   committed. **Decided (user, 2026-09-28): commit everything else,** the full
   generated listings under `docs/rom-disassembly/` included, because they
   are the reference for the work ahead.
3. **The BIOS the core ships with** is OpenBIOS (`boot.rom` from
   `github.com/Grabulosaure/ss_openbios`, GPL-2). It can be redistributed.
   Whether the core should also run the real Sun OBP is a phase 4/5 question
   (see 4.3).

---

## Phase 1 — boot PROM disassembly, POST catalogue, CPU test suite

### ROM selection

Three images are in `scratch/SparcStation/`. The two chosen are the ones that
match what the core implements:

| Choice | File | Size | MD5 | Machine / CPU | Firmware |
|---|---|---|---|---|---|
| **SS5** | `ss5.bin` | 256 KiB | `6364e9a6f5368e2ecc4e9c1d915a93ae` | SPARCstation 5, microSPARC-II ("Swift", MB86904), the CPU the core's SS5 build implements | **OBP 2.15** (banner "ROM Rev. 2.15"), built `95/03/29 14:21:55` |
| **SS20** | `SparcSTATION 20 SunOBP2-25_525-1377-08.ROM` | 512 KiB | `910bd7306fcec38361fc4c3a2be50fa0` | SPARCstation 10/20, UP/MP, SuperSPARC ("Viking") with or without MXCC, and Ross HyperSPARC | OBP 2.25 (525-1377-08), built `95/09/15 17:18:06`; POST `VRV3.45 (09/11/95)` |
| not chosen | `ss5-170.bin` | 512 KiB | `93b047c88caf6660f6ea3e6aa6a439b1` | SPARCstation 5 model 170, TurboSPARC (MB86907, "SR-71") | OBP 2.x built `97/01/13`; `MB86907 POST 2.2.3 03SEP96` |

`ss5-170.bin`'s POST targets TurboSPARC, which the core does not implement.
Its Forth side is newer and worth a later diff against `ss5.bin` (it adds
`enable-swift-compatability`, TPE link test and the CS4231 / L1A7192
self-tests), but it is not a primary target.

### Reference emulator and toolchain (found in session 1)

- **QEMU as an oracle.** `qemu-system-sparc` 8.2.2 is installed and runs both
  real PROMs. The SS5 (`-M SS-5`) boots to `ok`, printing "ROM Rev. 2.15",
  with POST in diag mode; only the TLB RAM diagnostic fails, because QEMU
  does not model it. The SS20 (`-M SS-20`) runs POST VRV3.45 ("TI,
  STP1021PGA(1.x) 1Mb External cache"), fails one I-TLB diagnostic, maps
  the ROM at `0xffd00000`, and stops early in Forth with "Cpu #0 Data Access
  Error". `tools/romdis/qemu_trace.py` runs a PROM with `-d in_asm` and turns
  every executed ROM address into romdis seeds (`qemu-trace.json`); the
  cleaned console output is `qemu-console.txt` in each ROM folder. QEMU is a
  model, not silicon: its POST results are evidence, not ground truth.
- **Forth inner interpreter.** NEXT is copied to RAM at `0xffef0000`:
  `lduh [%g5]` (IP, 16-bit tokens), `×4 + %g2` (origin) gives the CFA, whose
  16-bit code field is scaled the same way and jumped to; `%g6` is the return
  stack.
- **SPARC toolchain without downloads.** LLVM 18 is installed
  (`/usr/lib/llvm-18/bin`: `clang --target=sparc`, `llvm-mc -triple=sparc`,
  `llvm-objcopy`) and assembles V8, privileged and ASI forms included. It
  has no SPARC linker (no `ld.lld` SPARC32, no `sparc-elf` binutils), so
  the CPU suite links with a small Python ELF relocator.
- **VHDL simulation:** neither GHDL nor nvc is installed here. The user's
  Mac cores used OSS-CAD-Suite's GHDL 7.0.0-dev in WSL on the Windows machine
  (`../lbmactwo_MiSTer/CLAUDE.md`), not on this box. Options: `sudo apt
  install ghdl-mcode` (4.1; Ubuntu's `ghdl-llvm` has a broken libLLVM
  soname), or OSS-CAD-Suite in `~/oss-cad-suite` (a download; needs the
  user's OK).
- **QEMU 11.1.1** built from source (`~/src/qemu-11.1.1`, installed in
  `~/.local/qemu-11.1.1`, sparc-softmmu only). It fixes the `sdiv` bug and
  installs Solaris 8, which 8.2.2 cannot (`tests/cpu/README.md`,
  [disk-images.md](disk-images.md)). The RETT nPC and WRTBR deviations are
  still there in 11.1.1.
- **Quartus 17.0.2 Lite** is on this box, at `~/intelFPGA_lite/17.0/quartus`:
  builds run here (`scripts/build.sh 5|20`).

### Output layout

Directory names below use `rom-disassembly` (the request spelled it
`rom-dissassembly`).

```
docs/rom-disassembly/
  README.md                 index, method, how to regenerate
  ss5-obp/                  ss5.bin
    README.md               image map, reset flow, POST sequence, OBP handoff
    post-tests.md           every POST test: name, what it touches, pass criteria, messages
    listing.s               full annotated disassembly (machine code regions)
    forth-dictionary.txt    every Forth word: address, name, flags, code field, decompiled body
    strings.txt             string table with addresses and references
    hardware-access.md      every physical address / ASI the ROM touches, by device
  ss20-obp-2.25/            same set for the SS20 image
tools/romdis/               the generator (Python 3, no external deps beyond stdlib)
```

### Steps

- **1a. Tooling (`tools/romdis/`).** A SPARC V8 disassembler of our own.
  Capstone 5 cannot decode V8 privileged instructions (`rd %psr`, `wr %wim`,
  `lda [..] asi`, `rett`, …), which are exactly what POST is made of. Add
  annotation for sun4m: ASI names (MMU registers, cache tags and data, bypass,
  MXCC), `sethi`/`or` constant folding into physical addresses tagged with the
  device they hit, branch targets and labels, xrefs, strings, and a
  recursive-descent code/data split seeded from the trap table. Add a
  Forthmacs/OBP dictionary walker: header layout, link chain, code field
  types, and decompiled colon definitions.
- **1b. Image maps.** For each ROM: trap table, POST region, Forth kernel,
  dictionary, FCode images (device drivers), strings, padding, checksum
  location. Record everything in each `README.md`.
- **1c. Reset flow.** Instruction by instruction from the reset vector to the
  first Forth word. That covers what hardware is touched, in which order, and
  with which expected values. This is the bring-up contract a core has to
  meet to run the real PROM.
- **1d. POST catalogue (`post-tests.md`).** Every self-test: IU register file
  and window pointer, ALU and mul/div, traps, FPU (register file, single and
  double ops, FSR, exception blocking stores), MMU (TLB RAM/CAM, context table,
  context, SFSR/SFAR, data pointer), I-cache and D-cache (RAM, tag, flash
  clear), timers and counters (user timer, limit bits), interrupt pending
  registers, NVRAM/TOD, memory (SIMM detect, parity, ECC on SS20), SS20 MXCC
  and Viking and HyperSPARC suites, EPROM checksum. For each test give its
  address, entry, what it proves and the exact expected values.
- **1e. Hardware access map (`hardware-access.md`).** Every device register
  the ROMs touch, grouped by device. This feeds phase 2 directly: anything the
  real PROM touches and the core does not decode is a gap.
- **1f. CPU test suite.** Extract the IU, FPU, MMU and cache tests into a
  standalone bare-metal suite, `tests/cpu/`, in the spirit of the IRIS
  `cpu-tests` suite used by the SGI Indy core. Each test runs from a tiny boot
  stub, reports over the Zilog serial port and gives the same result in
  simulation and on the board. The POST tests provide the expectations for the
  hardware-specific parts. Generic V8 tests (every instruction, window
  overflow and underflow, traps, tagged arithmetic, `ldstub`/`swap`, alignment,
  FP IEEE corner cases) have to be written separately, because POST checks
  hardware, not ISA semantics. Toolchain: `sparc-elf` binutils is not
  installed on this box; building binutils for `sparc-elf` is part of this
  step.
- **1g. Stretch: boot the real Sun PROMs on the core** (sim first). The POST
  failure messages then point straight at hardware differences.

**Done when** both ROM folders hold a complete listing (every byte classified as
code, data, string, Forth or padding), a reset-flow walkthrough, a POST
catalogue, and a hardware access map; and `tests/cpu/` has a runnable first
cut.

---

## Phase 2 — hardware gap analysis

Build a machine-by-machine inventory: what a real SS5 and a real SS20 contain,
against what the core implements, with a priority for each gap. Output:
`docs/HARDWARE_GAPS.md`.

Areas to cover, each checked against `src/` and the manuals in `scratch/`:

- **CPU modules.** microSPARC-II (SS5); SuperSPARC or SuperSPARC-II with or
  without the MXCC E-cache, and HyperSPARC (SS20); `IOMMU rev` / mask
  revision reporting; FPU; SMP bring-up (the README says the ARM debug monitor
  `soft/debugarm` is currently needed to enable SMP).
- **Memory.** SS5 memory controller (8 SIMM slots, parity); SS20 EMC/MXCC with
  ECC; the maximum RAM on MiSTer compared with real machines; VSIMM.
- **Bus and system.** SBus controller and slots (no card slots at all?), the
  IOMMU, MBus, the BootBus, and the SS20's SBI.
- **Slavio / SS5 I/O.** Z85C30 ESCC ×2 (serial A/B, keyboard, mouse);
  MK48T08 NVRAM/TOD; the counter/timers (user timer); the interrupt
  controller; aux registers (LED, power off, …); **82077 floppy**; parallel
  port (BPP / DMA2 parallel channel); the power-off control.
- **DMA2 and devices.** ESP 53C9x SCSI (disk, CD-ROM, targets and IDs);
  LANCE Am7990 Ethernet; CS4231 audio via APC (SS5); **DBRI + SpeakerBox on
  the SS20** (a different audio chip, so the SS20 build may have no native
  audio at all); ISDN.
- **Graphics.** TCX (SS5 onboard with the 8-bit or 24-bit option, as an SBus
  card on the SS20), CG3, and what real machines had: cgsix/TurboGX (the most
  common card, and what most OSes support best), SX/VSIMM on the SS20.
  Resolutions and depths.
- **Ethernet, the headline gap.** The LANCE model exists, but it only reaches
  the wire through an external **RMII PHY wired to USER_IO** (LAN8720 board,
  OSD "Ethernet PHY present"). An ordinary MiSTer owner has no such board. The
  goal: an **HPS-bridged Ethernet**, with frames tunnelled to Linux on the HPS
  (tap/bridge) through a Main_MiSTer extension, the way the MacQuadra800 core
  does it for its SONIC (`../MacQuadra800_MiSTer/docs/ethernet.md`). Keep the
  RMII path as an option.
- **MiSTer integration.** SCSI images vs "Direct SD" (the core drives the SD
  card's SDIO pins directly, which is unusual on MiSTer); image mount and
  unmount at runtime; CD-ROM image formats; RTC seeding (done, `630d68e`); PS/2
  to Sun keyboard layouts; mouse; video modes through the scaler and the
  framebuffer; audio; saving NVRAM (`nvram` persistence to the SD card).

Each row: *real hardware* | *core today* (file refs) | *who needs it* (which
OS or PROM breaks without it) | *priority* P0–P3 | *effort*.

**Done when** every device of the SS5 and SS20 block diagrams appears in the
table with a priority, and the P0/P1 list is agreed with the user.

---

## Phase 3 — re-layout to Template_MiSTer, rename to SunSparcStation

Today the Quartus project lives in `src/board/mister/SS_MiSTer/`, with an old
copy of the framework in `SS_MiSTer/sys/` (it predates `emu_ports.vh`,
`yc_out.sv` and `audio_out.sv`) and the RTL at `src/{cpu,ts,plomb,peri}`.

Target layout, following `../Template_MiSTer` and the conventions already used
in `../SGIIndy_MiSTer` and `../MacQuadra800_MiSTer`:

```
SunSparcStation.qpf         revisions SunSparcStation5, SunSparcStation20 (was ss5 / ss20)
SunSparcStation5.qsf        template qsf + `source files.qip`; SS20 adds VERILOG_MACRO SS20
SunSparcStation20.qsf
SunSparcStation.sdc
SunSparcStation.srf
SunSparcStation.sv          emu top (was ss.sv), `include "sys/emu_ports.vh"`
files.qip                   the RTL list, rtl/-relative
clean.bat  .gitignore  LICENSE  README.md  CLAUDE.md
sys/                        verbatim copy of ../Template_MiSTer/sys (record the commit)
rtl/
  pll/ pll.v pll.qip pll_q17.qip pll.13.qip   (template requirement)
  mister/                   ss_core.vhd, plomb_avalon_mister.vhd
  cpu/                      was src/cpu
  sun4m/                    was src/ts (the chipset); keep file names. The
                            *.vhs microcode and the asm_*.rb assemblers stay
                            beside the .vhd files they generate (the scripts
                            use relative paths)
  plomb/                    was src/plomb (the internal bus)
  peri/                     was src/peri
releases/                   <core>_YYYYMMDD.rbf + boot.rom (OpenBIOS) + README.md
docs/                       this file, analyses, rom-disassembly/, user docs
tools/                      romdis/, debugarm/ (was soft/debugarm)
tests/                      cpu/ (phase 1f), sim regressions (phase 6)
```

### The core depends on a modified framework (found in session 1)

The old `SS_MiSTer/sys/` is not a stock copy. Moving to the stock
`Template_MiSTer/sys` (which may not be modified) breaks three things the
core relies on:

| Custom framework feature | Used for | Stock template | Plan |
|---|---|---|---|
| **A second DDR3 port, `DDRAM2`**: the old `sys_top.v` comments out ALSA's `ddr_svc` and hands its f2sdram `ram2` port to `emu` | `ss_core.vhd`: DDRAM carries video (the TCX VRAM, `i_plomb_avalon_vram`); DDRAM2 carries CPU main memory and the BIOS download (`i_plomb_avalon_dram`) | one `DDRAM` port; `ram2` belongs to ALSA | merge the two masters inside the core onto the one port: a 2:1 Avalon arbiter, or `plomb_mux` ahead of a single `plomb_avalon64`. Costs concurrency, so measure CPU memory latency and video underruns on hardware |
| **The SDIO pins passed to `emu`** (`SDIO_DAT/CMD/CLK`) | the OSD's "Direct SD" SCSI modes (`scsi_sd.vhd` drives the secondary SD card itself) | the secondary SD is reached only in SPI mode through `SD_SCK/MOSI/MISO/CS`, whose pins are shared with analog VGA | **Decided: drop Direct SD.** Disks go through the HPS. The SCSI storage path is to be modelled on the Mac cores (see phase 5, SCSI) |
| **Push-pull USER_IO** (`USER_EN` per pin) | the RMII Ethernet PHY on USER_IO (50 MHz TX0/TX1/TXEN) | USER_IO is **open-drain only** (`!user_out ? 0 : Z`), so 50 MHz RMII cannot work | **Decided: retire RMII.** HPS-bridged Ethernet (HARDWARE_GAPS #1) is the only network path; keep the RMII MAC in `attic/` |

Two smaller differences: `HPS_BUS` is `[45:0]`, not `[48:0]`, and
`hps_io.sv` changed (walk its port list against `ss.sv`'s instance).
`audio_out.v` became `audio_out.sv`, and `hdmi_config.sv`, `pll_cfg.v` and
the old PLL folders went away.

Steps:

1. Move files with `git mv` so history follows. No content edits in the same
   commit.
2. Replace `sys/` with `../Template_MiSTer/sys` verbatim (currently at
   `3ea1134`) and record the commit in `docs/`.
3. Port `ss.sv` to the new framework: `emu_ports.vh`, new outputs
   (`VGA_DISABLE`, `HDMI_BLACKOUT`, `HDMI_BOB_DEINT`, …), the `hps_io` changes,
   the `audio_out.sv` rename. Walk the diff between the old and new
   `sys/sys_top.v` / `hps_io.sv` for any interface change. Then the three
   items in the table above: DDR arbitration, the Direct SD decision, RMII
   removal. This step needs RTL work and a hardware test; it is not a pure
   move.
4. Rewrite the qsfs as template qsf + `source files.qip`, keeping the
   project-specific settings (`MISTER_FB=1`, `SS20=true`, the seed and effort
   multipliers).
5. Rename to SunSparcStation (qpf revisions, rbf names, README title, CONF_STR,
   see the decision below).
6. Remove dead files, or move them to an `attic/` if they are worth keeping:
   `mcu_multi_avant_x.vhd`, `ts_lance_mac_rmii.vhd` (only the `_norxen`
   variant is in `files.qip`), `ts_lance_mac_void.vhd`, and the `iram_*`
   variants. Document which ones `files.qip` really uses.
7. **Verification.** There is no Quartus on this Linux box. Needed: an A&S
   check on the build machine for both revisions, then a full fit and boot on
   hardware (OpenBIOS prompt, then NetBSD / Solaris / Linux). The Verilog/SV
   top can be linted with Verilator here; the VHDL needs GHDL or nvc (neither
   is installed yet).

### Naming decision (decided 2026-09-28: B)

The first field of `CONF_STR` (`"SparcStation;;"`) names the core on MiSTer
and so the `games/` folder that holds `boot.rom` and the disk images.

- **A.** Keep `SparcStation` as the CONF_STR name (existing users' files keep
  working) and rename only the repo, project and rbf files to
  `SunSparcStation`.
- **B.** Rename it to `SunSparcStation` everywhere: a clean, consistent name,
  but existing users must move `games/SparcStation/` to
  `games/SunSparcStation/`, and the release notes have to say so.

Either way the two builds share one folder (same `boot.rom`, same disk
images), the way Atari800_MiSTer ships two rbfs from two revisions of one
project.

**Decided: B.** The CONF_STR name becomes `SunSparcStation`, so files live in
`games/SunSparcStation/`, and the first release notes must tell existing users
to move `games/SparcStation/`.

---

## Phase 4 — implementation gap analysis

Here the question is not which devices are missing, but whether what the core
implements is complete and correct. It needs a register-by-register and
behaviour-by-behaviour audit against the documentation in `scratch/` (Sun-4M
System Architecture, the microSPARC-II user's manual, TMS390S10, SuperSPARC
whitepaper, TurboSPARC, the SS5 and SS20 service manuals, the 53C9x, Am7990
and CS4231 datasheets) and against reference implementations (QEMU `hw/sparc`,
MAME `sun4m`, OpenBIOS). Output: `docs/IMPLEMENTATION_GAPS.md`, plus design
notes under `docs/design/` for the big items.

Known leads to start from:

- 4.1 **Reset state.** The README says to reboot MiSTer between OSes because
  of "probably a few missing register reset". Audit every register's reset
  value.
- 4.2 **SMP on the SS20** needs `soft/debugarm` to activate. Find out what the
  PROM or OS expects (processor start, MXCC, interrupts) and make SMP work
  without the ARM monitor. Target: multicore Solaris.
- 4.3 **Sun OBP compatibility.** What stops the real SS5 and SS20 PROMs from
  booting on the core (phase 1g feeds this). It also covers FCode ROMs for the
  SBus devices the core presents (TCX, CG3), which a real OBP needs to find
  and drive them.
- 4.4 **CPU fidelity.** The README notes that the MMU and cache differ from
  real microSPARC-II and SuperSPARC, so OSes take different paths (the `IOMMU
  rev` / mask-rev OSD option); `BSD_MODE`; the L2TLB and NeXTSTEP; the SS20
  write-back/AOW options. The phase 1f test suite is the measure.
- 4.5 **Device models.** For ESP, LANCE, TCX, CG3, CS4231, ESCC, NVRAM, timers
  and the interrupt controller: which commands, registers and modes are
  missing, and which OS drivers use them.
- 4.6 **MiSTer glue.** Image handling, runtime mount and unmount, the CD-ROM
  sector size OSD option (2048/512), the keyboard layouts, video timing and
  scaler, audio levels.

- 4.7 **Found so far** (session 1, to be confirmed and fixed):
  - `ss.sv` declared `scsi_conf` and `scsi_cdconf` as 1-bit wires, so only
    the low bit of each OSD field reached `ss_core` (3 and 2 bits wide):
    "Image+Image" gave a single disk and CD-ROM "512" switched the CD-ROM
    off. Fixed in the phase 3 top.
  - The MMU decodes ASI 4 from VA[11:8] only, so microSPARC-II registers
    at `0x1000`, `0x1300` and `0x1400` alias the PCR, SFSR and SFAR. The
    real SS5 PROM writes 0 to `[0x1000]`, which on the core would clear
    boot mode ([ss5-obp/post-tests.md](rom-disassembly/ss5-obp/post-tests.md)).
  - The TLB diagnostic ASI (6) and the cache RAM/tag ASIs are not
    implemented, so POST test 6 fails (QEMU fails it too).
  - The SS5 PROM sits at pa `0xF…` on the core but `0x7000_0000` on a real
    SS5; the Sun PROM reads itself and maps itself at `0x70000000`.
  - Unmapped addresses never fault: they return `0xBADACCE5` and ack
    (HARDWARE_GAPS §2.1). The PROM's SBus/EBus time-out tests cannot pass.
  - SS20 MP, against the real OBP 2.25
    ([ss20-obp-2.25/README.md](rom-disassembly/ss20-obp-2.25/README.md),
    [post-tests.md](rom-disassembly/ss20-obp-2.25/post-tests.md)):
    every CPU identifies as MID 8; the MSI MID register and arbiter
    enable (which the PROM uses to stop and start CPUs) are not decoded;
    ASI 0x38 is the core's internal table-walk ASI, but the PROM keeps the
    MID there; the IOMMU reports IMPL 0 with MB=1. Any one of these breaks
    the PROM's MP start-up, and these are likely what the OS SMP start
    path (`v3_cpustart` → `cpu_enter_client` at 0x274ac) needs too
    (phase 4.2).
  - SS20 POST fails first at "MMU Context Register": the core has 8
    context bits, the SuperSPARC POST expects 12.
  - Absent on the SS20 build: EMC/SMC at pa `0xf_0000_0000`, TLB/cache
    diagnostic ASIs and flash clear, MSI AFSR/AFAR and slot configuration,
    IOMMU diagnostic windows, the MACIO ID register, the parallel port.
  - The FPU "trap priority" POST tests (a misaligned store must trap, tt 7,
    before a pending deferred fp_exception) suggest the order is inverted in
    `iu_pipe5.vhd` (unverified). QEMU raises FP traps at the FPop itself
    and fails these tests too.

**Done when** every block has an audit entry with its evidence (datasheet
section, or OS driver code) and a severity.

---

## Phase 5 — execute

### Stage order (proposed 2026-09-28, reviewed by the user: "looks very good")

The principle is foundations before features. A fast feedback loop comes
first, then the changes everything else builds on (reset, bus errors, the
memory map, NVRAM), and one FPGA↔HPS channel for all the Main-side
services. The items numbered 0-5 further down are the content of these
stages.

| Stage | What | Depends on | State |
|---|---|---|---|
| **0** | Bring-up under the new name: build both revisions, deploy, CPU suite as the BIOS, OpenBIOS `ok`, an OS from disk; baseline area/timing | phase 3 | SS5 **mostly done** (below). Left: SS20 build; close SS5 timing (-2.7 ns); NetBSD to a login on the core; `scripts/` for screenshots |
| **1** | Full-machine simulation (GHDL → Verilog → Verilator, as the SGI Indy core does) booting OpenBIOS and the CPU suite; regression scripts | a GHDL on this box | **done** (session 2): `sim/`, GHDL 6.0.0 in `~/.local/opt`; the CPU suite matches the board; ~60 kHz, so OS boots stay on hardware |
| **2** | Platform foundations: reset architecture (SW_RST keeps DRAM, RS status bit, reset everything the audits found surviving), bus errors (unmapped → fault), memory-map decisions (SS5 PROM at `0x7000_0000` and `0xF…`; SS20 top-48 MB fold; FCode ROM windows), NVRAM persistence plus the IDPROM | 1 (for fast testing) | not started |
| **3** | Real Sun OBP on the SS5 (design/sun-obp-boot.md M1-M5), then use it as the hardware regression tool | 2 | not started |
| **4** | Main-side services on one channel: design the FPGA↔HPS channel once; SCSI replies in Main (IDs 3/1/6), then HPS Ethernet; test with OpenBIOS and the real OBP | 2, the revised SCSI design | not started (the "replies in Main" revision of design/scsi-hps.md is still to write) |
| **5** | Device and OS fixes in batches (the IMPLEMENTATION_GAPS quick wins: ESCC, timers, TOD, CG3, CS4231, mouse, Stop-A/BREAK, UART CONF_STR, Scaler framebuffer) | 2 | **in progress** (session 2): ESCC TX fix verified (NetBSD shell on ttya); a batch of chipset fixes awaits a build |
| **6** | SS20 and MP: MID/MSI/arbiter enable, IOMMU IMPL, 16-bit contexts, the real OBP on the SS20, SMP without debugarm | 2, 4 (area freed) | **in progress** (session 3): MSI MID + arbiter, IMPL 1, slot-7 fold, 82077 floppy, OpenBIOS CPU nodes: the OBP 2.25 reaches `ok` and loads Solaris. Left: 16-bit contexts and flash clear (Fable prompt), the Solaris panic under the OBP, LANCE loopback, bus errors |
| **7** | Diagnostic POST and polish (the S1-diag items) | 3, 6 | not started |
| **8** | Release (phase 7) | all | not started |
| — | In parallel: the license question with Grabulosaure (phase 0) | — | open |

### Bring-up (Stage 0) results, session 1

- **Build (SS5, on this box).**
  - Fit: 20,372 / 41,910 ALMs (49 %), 31,537 registers, 165 / 553 RAM
    blocks, 45 / 112 DSPs.
  - The first fit showed -74 ns. The core's PLL (`i_pll`) did not match the
    template's clock-group pattern, and the router spent 1.5 h on bogus hold
    fixes. With the clock groups in `SunSparcStation.sdc` routing takes 4
    minutes; every framework clock meets timing, and `clk_sys` (65 MHz)
    misses by **-2.72 ns** (TNS -404 ns). All the failing paths are inside
    the upstream CPU (MCU → IU, IU → IU).
  - Next for timing: seeds, then deciding whether 65 MHz stays. The build
    works on hardware as it is.
- **Hardware (MiSTer `192.168.99.92`).**
  - **CPU suite as the BIOS: 28/32 pass**
    ([tests/cpu/expected/ss5-core-hw.log](../tests/cpu/expected/ss5-core-hw.log)).
  - The four failures are core bugs:
    - RETT with ET=1 executes instead of trapping;
    - CBccc gives illegal_instruction, not cp_disabled;
    - WRTBR overwrites TBR.tt;
    - the ASI 4 `0x1000` alias of the PCR (IMPLEMENTATION_GAPS MMU-1),
      confirmed on the board.
  - **OpenBIOS** boots to "Trying disk…" on the serial console (256 MB,
    `FMI,MB86904`).
  - **NetBSD 11.0 from `netbsd11.raw`**: through autoconfiguration (esp,
    sd0, le, tcx, audiocs), root mounted, the journal replayed. It had not
    reached a login when the capture stopped; that needs a longer look.
- **Images.** NetBSD 11.0 (any target) and Solaris 8 2/04 (target 3) were
  built under QEMU 11.1.1. The recipes are in
  [disk-images.md](disk-images.md). The raw copies are on the NAS in
  `Sun-Solaris/SparcStation-Images/`, and the VHD copies in `scratch/images/`.
  The Solaris image boots on the core only once HD0 is at target 3 (Stage
  4, or a small early fix).
- **Tooling.** In `scripts/`, with the settings in the gitignored `local.env`:
  - `build.sh` builds one revision;
  - `deploy.sh` pushes the rbf and boot.rom and launches the core;
  - `console.sh` captures ttya from the MiSTer's `/dev/ttyS1` at 115200;
  - `setopt.sh` writes the core's `.CFG` OSD options;
  - `mount.sh` writes the remembered-slot records.

  Screenshots come from mrext: `curl -X POST
  http://<mister>:8182/api/screenshots`, then fetch the newest file in
  `/media/fat/screenshots/SunSparcStation/`.

### Session 2 results (2026-09-30)

- **SS20 built** on this box: 33,228 ALMs (79 %), every clock meets timing at
  50 MHz (worst +0.41 ns, HDMI PLL). On the board, the CPU suite passes 27/30
  (`tests/cpu/expected/ss20-core-hw.log`; the same three IU bugs as the SS5).
  That needed the suite to park CPUs 1-2: every CPU leaves reset and runs the
  PROM (cpu SMP-2). OpenBIOS boots with 3 CPUs, 464 MB, then stops at
  "Not a bootable ELF image" with the NetBSD disk that boots on the SS5
  (Stage 6).
- **NetBSD 11 on the SS5:** login on the TCX console (6 min to `login:`), then
  **an interactive root shell on ttya** after the ESCC fix (kms D).
- **SS5 timing at 65 MHz:** -3.52 ns this fit (-2.72 ns in session 1). All of
  the 40 worst paths run from the cache tag RAM (`mcu_simple` `iram_bi`
  TagRAMBi) through the tag compare and `vcache_hit` (fanout 119) into the
  IU decode and stall logic (`Comb_DECODE`, `na_c`), ending at the enables of
  `inst_w_mem.a` (fanout 31). About 16 ns of logic in one cycle, MCU to IU.
  Seeds on identical RTL: 3 → -3.52 ns, 5 → -2.42 ns, 7 → -3.01 ns.
  No functional failure has been observed at 65 MHz: the CPU suite passes
  (28/4, 4 runs, 2 seeds, warm board). Two apparent failures were other
  bugs: a stale CPU-suite ROM on the MiSTer (its rett test crashes the
  core), and OpenBIOS's SD probe reading the unconnected Direct SD pins,
  which hung boots at random (fixed: the inputs idle high). The negative
  slack still has to go before a release. That path is CPU work: the
  prompt is `scratch/handoff/fable-ss5-65mhz.md`.
- **On the board after the fix batch** (`d3f5eb8`, 65 MHz, `scripts/hwtest.sh`):
  - CPU suite 36/2 with Fable's CPU fixes: the four old failures pass, and so
    do the new tests; the two failures are FCode and the `0x70…` PROM alias,
    which came after this build (38/0 in simulation).
  - NetBSD 11 from HD0 at **target 3**: OpenBIOS boots `sd@3,0`, root on
    sd0a, a shell on ttya.
  - **Solaris 8 boots to `console login:`**, the first time on this core
    (the image is installed at target 3): root login, `uname -a` says
    `SunOS 5.8 Generic_108528-29 sun4m SUNW,SPARCstation-5`, 256 MB.
    `psrinfo` shows "0 MHz": OpenBIOS publishes no CPU `clock-frequency`
    (a feature to port into OpenBIOS).
- **The official SS5 ROM in simulation** (all of today's real-OBP fixes):
  silent, as expected before its banner; at 25M cycles it is in
  `kbd_getc_timeout`, the keyboard-reset wait timed by the processor-0 user
  timer.
- **Stage 1, simulation:** see [sim/README.md](../sim/README.md). It found
  that the loader's download writes are not latched (glue G7): words are lost
  whenever the DDR stalls.
- **Machine switching:** `scripts/machine.sh` keeps a `boot.rom`/CFG/slot set
  per machine; `deploy.sh` calls it.
- **SCSI IDs 3/1/6 and OpenBIOS.** OpenBIOS gives the `disk` alias to the
  first disk found scanning targets 0-7 (`drivers/esp.c`), so with HD0 alone
  (target 3) `boot disk` works; with HD1 (target 1) mounted too, `disk` is
  HD1 and HD0 needs `boot disk1` (or a `boot-device` setting). The Sun OBP
  means target 3 by `disk`. A fix belongs in `ss_openbios`.

### Session 3 results (2026-09-30 night to 2026-10-01)

The user locked the SS5 at 60 MHz and the SS20 at 55 MHz, said the core may
drop one of the two machines, and asked to focus on the SS20.

- **SS20 at 55 MHz on the board** (`ab4c740`): CPU suite 35/0, then 38/0
  and 39/0 with this session's chipset tests, every run identical to the
  simulation. **NetBSD 11 boots to a root shell on ttya** (OpenBIOS, HD0 at
  target 3); the old "Not a bootable ELF image" was only OpenBIOS trying ELF
  before a.out.
- **MSI (`c901e3f`):** the MID register answers 8 + the CPU that owns the
  MBus (smpmux's `sel`, registered, so no `rtl/cpu` change); the arbiter
  enable register parks a CPU by withholding its `smp_w.req` from smpmux
  unless it still owns the parked bus (Sun-4M 5.1.2); IOMMU IMPL/VER 0x13;
  pa `0x1D00_0000-0x1FFF_FFFF` folds onto `0x1C00_0000` (slot 7 is a 16 MB
  SIMM, G6). Reset value of the arbiter: all CPUs on (OpenBIOS starts every
  CPU from reset). `t_msi.S` tests all of it.
- **82077 floppy controller with no drive (`8e21d07`, `ts_fdc`)**: the
  official OBP's `fdc-init` polled for RQM forever. Now it resets the
  controller, finds no drive and disables `/obio/SUNW,fdtwo`. `t_fdc`.
- **The official Sun OBP 2.25 reaches `ok` on the board** (screen console):
  "SPARCstation 20 MP (3 X 390Z50), Keyboard Present, ROM Rev. 2.25, 464 MB
  memory installed", the TCX found through our FCode, `probe-scsi` shows
  the disk at target 3, the slaves sit in `(idle-cpu-loop)` with MIDs 9 and
  10, and the memory banks probe as 7 × 64 MB + 16 MB. Blank NVRAM makes it
  set `diag-switch?` true, so it boots from `net` first (fails the LANCE
  loopback test, LAN-1). `setenv diag-device disk` then `boot` loads
  **Solaris 8 under the real OBP** to its banner; it then panics (write to
  `0xff000020` from `taskq_dispatch` in `kmem_cache_create`, a bad task
  queue pointer: open, see the hand-off). Typing goes through mrext's
  virtual keyboard (`scratch/kbtype.sh`: `POST /api/controls/keyboard-raw/
  <linux keycode>`).
- **Sun's POST in simulation** (`sim/build.sh 20 --diag`, NVRAM with
  `diag-switch?` set): banner, three CPUs found through the arbiter
  mailboxes, "MMU Context Table Reg Test" passes, **"MMU Context Register
  Test" fails** (8 context bits, MMU-3), and POST hands over to OBP, which
  sizes 464 MB.
- **Solaris 8 under OpenBIOS on the SS20** panicked after its banner: all
  three CPU nodes had MBus module 8's `reg`. Fixed in `bios/` (`b7d0345`);
  it then stops at "Cannot assemble drivers for root" (open).
- **Debugging on the board:** `tools/debugarm/pcdump` (static ARM binary,
  run on the MiSTer) uses upstream's debug link on ttya to stop each CPU
  and print PC, PSR, registers and memory. It found the floppy loop and
  Solaris's panic message and stack (with `tools/ufsread.py` to pull
  `unix`/`genunix` out of `sol8.img` for their symbols).
- Gotchas: never run `pkill -f PATTERN` from a command line that contains
  PATTERN (it kills its own shell); two readers on `/dev/ttyS1` split the
  bytes (it looked like a UART bug once more).

### Session 4 results (2026-10-01 evening)

- **Merged `ss20-smp`** (Fable: `ss20-mmu` + `ss20-smp`, `41007eb`): 16-bit
  contexts, flash clear, synchronous line flushes, SRMMU/V8 trap fixes, and
  the **DDR bridge write-pair fix** (`276b3db`, `plomb_avalon_mister.vhd`:
  a stalled odd beat replaced the latched even word). On the board the SS20
  CPU suite matched the simulation, 59/0/0 (`4d73d63`).
- **Three regressions of `5568d30` found on the board**, each now a test
  that fails on the board (`3809e87`: SS20 57/3/0, SS5 49/2/0), each for
  Fable (`scratch/handoff/fable-iu6-asr.md`):
  1. Reserved ASRs trap `illegal_instruction` (IU-6, our audit's mistake):
     NetBSD's `syslogd` and `login` die of SIGILL at OpenSSL's V8/V9 test
     `rd %asr2` (gdb on the core file, single-user boot). The microSPARC
     manuals: ASR reads act as RDY, writes as NOP. `t_rdasr` rewritten.
  2. ASI 0x4c (SuperSPARC ACTION) no longer aliases the I-cache tags but
     does not read back: Solaris's `bpt_reg` (in the `TI,TMS390Z55` CPU
     module) loops until it does. `t_asi_width` checks 6-8.
  3. One instruction fault sets SFSR.OW (the fetch unit's next fetch on the
     same unmapped page records a second fault): Solaris's sun4m
     `get_fault_type` then never pages user text in and the process loops
     on the fault. Upstream kept the first instruction fault. `t_mmu_ifault`
     (fails on both machines, SFSR `0x367`).
- **All three fixed by Fable the same evening** (`ss20-asr`, merged
  `b775165`; `rtl/cpu` only, one commit each: `7a85732`, `b4eb066`,
  `02569da`): every ASR reads Y and WRASR to a reserved ASR is a NOP
  (`iu_pack.vhd`, the decode gates `m_ry` on rd = 0); `mmu_action`, a
  13-bit per-CPU register at ASI 0x4c as in QEMU (`mcu_multi.vhd`); an
  instruction fault is recorded only while nothing unread is pending, never
  with OW, in both MCUs (a genuine second instruction fault without an SFSR
  read in between is dropped rather than flagged OW: upstream's rule for
  invalid walks, extended). Simulation reproduced both board baselines
  first, then SS20 60/0/0 (28.52M cycles) and SS5 51/0/0 (19.49M); QEMU
  references unchanged. Fits at the default seed: SS20 +0.361 ns worst
  (HDMI PLL clock; +0.380 ns at 55 MHz, 86 % ALMs), SS5 +0.340 ns (+0.883
  ns at 60 MHz); rbfs `scratch/SunSparcStation{20,5}-02569da-s1.rbf`, not
  on the board yet.
- **Solaris 8 under the official Sun OBP 2.25 on the SS20**: the bridge
  fix cured the `taskq` panic of session 3. With 2 and 3 patched in memory
  (`pcdump -W`, `scratch/solpatch.sh`), Solaris reaches its rc scripts;
  with **`sol8-ss20.img`** (the SS5-made image's device links fixed for the
  SS20's ESP path in QEMU, [disk-images.md](disk-images.md)) it boots to
  `sunsparc8 console login:`, **3 CPUs on-line** (`psrinfo`), 464 MB, the
  root on `c1t3d0s0`. The OBP needs `setenv diag-device disk`,
  `output-device ttya`, `input-device ttya`, `reset` after every core load
  (blank NVRAM: TOD-6).
- The "Cannot assemble drivers for root" of Solaris under OpenBIOS on the
  SS20 (session 3) is probably the same image problem; retry with
  `sol8-ss20.img` after the Fable fix.
- Tools: `pcdump` reads/stores any ASI (`-A`, `-S`), patches a word
  through its physical address (`-W`) and resumes a CPU elsewhere (`-j`);
  `tools/ufsread.py` reads NetBSD's FFSv1 too; the test runtime's
  `V_TRAP_RESUME` lets a test survive an instruction fault.
- The SS5 rbf at 60 MHz with the merge (`41007eb`, +0.054 ns) passes
  everything on the board but the two shared regressions.

### Session 5 results (2026-10-01 night to 2026-10-02)

- **Fable's three fixes on the board** (`b775165`): SS20 CPU suite 60/0/0
  (baseline `1f878e7`), then with this session's tests **SS20 63/0/0, SS5
  53/0/0**, both identical to the simulation; **NetBSD 11 on the SS20:
  login and shell** (`syslogd` runs).
- **Solaris 8 under the official OBP 2.25 without any in-memory patch**:
  the ACTION loop and the user-text page-in work; login with **3 CPUs
  on-line**.
- **NVRAM persistence (TOD-6, `9a99e4b`)**: OSD "NVRAM" (`SC3`), an
  8192-byte image file, loaded at every core start (the machine waits for
  it, 3 s at most without one), written back half a second after the last
  change; a blank file gets the built-in IDPROM (`rtl/mister/nvram_sd.vhd`,
  `iram_rtc` true dual-port). On the board: settings typed once at `ok`
  survive a core reload; the OBP then starts in normal mode (no diag POST),
  console on ttya, and boots Solaris in 2.5 minutes. **`hwtest.sh 20 --obp
  FILE solaris-obp`** runs that unattended (4 minutes, 3 CPUs). Fits: SS20
  seed 3 (`scratch/SunSparcStation20-9a99e4b-s3.rbf`: +0.201 ns worst, on
  the HDMI clock; +0.653 ns at 55 MHz; 87 % ALMs; seeds 1, 2, 4 missed by
  0.09-0.26 ns), SS5 seed 1 (+0.078 ns HDMI, +0.321 ns at 60 MHz).
- **Memory corruption under disk I/O with the caches on** (the open
  problem). Three parallel `find /usr -type f -exec cksum {} \;` loops:
  Solaris with 3 CPUs hangs after ~7000 processes (a stack-growth fault
  the kernel never resolves), with one CPU on-line panics after ~1000-2500
  (a jump to a garbage address in `pagefault`; `recursive mutex_enter` on
  the page-table lock its owner had released); a boot once panicked in
  `bread_common` with another frame's register-window outs; NetBSD 11
  (uniprocessor) stops dead after ~8000 (no debug-link answer). **With the
  caches off Solaris survives 40 minutes (~3600 processes).** Plain cached
  traffic is fine: `memstress` (board-only ROM, CPUs 0-2 × 144 MB) and the
  new `t_smp_ring` and `t_cache_st_atomic` pass on the board. So the loss
  needs the caches plus what an OS adds (DMA page-ins, table walks, TLB and
  line flushes, locks on lines another agent touches). Handed to Fable
  with the evidence, the crash dumps and a board reproducer:
  `scratch/handoff/fable-ss20-corruption.md` (`scratch/solstress.sh`).
- **OpenBIOS ran with its I-cache off** (its MMU setup said "ICE non"): on
  the SS20 about two minutes to "Trying disk". Turned on (`9e89fda`): 25 s.
  **Our OpenBIOS build is now the default `bios/boot.rom`** (`59ffd98`):
  NetBSD 11 and Solaris 8 reach a shell with it on both machines (SS20
  Solaris from `sol8-ss20.img` with 3 CPUs; session 3's "Cannot assemble
  drivers for root" was the SS5-made image).
- A blank NVRAM on the SS20 OBP: "Incorrect configuration checksum" sets
  `diag-switch?` true, hence the diag boot after every core load before
  TOD-6.

### Session 6 results (2026-10-02, Fable: the SS20 corruption)

- **The mechanism.** In `rtl/cpu/mcu_multi_ext.vhd` (the SS20's cache
  controller, bus side) `filling_end` was set after the last beat of a
  line fill and never cleared, so `filling_d` / `filling_i`, which hold
  the CPU side off a line while it is being filled, only meant "a beat
  arrived last cycle". A line's tag is written valid when the fill starts
  (`sHIT`); its eight words land over the following cycles. Whenever the
  DDR delivered the beats of a burst with a bubble between them, the CPU
  side was released onto the half-written line: a load or a fetch of a not
  yet written word hit the evicted line's words (the fetch streaming
  `inst_cont` also stops on a bubble and falls back to a tag lookup), and a
  write-through store to such a word was overwritten by the beat that
  landed after it (memory keeps the store, the cache does not). The SS5's
  `mcu_simple.vhd` clears `filling_end` every cycle (a one-cycle pulse) and
  is right. The simulation's DDR model delivers bursts back to back, so
  the suite could never see it, and the board's port does so only when
  the ARM side is busy: Main's SD-card transfers during disk I/O, which is
  exactly when the OSes died. Stale loads, lost stores and garbage
  fetches cover every symptom of session 5 (the stack-growth loop, the
  jump into garbage in `pagefault`, `recursive mutex_enter`, the `bread`
  frame, NetBSD stopping dead); `memstress` passed because it caused no
  SD traffic.
- **The fix** (`mcu_multi_ext.vhd`): `filling_end` defaults to 0 each
  cycle, as in `mcu_simple`, plus resets of the three flags. No other
  change; the SS5 is untouched.
- **Reproduction.** `sim/sim_main.cpp --ddr-gaps` skips the DDR model's
  read beat on half the cycles. `tests/cpu/src/t_cache3.S`:
  `t_cache_fill_words` (2048 lines: a load of word 0 misses and the next
  instructions load words 7..1, then the same with stores, a bypass read
  to wait for the fill and loads back) and `t_icache_fill_words` (ten
  code lines 4 KB apart in one I-cache set, six of `add %o0,k` x 7 +
  `retl`, called 64 times each; the sum must be 7k). Results: SS20
  unfixed without gaps 65/0/0 (= the board baseline + 2); unfixed with
  gaps: the suite never reaches `CPUTEST DONE` (stale fetches hang it in
  the first MMU-on tests, and the two tests alone hang too); fixed: 65/0/0
  with and without gaps, logs byte-identical. SS5 (no RTL change) 55/0/0
  with and without gaps. QEMU: both tests pass on both targets; the QEMU
  reference logs refreshed (they had been three lines behind since
  session 5).
- **Fit:** SS20 seed 3, `scratch/SunSparcStation20-fillfix-s3.rbf`:
  +0.241 ns at 55 MHz, +0.252 ns on the HDMI clock, hold +0.107 ns, TNS 0,
  87 % ALMs (36,311), 46,641 registers.
- **Board (the user's go-ahead, 2026-10-02 morning), rbf
  `SunSparcStation20-fillfix-s3.rbf`:** `hwtest.sh 20 cpu` **65/0/0**,
  byte-identical to the simulation (`ss20-core-hw.log` re-recorded,
  `e62df75`); `memstress` PASS; `scratch/solstress.sh` one CPU, caches on:
  **survived 40 minutes**, ~19,000 processes, no panic (before: a panic
  within 1,000-2,500); `ALLCPUS=1`, three CPUs: **survived 40 minutes**,
  process IDs wrapped past 30,000 (before: hung at ~7,000); `nbstress.sh`:
  **survived 40 minutes** (before: dead at ~25). Logs
  `sim/out/hw-20-{cpu,memstress-fix,solstress-fix1,solstress-fix3,nbstress-fix}.log`.
  Still to do: the SS5 suite image gained the two tests, so
  `hwtest.sh 5 cpu` → 55/0/0 and re-record `ss5-core-hw.log` (no new SS5
  rbf is needed, its RTL is unchanged).

### Work items (the content of the stages)

0. **SCSI storage modelled on the Mac/NeXT cores** (user, 2026-09-28; the
   replies are to live in Main, see Decisions): disk and CD-ROM images only
   through the HPS, the way `../MacQuadra800_MiSTer` does
   it (its NCR 53C96 is from the same 53C9x "ESP" family as the SPARCstation's
   ESP, with HPS-backed targets, a block cache, a CD-ROM target, and the
   Main_MiSTer changes it needed). Main changes are acceptable where needed.
   **Design: [design/scsi-hps.md](design/scsi-hps.md).** Recommended: keep
   `ts_esp` and the DMA2/IOMMU path that every sun4m OS drives; replace
   everything behind the ESP (`scsi_mist*`, `scsi_sd`, the `ss_core`
   muxes) with one SystemVerilog target engine for disks and CD at
   OSD-selectable IDs, in front of the Mac's `scsi_cache.sv`. Steps S0–S5
   need no Main change (stock Main already does multi-block transfers);
   S6 (CUE/BIN/CHD, CD audio) needs a `support/sparc/` in Main. Its §6
   lists nine open questions for the user.
1. **Boot the real Sun OBP** (user, 2026-09-28), SS5 first, then SS20.
   Plan: [design/sun-obp-boot.md](design/sun-obp-boot.md), milestones M1-M10
   (SS5) and S1-S8 (SS20), each with its blocker, the change and a test. What is already known:
   - QEMU boots the SS5 OBP 2.15 to `ok`, so its sun4m model shows what
     the PROM needs.
   - Known blockers on the core:
     - the SS5 PROM decode at pa `0x7000_0000`;
     - the ASI 4 register aliasing;
     - unmapped addresses must fault, or SBus probing finds phantom cards;
     - an IDPROM in NVRAM, with a per-unit MAC and hostid;
     - FCode on the TCX/CG3 "card" (QEMU ships GPL FCode for both);
     - the memory-controller bank registers the PROM sizes SIMMs with;
     - SS20 adds MID/MSI, the EMC/SMC and 12-bit contexts.
   - OpenBIOS stays bootable meanwhile. Decoding the PROM at both addresses
     keeps both firmwares working.
2. HPS-bridged Ethernet for the LANCE (Main_MiSTer extension plus core side).
   RMII is retired (it needs push-pull USER_IO).
3. Reset and robustness fixes, so no MiSTer reboot is needed between OSes.
4. SMP without the ARM debug monitor (the real SS20 OBP's MP start-up needs
   the same fixes: MID, MSI, ASI 0x38).
5. P0/P1 device gaps (floppy? cgsix? SS20 audio?) as agreed in phase 2.

## Phase 6 — test infrastructure

- Simulation of the full machine. The RTL is VHDL (plus the SV top), so the
  options are GHDL or nvc, or GHDL-to-Verilog through the yosys plugin so the
  Verilator flow from the other cores can be reused. Pick one, and boot
  OpenBIOS in simulation to the `ok` prompt over the serial console.
- The CPU suite (1f) in simulation and on hardware, against a reference log.
- OS boot regressions: NetBSD, OpenBSD, Linux, Solaris 2.x, SunOS 4.1.4,
  NeXTSTEP, each to a milestone string over serial.

## Phase 7 — release engineering

- `releases/SunSparcStation5_YYYYMMDD.rbf` and
  `releases/SunSparcStation20_YYYYMMDD.rbf`, plus `releases/README.md`.
- User docs: install (`games/<name>/boot.rom`), making disk images
  (QEMU, dd from real disks), per-OS notes, the OSD reference, Ethernet
  setup.
- MiSTer distribution: meet the MiSTer-devel requirements (open license,
  standard layout, framework up to date) or ship through a custom
  Downloader database.

---

## Facts collected so far

- Two builds from one project: `ss5` (SYSFREQ 65 MHz, 1 CPU, microSPARC-II
  style) and `ss20` (`SS20=true`, 50 MHz, `NCPUS=3`, SuperSPARC style,
  MESI write-back caches). `ss.qpf` lists both revisions.
- OSD today: SCSI configuration (Image / Direct SD / mixes), two HDD images
  plus a CD-ROM ISO, CD sector size, aspect ratio, autoboot, boot console
  (video or serial), TCX or CG3, internal video or scaler framebuffer
  (`MISTER_FB`, 1024×768 8 bpp at `0x3E400000`), keyboard layout
  (US/FR/DE/ES), cache enable, L2TLB, SS20 write-back and AOW, IOMMU rev
  (0x26 / 0x11 NeXTSTEP / 0x23 / 0x30), Ethernet PHY present, BIOS load
  (`F,ROM`).
- RAM is DDR3 through the Avalon bridge (`plomb_avalon_mister.vhd`), on both
  DDRAM ports; SDRAM is unused.
- The `*.vhd` files `scsi_mist.vhd`, `scsi_mist_cdrom.vhd`, `scsi_sd.vhd` and
  `ts_lance.vhd` are **generated** from the `*.vhs` microcode sources by the
  Ruby scripts `asm_*.rb`. Edit the `.vhs` and regenerate; never hand-edit
  the generated `.vhd`.
- The upstream project has an ARM-side debug monitor, `soft/debugarm`
  (`arm-linux-gnueabihf-gcc`), which talks to the core's debug port and is
  said to be needed for SS20 SMP.

## Decisions

| Date | Decision |
|---|---|
| 2026-09-28 | Core name SunSparcStation_MiSTer; CONF_STR name `SunSparcStation` (`games/SunSparcStation/`) |
| 2026-09-28 | Drop "Direct SD"; disks only through the HPS, SCSI modelled on the Mac cores (Main changes allowed) |
| 2026-09-28 | Retire the RMII Ethernet PHY option; HPS-bridged Ethernet instead |
| 2026-09-28 | Commit the full Sun PROM disassembly listings (the ROM images themselves stay out) |
| 2026-09-28 | **Target the real Sun OBP** (SS5 OBP 2.15, SS20 OBP 2.25) as the firmware, instead of OpenBIOS. Users supply the PROM image, as other MiSTer cores do with their BIOS. OpenBIOS stays bootable until the real PROM works (phase 5.1) |
| 2026-09-28 | SCSI: the disk and CD **replies move into Main** (the NeXT/Mac-family way; frees ALMs). The FPGA keeps the ESP and a thin transport. Keep today's OSD slot layout. SCSI IDs as on a real Sun: disks at 3 and 1, CD at 6. INQUIRY identity "MiSTer". Two disks. CUE/BIN/CHD and CD audio deferred |
| 2026-09-28 | GHDL is not on this box; the user may install it (`sudo apt install ghdl-mcode`, GHDL 4.1) |
| 2026-09-28 | Builds run on this box (Quartus 17.0.2 Lite in `~/intelFPGA_lite`); the test MiSTer is `192.168.99.92` (in `scripts/local.env`, gitignored) |
| 2026-09-28 | Disk images: the OSD takes VHD, IMG, HDA and RAW (all raw sector data to the core); slots are remembered (`SC0`-`SC2`). Test images are built in QEMU 11.1.1; the raw copies are kept on the NAS (`Sun-Solaris/SparcStation-Images/`) |
| 2026-09-28 | QEMU: use the locally built 11.1.1 (`~/.local/qemu-11.1.1`), not Ubuntu's 8.2.2 |
| 2026-09-30 | License: aim for GPL like the other MiSTer cores; pending Grabulosaure's confirmation (phase 0.1) |
| 2026-10-02 | **License: GPL-2** (user). `LICENSE` + README: the rework's work GPL-2.0+; Grabulosaure's files keep their notice until he confirms |
| 2026-10-02 | **SCSI (Stage 4) follows the NeXT or the Macintosh model** (user); it waits for the user's Mac-side PR to be approved |
| 2026-09-30 | SS5 and SS20 keep the shared CONF_STR name for now (one `games/` folder and `.CFG`); a split, or a runtime machine switch, is for later. During development `scripts/machine.sh` swaps the per-machine files |
| 2026-09-30 | CPU fixes (`rtl/cpu/`) go to a Fable agent through a written prompt, one Fable agent at a time; the main session merges its branch after a hardware run |
| 2026-09-30 | Aim for 65 MHz on the SS5 (its speed is the point of the SS5): seeds first, then the MCU→IU path (Fable) |
| 2026-09-30 | Firmware goal restated (user): compatibility with the official Sun ROMs where possible; where they cannot work (the clock speeds may prevent it), port their missing features into OpenBIOS instead |
| 2026-09-30 (evening) | **The SS5 runs at 60 MHz** (user: "lock in at 60 for now"): after the timing work 65 MHz still missed by about 1 ns on a typical seed (six seeds: -0.51 to -1.67). The video keeps its 65 MHz pixel clock, asynchronous to the core. The SS20 misses 60 MHz by 1.15 ns but **closes at 55 MHz** (+0.90 ns), so it runs at 55 MHz. 65 MHz can be revisited: the remaining families are in the session log. |
| 2026-09-30 | **If the SS5 cannot close timing at 65 MHz, the core focuses on the SS20 only** (user). The test is Fable's MCU→IU restructuring (`scratch/handoff/fable-ss5-65mhz.md`) |
| 2026-09-30 | Hardware is the main test bed; the simulation is for short CPU/chipset runs and waveforms |
| 2026-09-30 (night) | The SS20 runs at 55 MHz (closes with +0.9 ns; 60 MHz misses by 1.15 ns) |
| 2026-10-01 | **Focus on the SS20** (user): the core may drop one machine; work goes to the SS20 first. Fable sessions are run by the user from prompts in `scratch/handoff/` |
| 2026-10-01 | MSI arbiter: power-on value enables all CPUs (the real MSI enables 8 and 9 only), because OpenBIOS starts every CPU from reset; the Sun OBP enables 9-B in its first instructions anyway |
| 2026-10-01 (night) | **NVRAM persistence (TOD-6) through a fourth hps_io slot** (OSD "NVRAM", `SC3`, an 8192-byte file the user picks once; Main remounts it at every core start), as the MacLC/LBMacTwo cores save PRAM: needs no Main change. The file is a plain byte image; the user decides per machine / per firmware / per disk (HARDWARE_GAPS question 10). A blank file gets the built-in IDPROM. The machine is held in reset until the image is in (3 s without one) |

### What phase 3 did (session 1)

- Commit `7ba7b37`: moves only (162 renames, no content change).
- Next commit: `sys/` replaced by Template_MiSTer `3ea1134` (2026-08-26),
  verbatim; `SunSparcStation.sv` ported to `emu_ports.vh`; the two DDR3
  ports merged by `rtl/mister/ddram_arb.sv` (video first; randomised bench
  `rtl/mister/tb/run.sh`, 6000 bursts, no errors); Direct SD pins and RMII
  tied off at the `ss_core` boundary (so `ss_core.vhd` is unchanged); OSD
  "SCSI disks: HD0 / HD0+HD1", the Ethernet PHY entry gone, the 1-bit
  `scsi_conf`/`scsi_cdconf` wires fixed; CONF_STR name `SunSparcStation`;
  template qsf + project settings; `SunSparcStation.qpf` with revisions
  `SunSparcStation5` and `SunSparcStation20`.
- Linted: `verilator --lint-only` of the top against the stock `hps_io`
  with an `ss_core` port stub, both revisions. Not synthesised.
- After the phase 4 glue audit: `ddram_arb` rewritten to pipeline. It
  grants with no dead cycle, tracks up to 8 outstanding reads in a FIFO,
  locks write bursts, and flushes an abandoned write burst. Benches are
  `rtl/mister/tb/run.sh`: random, pipelined, abandon, and latency.
- Left for later: moving the unused `scsi_sd*`, `ts_lance_mac_rmii*`,
  `mcu_multi_avant_x.vhd` to `attic/` (done with the SCSI and Ethernet
  work, which change `ss_core`); `MISTER_FB_PALETTE` stays off as upstream
  had it.

## Session log

- **2026-10-02, session 6 (Fable, SS20 corruption).** Found and fixed the
  memory corruption under disk I/O: `mcu_multi_ext.vhd` released the CPU
  side on every bubble between the DDR beats of a line fill (`filling_end`
  never cleared; the SS5 controller was right). `sim --ddr-gaps` and
  `t_cache3.S` (`t_cache_fill_words`, `t_icache_fill_words`) reproduce it:
  unfixed + gaps hangs, fixed 65/0/0 with and without gaps, SS5 55/0/0.
  Fit seed 3 closes (+0.241 ns at 55 MHz). Board: suite 65/0/0, memstress,
  Solaris one and three CPUs and NetBSD each survive 40 minutes of the
  disk stress.

- **2026-10-02, session 5 (SS20).** Fable's three fixes verified on the
  board (SS20 60/0/0, NetBSD shell); Solaris 8 under the Sun OBP without
  patches, 3 CPUs. NVRAM saved to the SD card (TOD-6, OSD "NVRAM",
  `rtl/mister/nvram_sd.vhd`, `sim --nvram`, `sim/run-nvram.sh`), and
  `hwtest.sh solaris-obp`: Solaris boots unattended. OpenBIOS with its
  I-cache on (5× faster start). Found: memory corruption under sustained
  disk I/O with the caches on (both OSes, one or three CPUs; caches off
  survives): tests `t_nvram`, `t_smp_ring`, `t_cache_st_atomic`, the
  `memstress` ROM (all pass), and a Fable prompt with the evidence. Suite
  on the board: SS20 63/0/0, SS5 53/0/0. Hand-off:
  [RESUME-20261002.md](../RESUME-20261002.md).

- **2026-10-01, session 4 (SS20).** Merged Fable's `ss20-smp` (MMU,
  caches, SMP, the DDR bridge write-pair fix); SS20 CPU suite 59/0/0 on the
  board. Three regressions of its `rtl/cpu` change found on the board and
  turned into tests (reserved ASRs, ACTION register, SFSR.OW), handed back
  to Fable (`scratch/handoff/fable-iu6-asr.md`). **Solaris 8 boots to login
  with 3 CPUs on the SS20 under the official Sun OBP 2.25** (in-memory
  workarounds for two of them; `sol8-ss20.img`). `pcdump` patching options.
  New rule from the user: never change branches unless told to. Evening:
  Fable fixed the three on `ss20-asr` (`rtl/cpu` only; simulation SS20
  60/0/0, SS5 51/0/0; both fits met), merged `b775165`; the board tests
  are the next step. Hand-off: [RESUME-20261001.md](../RESUME-20261001.md).
- **2026-10-01, session 3 (SS20).** SS20 at 55 MHz on the board: CPU suite
  39/0, NetBSD shell. MSI MID/arbiter/IMPL and the slot-7 fold (chipset
  only), an 82077 floppy model, `sim --diag` (Sun POST in simulation),
  `pcdump` (CPU state on the board), OpenBIOS CPU nodes per MID. **The
  official SS20 OBP 2.25 runs to `ok` and loads Solaris 8.** Fable prompt
  for the CPU side: `scratch/handoff/fable-ss20-mmu.md` (16-bit contexts,
  flash clear). Hand-off: [RESUME-20261001.md](../RESUME-20261001.md).

- **2026-09-28, session 1.** Created branch `danifunker`. Surveyed the repo,
  the framework version and the ROMs; chose `ss5.bin` and the SS20 OBP 2.25
  image; extracted the PDF text to `scratch/SparcStation/text/`; found the
  license blocker; wrote this plan. Started phase 1 (tooling) and phase 2.
  Then: romdis + QEMU traces; SS5 and SS20 machine-code disassembly and
  POST catalogues; the CPU test suite (27/30 under QEMU, the 3 failures
  QEMU bugs; later +2 Swift MMU tests); HARDWARE_GAPS (phase 2 done); the
  user's decisions (name, Direct SD, RMII, listings); the SCSI design
  (`design/scsi-hps.md`); phase 3 in two commits (moves; stock framework,
  ported top, DDR arbiter); phase 4 audit started in three parts. The Forth
  dictionary decoder (`tools/romdis/obpforth.py`) was still running at the
  end of this entry.
- **2026-09-28, session 1, continued.** Phase 1 finished (the Forth
  dictionaries, device trees, FCode). Phase 4 finished
  (IMPLEMENTATION_GAPS.md plus four audits; design/sun-obp-boot.md). The
  user decided on the real Sun OBP as the target firmware and on SCSI
  replies in Main. `ddram_arb` was rewritten to pipeline. Proposed the stage
  order, which the user reviewed. Stage 0 bring-up: the SS5 builds on this
  box, the SDC clock groups are fixed, the CPU suite passes 28/32 on
  hardware, OpenBIOS boots, and NetBSD mounts its root on the core. Built
  QEMU 11.1.1. Built the NetBSD 11 and Solaris 8 images and copied them to
  the NAS. The SCSI "replies in Main" design revision was started by an
  agent that ended without output: still to do. Hand-off:
  [RESUME-20260928.md](../RESUME-20260928.md).
- **2026-09-30, session 2 (continued).** Fable's CPU fixes merged and
  verified on the board (SS5 38/0). SCSI IDs 3/1/6: NetBSD boots from
  target 3 and **Solaris 8 boots to a login** (first time on this core). The
  "65 MHz fails when warm" scare was a stale test ROM plus OpenBIOS's SD
  probe on the unconnected Direct SD lines (fixed). Real-OBP work: the SS5
  PROM at `0x7000_0000`, TCX/CG3 FCode, the NVRAM IDPROM, the keyboard
  command queue (the official ROM deadlocked in `kbd_putc_boot`; in
  simulation it now runs from RAM). OpenBIOS imported as `bios/` (git
  subtree), built with Ubuntu's sparc64 GCC (`scripts/build-bios.sh`), with
  our first changes. Fable started task 2 (65 MHz). Open: the two-disk hang.
  Hand-off: [RESUME-20260930.md](../RESUME-20260930.md).
- **2026-09-30, Fable timing session (SS5 at 65 MHz), merged as
  `danifunker` = `ss5-timing` at `36f07d3`.** Seed-5 setup slack on the
  core clock: **-0.993 ns** (TNS -49) from -2.345 (TNS -304) at the start of
  the session and -3.5 before the task; hold +0.25; 21,575 ALMs. Seeds 3
  and 7 of the same commit: -2.64 and -1.88, so a typical fit is about -2 ns
  and seed 5 is the lucky end; the seed-7 leaders are the instruction word
  (I-cache data, the MCU's output select) through the decode into the
  bypass select and `pipe_dec.by_rs2` (-1.9), the IU register file through
  the JMPL adder into the next PC (-1.3), and fpu_calc stage 1 (-1.4). SS20 at
  50 MHz: +4.68 ns. Changes: the I-cache hit vector registered, tags in
  MLABs (`mcu_simple`, `mcu_tagram`); the IU's load-use test on the raw
  fields; the FPU register file in MLABs; the FPU's dependency test from a
  registered pending-write map; the FPU decodes the raw instruction word
  (the pipeline-advance chain off its rdy); fpu_calc's stage 1 in two adder
  levels (exhaustively checked against the old chain); and, with the user's
  leave, the CS4231 DMAPVA/DMAPVC write path (`ts_cs4231a`). The SS5 suite
  is 39/39 (t_cache added, SS5 only) and the SS20 35/35 in simulation, cycle
  counts unchanged by the FPU/IU changes (15,732,403 / 16,270,280). What is
  left, -1.0 to -0.6 ns: the in-order pipeline's advance chain (D-cache hit
  → data ready → as_wri/as_mem/as_exe → next PC and fetch enables), the
  JMPL adder, the I-side FSM into the same registers, and the CS4231 sample
  FIFO from the DDR bridge's FIFO state (-0.76). The likely next step is a
  registered D-cache hit vector (as on the I side), which costs a cycle per
  D-line change: a performance trade for the user to decide. Reports and
  scripts: `scratch/handoff/ss5-timing-36f07d3/`, `scratch/handoff/sta-*.tcl`,
  `group-paths.py`. The hardware baseline `ss5-core-hw.log` still has 38
  tests: to be re-recorded from the board with t_cache.
  **Later the same evening (commits 75f3585 to 2a11900):** the bypass select
  on the raw register fields, the IU register file in MLABs, the FPU's
  pending-write map independent of the push: seed 5 reached -0.508 ns
  (TNS -3.7, 40 pairs), but six seeds at 65 MHz spread from -0.51 to -1.67,
  so the user locked the SS5 at **60 MHz**: a fourth PLL output (the video
  stays on the 65 MHz one, its own clock group), `gen60` in `ss_core`,
  SYSFREQ 60000000; first fit +0.376 ns, TNS 0, no negative slack on any
  clock. The SS20 at 60 MHz misses by 1.15 ns (86 % of the device), but at
  **55 MHz** it closes with +0.90 ns (84 %), so it runs at 55 MHz: the PLL's
  fourth output is a parameter (`CORE_MHZ`, set by `ss_core` from SYSFREQ),
  60 MHz on the SS5 and 55 MHz on the SS20, because 55, 60 and 65 cannot
  share one VCO. Still to do: a seed or two more of the SS5 at 60 MHz for
  margin, the board regression at 60 MHz (`hwtest.sh 5 cpu netbsd solaris`,
  re-record `ss5-core-hw.log` with t_cache), and the 65 MHz leftovers if
  wanted (JMPL adder → fetch address, the FPU multiplier's operands, the
  D-cache hit into the advance chain; SS20 at 60: `by_sel2` → `npc`, the
  `mcu_mp` I-TLB into the decode).
- **2026-09-30, session 2.** GHDL 6.0.0 installed; Stage 1 simulation
  (`sim/`) built and matched to the board. SS20 built and run (CPU suite
  27/30 with a park for CPUs 1-2; OpenBIOS up, disk boot fails). ESCC TX fix:
  NetBSD shell on ttya. SS20 MCU latch fix. CPU bugs handed to Fable
  (`cpu-fixes` branch). Timing analysis of the SS5 miss; a seed sweep. A
  batch of chipset fixes (AUX-1 system control register and SW reset
  without the DRAM wipe, INT-1, DMA-1/2, ESP-1, TMR-1/2/3, TOD-1, V2, V3,
  A1, mouse deltas, the PS/2 LED path, ZS-7, DCD/CTS, SCSI IDs 3/1/6, the
  loader's download writes, the aspect-ratio option) awaiting a build.
