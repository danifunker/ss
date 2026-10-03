# Booting the real Sun OBP

REWORK phase 5.1. The user decided (2026-09-28) that the core should boot
Sun's own firmware instead of OpenBIOS: OBP 2.15 on the SS5 build and OBP
2.25 on the SS20 build. This document merges the four phase 4 audits into
one ordered work plan: what the PROM needs, in the order it needs it,
milestone by milestone, with a test for each.

Sources:
- the PROM analyses in [../rom-disassembly/](../rom-disassembly/README.md)
  (reset flows, POST catalogues, device trees);
- the audits: [cpu.md](../impl-gaps/cpu.md), [chipset.md](../impl-gaps/chipset.md),
  [video-audio-glue.md](../impl-gaps/video-audio-glue.md),
  [keyboard-mouse-serial.md](../impl-gaps/keyboard-mouse-serial.md). IDs
  below are theirs.

## Principles

- **The user supplies the PROM image.** It goes in
  `games/SunSparcStation/boot.rom`, like any MiSTer BIOS; Sun images are
  never shipped.
- **OpenBIOS stays bootable** until the real PROM reaches an OS on both
  builds. Where the two need different hardware behaviour (the PROM
  address, the NVRAM image), the core supports both: a PROM decoded at both
  addresses, and an NVRAM image chosen per firmware (below).
- **SS5 first.** QEMU already boots the SS5 PROM to `ok`, so a working
  reference exists and the list of blockers is short. The SS20 needs the MP
  plumbing (MID, MSI) first.
- **Normal boot before diagnostic POST.** With `diag-switch?` false, POST is
  skipped. The S1-diag items (TLB/cache diagnostic ASIs, IOMMU diagnostics,
  FPU trap priority, …) come after the OS boots.
- **Every milestone is visible on ttya** (the MiSTer UART at 115200: the
  core runs the wire at a fixed 115200 whatever OBP programs, kms A.2).

**Status 2026-10-03 (session 9):** the SS20 milestones S1-S8 are done
(below); of the M rows, M8 (`test net`, the LANCE loopback) is done on the
SS20, and **M7 (Stop-A, BREAK), M9 (bus errors) and M10 (diagnostic POST)
are open**: [PLAN.md](../PLAN.md) items B2, B1/A3 and A2/D1. The SS5 rows
are parked with the SS5.

## SS5, OBP 2.15

