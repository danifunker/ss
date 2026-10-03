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
  Fixes and the two approved MMU items (A2) only, kept small. **New
  block RAM is allowed for the POST's cache diagnostics (A4)** (user,
  2026-10-03). The POST's ECC and memory-controller tests are out of scope
  (user, 2026-10-03). Session 10's fits: 90 % ALMs; the HDMI clock misses
  by hairlines at some seeds (d1: seeds 2 and 3), seed 4 met everything.
- **CPU work (`rtl/cpu/`) goes to Fable** through a prompt in
  `scratch/handoff/` that the user runs; the main session reviews and
  merges. Everything else (chipset, glue, Main, OpenBIOS, tests, sim,
  scripts) is the main session's.
- **Board work is the main session's.** Stress runs are 30-40 minutes.
- **Branches:** one per repository: this repository on `danifunker`;
  Main (a separate repository, the user's fork of Main_MiSTer, checked out
  in `scratch/Main_MiSTer-sparc`) on `sparcstation-enhancements` only,
  never touching `support/mac`.

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
| A1 | **The trap-return hang.** OpenBIOS's window-overflow handler sometimes freezes CPU 0 (error mode, a wrong PSR after `restore; …; wr %l0,%psr`), depending on code position and on the caches being on. Cause (Fable, `f69e653`): a JMPL decoded behind a RETT stalled in EXE (a store before it waiting for the bus: the CD's DMA) took the fetch unit's stale pc, so Forth's `call %g1` linked `%o7` to the RETT and the callee's `retl` ran the spill handler without a trap. Test `t_dcti` | **done** |
| A2 | **The 64-entry diagnostic TLB (ASI 6, MMU-2)** so the Sun POST passes its TLB Bit Pattern and Flush tests; **the L2 TLB made safe to switch at run time** (swept at reset and when enabled; saturating pending counters) **and NeXTSTEP-compatible** (an ASI 5/6/7 write drops the TLBs). Fable `c265fac`: the image in block RAM on CPU 0 (`cpu_conf_pack` `DIAGTLB_CPUS` 1); tests `t_mmu_diag`, `t_mmu_l2`; the POST's four SRMMU tests pass in simulation | **done** |
| A3 | The MMU side of bus errors (M9): the MMUs force `PB_OK` and SFSR EBE 0 (`mcu_multi.vhd:122`). After B1 | open |
| A4 | The CPU items of the diagnostic POST after A2: the SuperSPARC cache diagnostics (C-1/C-2: D/I-cache data, PTAG and STAG behind ASIs 0x0c-0x0f, the flash clears 0x36/0x37), the diagnostic TLB on every CPU (the POST runs its list on each CPU; `DIAGTLB_CPUS` is 1), the FPU underflow trap and FPU-1, **a look at the POST's timing assumptions**, and **main memory cached even where the PROM maps it uncacheable** (E3; only if the walker's own PTE writes can be kept coherent) (the counter/timer interrupt tests and the CPU probe seem to expect a slow boot PROM; user: "have Fable look into this a bit"). **New block RAM is allowed for this** (user, 2026-10-03). Prompt: `scratch/handoff/fable-post-a4.md` | Fable |

After A1: OpenBIOS enters client programs with the caches on, as the Sun
OBP does (E2, done). After A2: the L2 TLB's default (On gives
Solaris −14 % boot, −28 % CPU-bound time) once NeXTSTEP has been tried
with it on — **needs a NeXTSTEP 3.3 for SPARC image or CD from the user**.

### B. Chipset and platform

