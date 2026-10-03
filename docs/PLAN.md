# SunSparcStation_MiSTer — plan 2: finishing the SS20

The bring-up plan, [REWORK.md](REWORK.md), is done in its essentials
(sessions 1-9, 2026-09-28 to 2026-10-03): the SS20 core on the standard
MiSTer framework boots NetBSD 11 and Solaris 8 under OpenBIOS and Solaris 8
under the official Sun OBP 2.25 with its three CPUs; SCSI disks, CD images
and Ethernet go through Main (`sparcstation-enhancements`, `support/sun/`);
the NVRAM is saved to the SD card; a CPU test suite and a whole-machine
simulation back it. REWORK.md stays as the record: its phases, the
decisions table and the session log up to session 9.

This file is the plan from session 10 on: what is left to make the SS20
correct and complete. **Release engineering comes later** (user,
2026-10-03): user docs, the MiSTer distribution route, the licence
confirmation, getting the Main changes upstream (listed at the end, not
worked on now).

## Ground rules (user decisions, see REWORK.md Decisions)

- **SS20 only.** The SS5 revision is parked (it should keep building, no
  effort on it).
- **No new features** (2026-10-03): the SS20 uses ~89 % of the device's
  ALMs and its fits are marginal (session 9: seed 1 failed to route, seed 2
  met the core clock by 0.017 ns); more logic may force it down to 2 CPUs.
  Fixes and the two approved MMU items (A2) only, kept small.
- **CPU work (`rtl/cpu/`) goes to Fable** through a prompt in
  `scratch/handoff/` that the user runs; the main session reviews and
  merges. Everything else (chipset, glue, Main, OpenBIOS, tests, sim,
  scripts) is the main session's.
- **Board work is the main session's.** Stress runs are 30-40 minutes.
- **Branches:** stay on `danifunker`; Main work on
  `sparcstation-enhancements` only, never touching `support/mac`.

## State at the start (2026-10-03, end of session 9)

- Release `SunSparcStation20_20261003` (`releases/`): RTL `f99098d`,
  OpenBIOS `9cb810de`, Main `17224b1`. Board regression: CPU suite
  65/0/0, scsitest 6/0/0, NetBSD and Solaris under OpenBIOS, Solaris
  under the Sun OBP with 3 CPUs, the OBP's `test net`, Solaris and NetBSD
  on the LAN under OpenBIOS (TCP checked), a 30-minute three-CPU stress.
- Sun OBP milestones ([design/sun-obp-boot.md](design/sun-obp-boot.md)):
  SS20 S1-S8 done, M8 (`test net`) done; **M7, M9, M10 open**.

## Work items

State: **open**, **Fable** (a prompt is written, waiting for the user's
Fable session), **wip**, **done**, **deferred**.

### A. CPU (Fable)

| ID | Item | State |
|---|---|---|
| A1 | **The trap-return hang.** OpenBIOS's window-overflow handler sometimes freezes CPU 0 (error mode, a wrong PSR after `restore; …; wr %l0,%psr`), depending on code position and on the caches being on; `tests/cpu/src/winstress.S` alone does not reproduce it (DMA and the level-14 interrupt are the untried ingredients). Prompt: `scratch/handoff/fable-layout-hang.md` | Fable |
| A2 | **The 64-entry diagnostic TLB (ASI 6, MMU-2)** so the Sun POST passes its TLB Bit Pattern and Flush tests; **the L2 TLB made safe to switch at run time** (its RAM survives resets, its pending counters overflow while off) **and NeXTSTEP-compatible** (an ASI 6 write invalidates the TLBs). Prompt: `scratch/handoff/fable-mmu-diag-tlb.md` | Fable |
| A3 | The MMU side of bus errors (M9): the MMUs force `PB_OK` and SFSR EBE 0 (`mcu_multi.vhd:122`). After B1 | open |
| A4 | The CPU items of the diagnostic POST after A2 (C-1/C-2 cache diagnostics, FPU-1 trap priority), as the POST reaches them (D1) | open |

After A1: OpenBIOS enters client programs with the caches on, as the Sun
OBP does (`go()` in `bios/openbios/arch/sparc32/boot.c`;
`scratch/boot-cacheon-pad.rom` is that change): NetBSD's install CD boots
in 113 s instead of 19 minutes. After A2: the L2 TLB's default (On gives
Solaris −14 % boot, −28 % CPU-bound time) once NeXTSTEP has been tried
with it on — **needs a NeXTSTEP 3.3 for SPARC image or CD from the user**.

### B. Chipset and platform