| M | Milestone | Blocker | Change | Test |
|---|---|---|---|---|
| **M1** | the PROM runs its first instructions | MMU-9: boot-mode fetches go to pa `0xF_F000_0000` + VA[27:0]; microSPARC-II uses `0x7000_0000` + VA[27:0] (User's Manual Table 40). Glue §1 row 2: nothing is decoded at `0x7000_0000` | `mcu_simple.vhd:1390-1395`: boot-mode PA = `0x0_7000_0000` \| VA[27:0] on the SS5 build. `ts_decode.vhd` Gen5: `sel.rom` also for `a[31:24] = 0x70`; `ts_core.vhd` VideoShmuck remaps it to OBRAM like `0xF…`. OpenBIOS keeps working through the `0xF…` alias | serial shows the reset path (with diag: "Power-ON Reset") |
| **M2** | it survives its own soft reset | AUX-1: the system control/status register (`0x71F0_0000`) has no read side, so RS (bit 1) reads 0; SW_RST (`sta 1,[0x71f00000]`) is a full core reset plus a DRAM wipe (ef5ef21), so the PROM comes back on the power-on path forever. CFG-2 | read side: RS set by SW_RST, WD (bit 4) by a watchdog; both kept across that reset (held in `ss_core` outside `reset_n`), cleared by power-on/OSD reset. SW_RST resets the CPU and devices but **not** DRAM (as on a real machine); keep the register file (POST passes its result in `%g1`-`%g7`, which have no reset). Check that OpenBIOS still reboots | exactly one soft reset, then the post-reset path |
| **M3** | it survives `tlb_init_clear` | MMU-1: `sta %g0,[0x1000] 4` (TLB replacement control) lands on the PCR through the VA[11:8]-only decode: EN, BM, … cleared, and the next fetch goes to RAM | decode ASI 4 on VA[12:8]: 0x1000 TLB replacement control (mask `0x0011ffff`, bit 6 forced), 0x1300/0x1400 writable SFSR/SFAR diagnostic aliases, 0x500/0x600 AFSR/AFAR; `mcu_simple.vhd:970-985`, `:1242-1284` | `tests/cpu` `t_mmu_swift` passes on the core (today it reports the alias); the PROM reaches Forth |
| **M4** | `ok` on ttya | TOD-5: the bitstream NVRAM image is OpenBIOS-formatted. Byte 1 = `0x1a` reads as `diag-switch?` true, so POST runs (and fails at test 6, MMU-2); the IDPROM has type `0x72` (SS5 needs `0x80`) → "IDPROM contents are invalid" | an NVRAM image per firmware (OSD "Firmware: OpenBIOS / Sun OBP", or detection from the PROM image's first words): for Sun, zeroes plus a valid IDPROM at `0x1fd8` (byte 0 = 1, byte 1 = `0x80` SS5 / `0x72` SS20, MAC `08:00:20:…`, hostid, byte 15 = XOR of 0-14). OBP then prints "Incorrect configuration checksum; Setting NVRAM parameters to default values", as under QEMU, and carries on. Per-unit MAC/hostid comes with NVRAM persistence and Ethernet (HARDWARE_GAPS #2, #5) | `ok`; `banner` shows the IDPROM MAC and hostid; `printenv diag-switch?` = false |
| **M5** | screen console | V4: `ts_tcx` returns 0 at slot offset 0, so OBP finds no FCode and builds no display node | an FCode ROM at the TCX slot base (SS5 slot 3, pa `0x5000_0000`; offsets `0x0-0xFFFF`). QEMU's `QEMU,tcx.bin` (1402 bytes, GPL, built from OpenBIOS FCode sources) describes exactly the core's 1024×768×8, and OBP 2.15 accepts it under QEMU. The same for CG3 (`QEMU,cgthree.bin`). Record its provenance and licence | "Probing … at 3,0 SUNW,tcx"; the banner on screen; `output-device screen` |
| **M6** | `probe-scsi`, boot from disk | the PROM's own espdma/esp FCode (`fcode-70011f00-espdma.txt`) drives DMA2/ESP like OpenBIOS does (chipset ESP-*), but the targets: the SCSI rework ([scsi-hps.md](scsi-hps.md)) puts the disks at IDs 3 and 1 and the CD at 6 | the SCSI rework; ESP-1/DMA-1 resets | `probe-scsi` lists t3/t1/t6; `boot disk` loads a NetBSD / Solaris kernel |
| **M7** | Stop-A, BREAK | kms A.8 (no Stop key), A.9 (no BREAK delivery), A.10 (the debug mux swallows BREAK) | Pause → sticky Stop; ESCC break detection (RR0 bit 7, ext/status); debug escape off by default | Stop-A at the OS prompt returns to `ok`; `go` resumes |
| **M8** | `boot net` | LAN-1: `le`'s `open` runs an internal loopback test, which the core does not implement; DMA-2 E_BASE_ADDR | LANCE INTL/LOOP loopback; E_BASE_ADDR reset `0xff`; after HPS Ethernet (phase 5.2) | `boot net` sends RARP |
| **M9** | correctness | MMU-4 + DEC-1: no bus errors (empty SBus slots read `0xBA…` and print "Invalid FCode start byte"; not a hang); timer prescaler TMR-1 | a bus error return in `plomb` + SFSR BE/TO + a data access trap | "Nothing there" for empty slots |
| **M10** | diagnostic POST passes | S1-diag list: MMU-2 (TLB diag ASIs; the core has 4+4 TLB entries, the PROM expects 64), C-1/C-2 (cache diag, flash clear), FPU-1 (trap priority, a one-line fix), IOM-3, IOM-7, DEC-2, DMA-4, TOD-1, TMR-3 | per item | `diag-switch? true` → "Power-On Selftest PASSED" |

## SS20, OBP 2.25

The SS20 PROM also runs in boot mode from VA 0, with the PROM at
`0xF_F000_0000`, which the core already does. Its MP start-up comes first.

**Status (2026-10-02, session 5):** S1-S8 done on the board. S1, S2, S4,
S5, S6 (session 3: MSI MID and arbiter, IMPL 1, slot-7 fold, NVRAM IDPROM,
TCX FCode, an 82077 floppy model) and S3 (the `boot` reset); S7 (16-bit
contexts, Fable `ss20-mmu`) and S8: **Solaris 8 boots to login with 3 CPUs
on-line, with no in-memory patch** (Fable's `ss20-asr` fixes, session 5),
from `sol8-ss20.img`. **The NVRAM is saved to the SD card** (TOD-6, OSD
"NVRAM"): set `diag-switch? false`, `boot-device disk` and the ttya
console once at `ok`, and every later core load boots Solaris unattended
(`hwtest.sh 20 --obp FILE solaris-obp`). Left: memory corruption under
sustained disk I/O with the caches on (Fable,
`scratch/handoff/fable-ss20-corruption.md`), LAN-1 (the PROM's `le`
loopback test), M9 bus errors (empty SBus slots print "Invalid FCode start
byte"), the POST's diagnostic ASIs (MMU-2, C-1) for `diag-switch?`.

| M | Milestone | Blocker | Change |
|---|---|---|---|
| **S1** | each CPU knows its MID | SMP-1, IOM-1, IOM-2. `reset_find_mid` copies the MSI MID register (pa `0xF_E000_2000`, reads 0) into ASI 0x38 va 0. With IOMMU IMPL = 0 it reads the MID back from ASI 0x38 (not stored) and ORs in 8, so every CPU is MID 8 and all three run the master path. That breaks even a uniprocessor boot of the 3-CPU build | ASI 0x38 va 0 storage per CPU (`mcu_multi.vhd:1029`); the MSI MID register answering per requester (the MBus master ID), or answered inside each MCU; IOMMU IMPL/VER = `0x13…` as on a real SS20 (QEMU's SS-20 value), so the PROM takes the MSI path |
| **S2** | the master parks and releases the slaves | SMP-2, IOM-1: arbiter enable `0xF_E000_1008` (bit 0 reads 1; bits 3:1 park CPUs 9-B) is not decoded | an arbiter-enable register gating each CPU's bus grant in `smpmux` |
| **S3** | soft reset | AUX-1, as SS5 M2 (syscon bits 1 and 3) | as SS5 M2 |
| **S4** | memory sizing | G6: `cold_master_size_memory` probes the SIMM slots from `0x1C00_0000` down by aliasing. On the core the top 48 MB is plain writable DDR holding OBRAM (the running PROM image, `0x1D00_0000`), TCX VRAM and the scaler buffers | make slot 7 look like a 16 MB DSIMM: fold pa `0x1D00_0000-0x1FFF_FFFF` onto `0x1C00_0000-0x1CFF_FFFF` for CPU accesses (the remaps excepted). 7×64 + 16 = 464 MB = `RAMSIZE`. EMC registers at `0xF_0000_0000` (writes dropped today): check what `rom-cold-code` needs from them |
| **S5** | `ok` | TOD-5 (IDPROM type `0x72` is already right for this build; the NVRAM byte 1 problem remains); IDPROM as SS5 M4 | as SS5 M4 |
| **S6** | screen | V4: TCX FCode at SBus slot 2 (the core's SS20 TCX sits at `0xE_2000_0000`) | as SS5 M5 |
| **S7** | an OS on 1 CPU | MMU-3: 8 context bits against `mmu-nctx` 0x10000, so contexts ≥ 256 alias | 16-bit contexts (new L2TLB tag layout), or 12 plus a node patch; decide with the OSes' context allocators |
| **S8** | MP OS | `romvec` `v3_cpustart` → `cpu_enter_client` (`0x274ac`) is software once S1/S2 work; C-4/SMP-3 (snoop enable) | NetBSD MP, then Solaris MP, without debugarm |

## Cross-cutting decisions to make

1. **How the core knows which firmware it runs.** This matters for the
   NVRAM image and, possibly, for the soft-reset semantics. Options:
   - an OSD option;
   - automatic, from the PROM image (Sun PROMs start with `ba` + `rd %psr`,
     and have "OBP"/"Forthmacs" strings);
   - moot, if NVRAM becomes persistent and firmware-owned (gap #5): the
     first boot of each firmware then initialises its own format.

   Recommended: automatic detection, with the OSD option as an override.
2. **What SW_RST clears.** A real machine keeps DRAM. The core's DRAM wipe
   (ef5ef21) presumably guards against something upstream saw with
   OpenBIOS reboots; test OpenBIOS without it before deciding.
3. **FCode provenance.** QEMU's `pc-bios/QEMU,tcx.bin` and
   `QEMU,cgthree.bin` come from the OpenBIOS project (GPL-2). Embedding them
   in the bitstream is compatible with a GPL core; record the source commit
   in the repo.
4. **The clock the PROM measures.** OBP times a delay loop to derive the CPU
   clock. From it, it sets the DRAM refresh (MCR), the SBus clock (SS5
   TRCR), the SS5 `model` string, and the SS20 MBus clock and MXCC delay
   ([ss5-obp/device-tree.md](../rom-disassembly/ss5-obp/device-tree.md)). At
   the core's 65/50 MHz these differ from the real 85/110 MHz machines.
   Check the `model` and `clock-frequency` properties OSes see.

## Verification

- **Simulation.** A full-machine simulation that boots the PROM to `ok`
  makes M1-M4 an afternoon each instead of a hardware build each. It needs
  GHDL (not installed: `sudo apt install ghdl-mcode`). The SGI Indy core's
  GHDL-to-Verilog-to-Verilator flow (`../SGIIndy_MiSTer/tools/gen_r4300_verilog.sh`)
  is the model. Without it, every milestone is a Quartus build and a
  serial log.
- **The CPU test suite** (`tests/cpu`), as the PROM of the core. Tests to
  add:
  - `t_mmu_swift` passing (M3);
  - a syscon RS/WD test across a soft reset (M2);
  - an unmapped-address read that must trap with SFSR BE/TO (M9);
  - an IDPROM checksum check (M4).
- **QEMU as the reference.** The SS5 PROM's console under QEMU
  (`ss5-obp/qemu-console.txt`) is what the core's serial log should look
  like at M4/M5, apart from QEMU's own deviations (its TLB diagnostics,
  IOMMU version `0x05`).