| ID | Item | State |
|---|---|---|
| B1 | **Bus errors (M9).** The IU maps a bus `PB_ERROR` to an access error trap, but `plomb_pvc` never produces one: unmapped and empty-slot accesses read garbage (the OBP prints "Invalid FCode start byte" for empty SBus slots instead of "Nothing there"). Chipset side here (decode → `PB_ERROR`, SFSR/AFSR), then a Fable prompt for the MMU (A3) | open |
| B2 | **Stop-A, the L-keys, BREAK (M7).** Today no PC key produces the Sun Stop key or L1-L10 (Main maps those keys to nothing), so there is no way into `ok` from a running OS. Design below, after the Sun-2 core. Test: Stop-A at a Solaris and a NetBSD prompt → `ok`, `go` resumes; L-keys in OpenWindows/CDE; BREAK on the serial console; the keyboard layouts (US/FR/DE/ES) still type their AltGraph characters ([impl-gaps/keyboard-mouse-serial.md](impl-gaps/keyboard-mouse-serial.md) items 4 and 8-10, B). Session 10, `3c9f197`: `ts_ps2sun` (the chords, AltGraph, Pause, Print Screen), `ts_sunkb` (held keys in the reset reply), `ts_aciamux` + `ts_sport` (BREAK); bench `rtl/sun4m/tb/run.sh` (tb_kbd 14/14); board `hwtest.sh 20 kbd` (keys typed on a uinput keyboard through Main) and `brk` (= the simulation); a BREAK drops Solaris (Sun OBP, ttya) to `ok` and `go` resumes it; pcdump unaffected. Not yet tried: Stop-A from the keyboard with the screen console, the L-keys in OpenWindows/CDE, the FR/DE/ES layouts' AltGraph characters | **done** (the screen-console checks open) |
| B3 | **The gap sweep.** Re-check every IMPLEMENTATION_GAPS item (and the four audits in `impl-gaps/`) against today's RTL; sessions 2-8 fixed many without marking them. Known candidates still open: V1 (the Scaler framebuffer OSD mode), A2 (CS4231 status/INT, Linux audio), LAN-2 (the LANCE's receive-buffer size check), LAN-4, T3 (the `UART` declaration), the reset leftovers of §3; NetBSD's install kernel prints `kbd0: reset failed` (already before B2: its reset handshake with `ts_sunkb`). Already fixed but still listed open: TMR-2, TMR-3 (in `ts_timer.vhd`), and from session 10 INT-2, TMR-4, the keyboard audit's 4, 8-10 and B. Then fix them in batches | open |
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
Right Alt), except while an L-key is held: Solaris' abort sequence is
Stop then A with no key between, so Right Alt + F1 then A is Stop-A even
with Right Alt still down. Also: the reset reply lists the keys held (FF 04, then the
held keys, then 7F), so Stop + A / N / D can be held across a reset as on
a Sun (audit item 4); and a BREAK on ttya reaches the ESCC (RR0 bit 7, the
ext/status interrupt) so the OBP and the OSes see it on a serial console,
while BREAK followed by '3' keeps entering the debug link that `pcdump`
uses (audit items 9, 10): `ts_aciamux` holds a BREAK back ~70 ms; '3' or
'4' within that time is the debug link's and is swallowed, anything else
(or nothing) makes it a BREAK for the ESCC, ~70 ms long, with the bytes
received meanwhile held back. The ESCC sets RR0 bit 7, raises an
External/Status interrupt on each edge (WR15 bit 7, WR1 bit 0; RR3,
vector code 101, RR0 latched until WR0's reset) and receives a NUL.

### C. Network

| ID | Item | State |
|---|---|---|
| C1 | **Solaris's TCP under the Sun OBP.** In session 9 DHCP and ping worked on `le1`, but TCP did not (a connect timed out, another read 0 bytes); under OpenBIOS it worked. Session 10, build `a2eth-s2` (A1+A2): **TCP both ways under the Sun OBP** (`OBP=1 scratch/solnet.sh`: 1.16 MB out at 926 KB/s, 4 MB in at 1406 KB/s, cksums equal on both sides; `scratch/sniff.py` on the MiSTer saw 4330 frames, every IP/TCP checksum right, full-size segments both ways). Not reproduced since the IU fix (A1: a wrong `%o7` after an interrupt return is a plausible cause of a lost connection); to be repeated on the next builds before it is closed | wip |
| C2 | The network modes: the OSD (System → Network) picks the adapter at run time: **eth0** (the MiSTer's own port, shared, filtered on the machine's address: what the user wants for most things), macvlan (a virtual interface on eth0 with the machine's address), eth1 (a second, USB adapter), tap0 (needs `/dev/net/tun`, which the test MiSTer's kernel lacks). eth0 and macvlan are checked; eth1 and tap0 stay untested (no adapter, no kernel support). **eth0 is the OSD default** (user, 2026-10-03): the list is eth0, Off, eth1, macvlan, tap0; `07c69eb` (CONF_STR, `eth_ena`, `setopt.sh`) with Main `a2e3ac3` (`mode_from_status()`), board build `a2eth-s2`: NetBSD and Solaris (OpenBIOS) on the LAN | **done** |

### N. NeXTSTEP

| ID | Item | State |
|---|---|---|
| N1 | **NeXTSTEP 3.3 for SPARC**: install and run it, then try the L2 TLB with it (A2's NeXTSTEP fix). The CD is on the MiSTer: `games/SunSparcStation/NeXTSTEP 3.3 User (SPARC, PARISC).iso` (369 MB). **After the CD work is faster** (user, 2026-10-03): E2 and E3 first | open |

### D. Diagnostic POST (M10)

| ID | Item | State |
|---|---|---|
| D1 | Follow the POST in simulation and on the board as A2 lands: the remaining S1-diag items ([design/sun-obp-boot.md](design/sun-obp-boot.md) M10). Chipset items here, CPU items to Fable (A4). Goal: every POST test passes but the memory controller's (**the EMC/SMC register test and the three ECC tests are out of scope**, user 2026-10-03: no ECC memory, no memory-test work), so the POST will end with those failures reported. **Session 10, the whole list** (board, CPU 0, `scratch/ss20-obp225-postall.rom`: `scratch/postall.py` turns post_main's failure branches into nops; `sim/out/hw-20-postall-a2.log`): CPU (A4, prompt `scratch/handoff/fable-post-a4.md`): the six D/I-cache RAM/PTAG/STAG tests, Cache Flashclear, FPU SP Underflow CEXC (FSR stays 0). Chipset (here): EMC/SMC Control Regs (pa 0: exp 100003fc), ECC Multiple UE/CE/CE+UE (pa 8), System Interrupt Regs (f1410004: bits 26:23 must read 0, INT-2), PROC0 User Timer (f1310010: exp f, obs 7), PROC0 Counter/Timer and System Counter ("No interrupt received", then an unexpected trap 0x1e: the interrupt comes, late), MSI/MSBI Control Reg (e000101c, IOM-1), IOMMU CAM/TLB NTA patterns and TLB flush (e000013c, e000023c, e0000140: IOM-7); the run ended there (the late level-14 trap). Fixed in session 10 (`68a339b`, d1-s4): System Interrupt Regs and PROC0 User Timer pass. Also: the POST reports **CPU_#2 NOT installed** on the board (`mp_probe_slaves`: no answer within 50000 polls; the OBP then finds 3 CPUs; the simulation's POST sees 3) | open |
| D2 | A board POST run: `scripts/hwtest.sh 20 --obp scratch/ss20-obp225.rom post` (a copy of the NVRAM with byte 1, `diag-switch?`, set: `post.nvr`; ~20 s). Board = simulation: the D-Cache RAM Write/Read Test fails first | **done** |

### E. Speed (without new logic)

| ID | Item | State |
|---|---|---|
| E1 | Solaris's boot by phase (`scratch/tscap.sh` + `scratch/bootphases.py`): where the 344 s go | open |
| E2 | OpenBIOS's CD boot with the caches on (after A1): NetBSD's install CD 19 min → 113 s. `4f6edcf`: `go()` only flushes the caches; `boot cdrom:d` 113/113/112 s on the board, NetBSD and Solaris from disk | **done** |
| E3 | **The Sun OBP's CD boot is slow too** (NetBSD's install CD: 899 s, though the OBP runs with the caches on at `ok`). **Cause (session 10):** the OBP maps what it gives a client **uncacheable** on a module without an E-cache: `mappage` builds PTEs through the defer `(ffd56c50)`, which stays the uncached builder `(ffd56c00)` (0x1e) unless `ecache?` (an MXCC with E-cache: MCNTL.MB = 0) switches it to `(ffd56c30)` (0x9e for memory); the core's modules run in MBus mode, "0Mb External cache" (the PTEs of the boot program at 0x4000 and 0x300000-0x390000 read `…7e`, C clear; `scratch/obpcdpte.sh`). At `ok` the OBP itself is fast (500 characters in 110 ms, CD reads 1-2.5 ms: `scratch/obprd.sh`). **With `ffd56c30 ffd56c50 (is  1000000 0 do i cache-enable 1000 +loop` typed at `ok`** (the cacheable builder, and C set on the first 16 MB) **`boot cdrom` reaches NetBSD's installer in 90 s** (`scratch/obpcdfast.sh`). **User's choice (2026-10-03): document it** (CD installs are rare), **then: have the CPU do it** if it can be made safe: Fable's A4 item 5 (the table walker's own R/M writes must keep the own D-cache coherent before page tables can be cached; see the prompt). Emulating an E-cache instead was considered and dropped: a real one is 1 MB per CPU (the device has ~700 KB of block RAM in all), and claiming an MXCC would switch the PROM and every OS to their MXCC code paths (its flush and stream copy/fill operations, the POST's MXCC tests): a second cache controller to emulate, for boot-loader speed only. The PROM's caution (most likely DMA/page-table coherency without an MXCC) does not apply to the core, whose caches snoop DMA and whose D-cache is write-through by default: README "Faster boots with the SS20 Sun PROM"; in `nvramrc` (`use-nvramrc? true`, `scratch/obpnvrc.sh`) it gives `boot cdrom` 90 s and Solaris from disk 102 s to its login (177 s without, `scratch/obpsoltime.sh`). PC samples with pcdump are biased toward console output: switching ttya to the debug link stalls the ESCC's transmitter | **done** |