| ID | Item | State |
|---|---|---|
| B1 | **Bus errors (M9).** The IU maps a bus `PB_ERROR` to an access error trap, but `plomb_pvc` never produces one: unmapped and empty-slot accesses read garbage (the OBP prints "Invalid FCode start byte" for empty SBus slots instead of "Nothing there"). Chipset side here (decode → `PB_ERROR`, SFSR/AFSR), then a Fable prompt for the MMU (A3) | open |
| B2 | **Stop-A, the L-keys, BREAK (M7).** Today no PC key produces the Sun Stop key or L1-L10 (Main maps those keys to nothing), so there is no way into `ok` from a running OS. Design below, after the Sun-2 core. Test: Stop-A at a Solaris and a NetBSD prompt → `ok`, `go` resumes; L-keys in OpenWindows/CDE; BREAK on the serial console; the keyboard layouts (US/FR/DE/ES) still type their AltGraph characters | open |
([impl-gaps/keyboard-mouse-serial.md](impl-gaps/keyboard-mouse-serial.md)
items 4 and 8-10). Test: Stop-A at a Solaris prompt → `ok`, `go` resumes; BREAK on the serial console | open |
| B3 | **The gap sweep.** Re-check every IMPLEMENTATION_GAPS item (and the four audits in `impl-gaps/`) against today's RTL; sessions 2-8 fixed many without marking them. Known candidates still open: V1 (the Scaler framebuffer OSD mode), A2 (CS4231 status/INT, Linux audio), LAN-2 (the LANCE's receive-buffer size check), LAN-4, T3 (the `UART` declaration), the reset leftovers of §3. Then fix them in batches | open |
| B4 | **Hot-plugging** a disk and a CD while an OS runs (the OSD driven through mrext's keyboard API: F12 88, Down 108, Enter 28); a CD swap under Solaris (`volcheck`/eject) and NetBSD | open |

#### B2 design: the Sun keys on a PC keyboard

The core emulates a Sun Type 4 keyboard (`rtl/sun4m/ts_sunkb.vhd`, the
PS/2 → Sun table in `ts_ps2sun.vhd`; the OSD's US/FR/DE/ES is the layout
byte it reports). The Sun-2 core (`../Sun-2_MiSTer`,
`rtl/sun2_mister_kbd_mouse.sv`) already solved the missing keys, and this
core does the same so both behave alike:

| PC | Sun |
|---|---|
| **Right Alt + F1** | **L1 Stop**: Right Alt + F1, then A, is Stop-A (abort to `ok`) |
| Right Alt + F2 .. F10 | L2 Again, L3 Props, L4 Undo, L5 Front, L6 Copy, L7 Open, L8 Paste, L9 Find, L10 Cut (Sun codes 0x03 0x19 0x1A 0x31 0x33 0x48 0x49 0x5F 0x61; L1 is 0x01) |
| Right Alt + F11 | Help (0x76; a Type 4/5 key the Sun-2 lacks) |
| Right Alt + any other key | **AltGraph** (0x0D) + that key: the Type 4 national layouts need AltGraph, so here Right Alt stays AltGraph whenever it is not a chord with F1..F11 (the Sun-2's Type 3 has no AltGraph, so its Right Alt sends nothing) |
| F1 .. F11 | F1 .. F11, as today (F12 is MiSTer's OSD) |
| Pause, Print Screen | Pause (0x15), Print Screen (0x16); today Pause turns into Ctrl + Num Lock (keyboard audit, item B) |

As in the Sun-2 core, an F-key keeps the meaning it went down with (its
auto-repeats and its release follow it), so releasing Right Alt first
cannot leave an L-key held; Right Alt itself sends nothing until it is
used with another key (then AltGraph goes down first, and comes up with
Right Alt). Also: the reset reply lists the keys held (FF 04, then the
held keys, then 7F), so Stop + A / N / D can be held across a reset as on
a Sun (audit item 4); and a BREAK on ttya reaches the ESCC (RR0 bit 7, the
ext/status interrupt) so the OBP and the OSes see it on a serial console,
while BREAK followed by '3' keeps entering the debug link that `pcdump`
uses (audit items 9, 10).

### C. Network

| ID | Item | State |
|---|---|---|
| C1 | **Solaris's TCP under the Sun OBP.** DHCP and ping work on `le1`, but TCP does not (a connect timed out, another read 0 bytes); under OpenBIOS it works. First suspects: the LANCE's receive side with buffers that are not word-aligned or of odd size (only transmit was made byte-exact, `f99098d`), LAN-2; then the MAC filter with that NVRAM's other address. Extend `ethtest` with receive buffers at 2 mod 4 and odd sizes. Script: `OBP=1 scratch/solnet.sh` | open |
| C2 | The network modes: the OSD (System → Network) picks the adapter at run time: **eth0** (the MiSTer's own port, shared, filtered on the machine's address: what the user wants for most things), macvlan (a virtual interface on eth0 with the machine's address), eth1 (a second, USB adapter), tap0 (needs `/dev/net/tun`, which the test MiSTer's kernel lacks). eth0 and macvlan are checked; eth1 and tap0 stay untested (no adapter, no kernel support). Open: whether eth0 should be the OSD default (today Off) | open |

### N. NeXTSTEP

| ID | Item | State |
|---|---|---|
| N1 | **NeXTSTEP 3.3 for SPARC**: install and run it, then try the L2 TLB with it (A2's NeXTSTEP fix). The CD is on the MiSTer: `games/SunSparcStation/NeXTSTEP 3.3 User (SPARC, PARISC).iso` (369 MB). **After the CD work is faster** (user, 2026-10-03): E2 and E3 first | open |

### D. Diagnostic POST (M10)

| ID | Item | State |
|---|---|---|
| D1 | Follow the POST in simulation and on the board as A2 lands: the remaining S1-diag items (C-1/C-2, FPU-1, IOM-3, IOM-7, DEC-2, DMA-4, TOD-1, TMR-3; [design/sun-obp-boot.md](design/sun-obp-boot.md) M10). Chipset items here, CPU items to Fable (A4). Goal: "Power-On Selftest PASSED" with `diag-switch?` true | open |
| D2 | A board POST run: the Sun OBP with `diag-switch?` true from a copy of the NVRAM image (`scratch/ss20-obp.nvr`), a script for it | open |

### E. Speed (without new logic)

| ID | Item | State |
|---|---|---|
| E1 | Solaris's boot by phase (`scratch/tscap.sh` + `scratch/bootphases.py`): where the 344 s go | open |
| E2 | OpenBIOS's CD boot with the caches on (after A1): NetBSD's install CD 19 min → 113 s | open |
| E3 | **The Sun OBP's CD boot is slow too** (NetBSD's install CD: 899 s, though the OBP runs with the caches on at `ok`): find where the time goes (PC samples with `pcdump`, MCNTL during the boot program); it decides how long a NeXTSTEP or Solaris install from CD takes | open |

A larger first-level TLB is out (no new features). Disk reads stay at
hps_io's ~4 MB/s (accepted, session 8).

### F. Tests and tools

| ID | Item | State |
|---|---|---|
| F1 | **Move the board tests into the repository.** The regressions this plan relies on live in the gitignored `scratch/` (`solnet.sh`, `nbnet.sh`, `obnet.sh`, `cdtest.sh`, `cdboot.sh`, `cdstage.sh`, `wbtest.sh`, `speed.sh`, `solstress.sh`, `stresswatch.sh`, `obpmem.sh`, `l2tlbtest.sh`, `rdrate.sh`, `romrun.sh`, `tcpsrv.py`, `ttyx.sh`, `startcap.sh`, `stopcap.sh`, `main-swap.sh`, …): copy the useful ones into `scripts/` (or `scripts/board/`), and give `hwtest.sh` the network, CD and stress tests so one command runs the whole board regression | open |
| F2 | Keep the simulation's suites current: `sim/run-eth.sh` (ethtest), `sim/run-scsi.sh`, `sim/run-cputest.sh`; add the receive-side Ethernet cases (C1) and any test A1/A2 bring | open |

### Deferred

- **CD audio** (CD-DA): needs a CD-DA path in the core (and is a new
  feature). Kept on the list.
- **The SS5** (parked).
- **Release engineering** (later): user docs (install, making disk images,
  per-OS notes, the OSD reference, Ethernet), the distribution route
  (MiSTer-devel or a Downloader database), the licence (Grabulosaure's
  confirmation, phase 0 of REWORK.md), the Main changes upstream (after PR
  #1336), the framework revision.

## Suggested order

1. C1 (Solaris TCP under the OBP): a known failure with a likely cause.
   E3 (the Sun OBP's slow CD boot) next to it: it gates NeXTSTEP (N1).
2. B2 (Stop-A, the L-keys, BREAK): M7, and the way into `ok` from an OS.
3. F1 (the board tests into the repository), so every later change runs
   the same regression.
4. B1 (bus errors, chipset side), then the A3 prompt.
5. B3 (the gap sweep) and its batches; B4 (hot-plug).
6. E1 (boot phases).
7. D1/D2 as Fable's A2 lands; the A1 follow-ups (caches on in OpenBIOS,
   E2) as A1 lands; then NeXTSTEP (N1) and the L2 TLB default.

Fable runs A1, then A2 (both change the MMU and pipeline code; one at a
time avoids conflicts).

## Session log

- **2026-10-03, session 9 (end).** This plan written from REWORK.md's
  open items (user: the old plan is almost entirely done; release later;
  CD audio stays deferred). The user's answers: the NeXTSTEP 3.3 SPARC CD
  is on the MiSTer, to be tried after the CD work is faster (N1 after
  E2/E3); eth0 is the adapter of choice (C2); Stop-A and the L-keys as in
  the Sun-2 core (B2 design).
