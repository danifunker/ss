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
| 0 | Distribution blockers (license, ROM redistribution) | **open, needs the user** |
| 1 | Disassembly of the SS5 and SS20 boot PROMs; POST self-test catalogue; CPU test suite | in progress |
| 2 | Hardware gap analysis (what a real SS5/SS20 has that the core lacks), prioritised | in progress |
| 3 | Re-layout to the Template_MiSTer standard, rename to SunSparcStation | not started |
| 4 | Implementation gap analysis (what the core has, but gets wrong or leaves out) | not started |
| 5 | Execute: fix gaps in priority order (HPS Ethernet first) | not started |
| 6 | Test infrastructure: simulation, CPU suite on hardware, OS boot regressions | not started |
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
2. **Sun PROM images and their disassembly.** The Sun OBP ROMs are Sun/Oracle
   copyright. The images stay in `scratch/` (gitignored) and are never
   committed. The generated listings under `docs/rom-disassembly/` are
   derivative of those images. **Decide before pushing this branch publicly**
   whether to commit the full machine listings or only the hand-written
   analysis plus the generator (`tools/romdis/`), which rebuilds the listings
   from a user-supplied ROM. The analysis documents (layout, POST test
   catalogue, register usage) are fine either way.
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
- **VHDL simulation:** neither GHDL nor nvc is installed (phase 6 needs one:
  `apt install ghdl` or `nvc`, needs the user).

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
  sun4m/                    was src/ts (the chipset); keep file names
  plomb/                    was src/plomb (the internal bus)
  peri/                     was src/peri
  gen/                      the *.rb microcode assemblers and *.vhs sources
releases/                   <core>_YYYYMMDD.rbf + boot.rom (OpenBIOS) + README.md
docs/                       this file, analyses, rom-disassembly/, user docs
tools/                      romdis/, debugarm/ (was soft/debugarm)
tests/                      cpu/ (phase 1f), sim regressions (phase 6)
```

Steps:

1. Move files with `git mv` so history follows. No content edits in the same
   commit.
2. Replace `sys/` with `../Template_MiSTer/sys` verbatim (currently at
   `3ea1134`) and record the commit in `docs/`.
3. Port `ss.sv` to the new framework: `emu_ports.vh`, new outputs
   (`VGA_DISABLE`, `HDMI_BLACKOUT`, `HDMI_BOB_DEINT`, …), the `hps_io` changes,
   the `audio_out.sv` rename. Walk the diff between the old and new
   `sys/sys_top.v` / `hps_io.sv` for any interface change.
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

### Naming decision (open)

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

**Done when** every block has an audit entry with its evidence (datasheet
section, or OS driver code) and a severity.

---

## Phase 5 — execute (outline, refined after phases 2 and 4)

Expected order, subject to the gap reports:

1. HPS-bridged Ethernet for the LANCE (Main_MiSTer extension plus core side),
   RMII kept as an option.
2. Reset and robustness fixes, so no MiSTer reboot is needed between OSes.
3. SMP without the ARM debug monitor.
4. P0/P1 device gaps (floppy? cgsix? SS20 audio?) as agreed in phase 2.
5. Real Sun OBP boot, if phase 4.3 says it is reachable.

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

## Session log

- **2026-09-28, session 1.** Created branch `danifunker`. Surveyed the repo,
  the framework version and the ROMs; chose `ss5.bin` and the SS20 OBP 2.25
  image; extracted the PDF text to `scratch/SparcStation/text/`; found the
  license blocker; wrote this plan. Started phase 1 (tooling) and phase 2.