A larger first-level TLB is out (no new features). Disk reads stay at
hps_io's ~4 MB/s (accepted, session 8).

### F. Tests and tools

| ID | Item | State |
|---|---|---|
| F1 | **Move the board tests into the repository.** The regressions this plan relies on live in the gitignored `scratch/` (`solnet.sh`, `nbnet.sh`, `obnet.sh`, `cdtest.sh`, `cdboot.sh`, `cdstage.sh`, `wbtest.sh`, `speed.sh`, `solstress.sh`, `stresswatch.sh`, `obpmem.sh`, `l2tlbtest.sh`, `rdrate.sh`, `romrun.sh`, `tcpsrv.py`, `ttyx.sh`, `startcap.sh`, `stopcap.sh`, `main-swap.sh`, …): copy the useful ones into `scripts/` (or `scripts/board/`), and give `hwtest.sh` the network, CD and stress tests so one command runs the whole board regression. Session 10: `scripts/board/` (`lib.sh`, `net.sh`, `cd.sh`, `stress.sh`, `tcpsrv.py`, `uinput_keys.py`), `scripts/main-swap.sh`; `hwtest.sh` runs them by name (`net-netbsd`, `net-solaris`, `net-solaris-obp`, `obp-testnet`, `cd`, `cd-obp`, `stress`) plus `post`, `brk`, `kbd`, and `all`; `SUN_OBP` in `local.env`. Left in `scratch/`: the one-off investigations (E3's `obpcd*.sh`, `obprd.sh`, `sniff.py`, `postall.py`), `wbtest.sh`, `speed.sh`, `rdrate.sh`, `l2tlbtest.sh`, `tscap.sh`/`bootphases.py` (E1) | wip |
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

(Updated at the end of session 10.)

1. **Fable: A4** (`scratch/handoff/fable-post-a4.md`): the cache
   diagnostics, the FPU underflow trap, the diagnostic TLB on every CPU,
   and a look at the POST's timing assumptions. Run between sessions: it
   shares the tree, Quartus and the board.
2. B1 (bus errors) designed with its MMU half (A3): the chipset can
   report an error on the I/O bus without touching every peripheral (an
   error output from `ts_io` for unmapped addresses, `PB_ERROR` in
   `plomb_pvc`), but nothing is visible until the MMU stops forcing
   `PB_OK`; write the A3 prompt with it.
3. D1's chipset remainder: MSI/MSBI control register (IOM-1), the IOMMU
   diagnostics (IOM-7), then the POST's later groups as A4 lets it run
   further (DMA2/ESP/LANCE registers, TOD). Not the EMC/SMC and ECC tests
   (user).
4. C1: one more `hwtest.sh 20 net-solaris-obp`, then close it.
5. B3 (the gap sweep), B4 (hot-plug), E1 (boot phases: `scratch/tscap.sh`
   + `bootphases.py`); the B2 checks left (Stop-A on the screen console,
   the L-keys in CDE, the FR/DE/ES AltGraph characters).
6. NeXTSTEP (N1) now that CD boots are fast under both PROMs (E2, E3),
   then the L2 TLB default with the user.

## Session log

- **2026-10-03, session 9 (end).** This plan written from REWORK.md's
  open items (user: the old plan is almost entirely done; release later;
  CD audio stays deferred). The user's answers: the NeXTSTEP 3.3 SPARC CD
  is on the MiSTer, to be tried after the CD work is faster (N1 after
  E2/E3); eth0 is the adapter of choice (C2); Stop-A and the L-keys as in
  the Sun-2 core (B2 design); eth0 as the Network default (C2). Next: a
  Fable session for A1 and A2 (`scratch/handoff/fable-session-20261003.md`),
  then the other items.
- **2026-10-03, Fable (between sessions 9 and 10).** A1 (`f69e653`: a
  JMPL decoded behind a stalled RETT linked `%o7` to the RETT) and A2
  (`c265fac`: the diagnostic TLB on CPU 0, the L2 TLB swept at reset and
  when enabled), board baseline 71/0/0 (`fb07ffb`); report
  `scratch/handoff/fable-report-20261003.md`.
- **2026-10-03, session 10.** Fable's commits reviewed (only `rtl/cpu/`
  and `tests/cpu/`); the A2 rbf on the board; regression: simulation CPU
  suite 71/0/0 and ethtest 8/0/0, board cpu, scsi, NetBSD, Solaris,
  Solaris under the Sun OBP (3 CPUs). **E2 done** (`4f6edcf`: OpenBIOS
  enters clients with the caches on; NetBSD's install CD 113 s, 3 of 3).
  **C2 done** (`07c69eb`, Main `a2e3ac3`: eth0 is the Network default).
  **C1**: Solaris's TCP under the Sun OBP works on the A1+A2 builds (twice;
  `scratch/sniff.py` on the MiSTer saw clean frames). **D2 done**
  (`hwtest.sh post`); **D1**: the whole POST failure list on the board
  (`scratch/postall.py` patches the failure exits out); the CPU side is
  Fable's A4 (`scratch/handoff/fable-post-a4.md`; **the user allows new
  block RAM for it**), the chipset side here: INT-2 and TMR-4 fixed (`68a339b`, build
  `d1-s4`: both POST tests pass), the rest listed under D1 (EMC/SMC, ECC, MSI, IOMMU diagnostics; the
  counter/timer and CPU-probe tests assume a slow PROM). **E3 explained**:
  the Sun OBP maps a client uncacheable without an E-cache; at `ok`,
  `ffd56c30 ffd56c50 (is  1000000 0 do i cache-enable 1000 +loop` makes
  `boot cdrom` 90 s instead of 899 s (user: document it, README).
  **B2 done** (`3c9f197`: the Sun keys,
  BREAK; board `kbd`, `brk`, Solaris BREAK → ok → go). **F1 mostly done**
  (`34c8386`: `scripts/board/`, `hwtest.sh` runs the whole board
  regression). `pcdump` prints the debug status words and `-w`
  (`649470b`). Final build `d1-s4` (`68a339b`, seed 4; seeds 2 and 3 missed
  the HDMI clock by hairlines): CPU suite, scsitest, brk, kbd, NetBSD,
  Solaris, Solaris under the Sun OBP with 3 CPUs, a 30-minute stress under
  the Sun OBP with all CPUs. User decisions: E3 documented (README), and
  the CPU change to cache RAM despite the PROM goes to Fable's A4 (item 5,
  only if the walker's own PTE writes can be kept coherent); A4 also looks
  at the POST's timing; the ECC and memory-controller POST tests are out
  of scope. Next: Fable's A4, then the suggested order above.
