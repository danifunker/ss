# Hardware gap analysis: SPARCstation 5 and SPARCstation 20

> Line references to `ss.sv` point at the MiSTer top as it was before phase 3
> (commit `0fb5903`, `src/board/mister/SS_MiSTer/ss.sv`); phase 3 replaced it
> with `SunSparcStation.sv`. The VHDL moved unchanged, so its line numbers
> still hold.

Phase 2 of [`REWORK.md`](REWORK.md). This compares what a real SPARCstation 5 and
a real SPARCstation 20 contain with what this core implements today, and ranks
the gaps. It is an inventory, not an audit: whether an implemented block is
*correct* is phase 4 (`IMPLEMENTATION_GAPS.md`).

- Written 2026-09-28 against branch `danifunker` at `debac15`.
- Every `file:line` below is at that commit. Phase 3 moves the RTL
  (`src/ts` becomes `rtl/sun4m`, and so on), but the file names stay, so the
  references can still be followed.

## Contents

1. [Scope and method](#1-scope-and-method)
2. [The core at a glance](#2-the-core-at-a-glance)
3. [What the OS actually sees: the OpenBIOS device tree](#3-what-the-os-actually-sees-the-openbios-device-tree)
4. [SPARCstation 5 inventory](#4-sparcstation-5-inventory)
5. [SPARCstation 20 inventory](#5-sparcstation-20-inventory)
6. [MiSTer integration inventory](#6-mister-integration-inventory)
7. [Prioritised gap table](#7-prioritised-gap-table)
8. [Ethernet: HPS bridge design sketch](#8-ethernet-hps-bridge-design-sketch)
9. [Open questions for the user](#9-open-questions-for-the-user)

---

## 1. Scope and method

**Real hardware.** Each machine's block list and physical addresses come from
the reference text in `scratch/SparcStation/text/`:

| Source | Used for |
|---|---|
| `Marquette__Sun_SPARCstation_5_service_manual…txt`, `ss5_110.txt` | SS5 options (DSIMMs, SBus, AFX/S24), POST test list, SIMM address map (Table 4-4) |
| `microSPARC-II-UsersManual2.txt` | SS5 physical address decode (§1.3, Table 40 boot fetch), memory controller, SBus controller |
| `SPARCSTation 20 Field service manual 801-6189-12.txt` | SS20 options and Appendix B functional description (MSBI, MACIO, SEC, SMC, DSIMM/VSIMM/NVSIMM) |
| `Sun4M_SystemArchitecture_edited2.txt` | The sun4m system space map (§3.2.2), TOD/IDPROM (§9.3), AUXIO (§9.8), interrupts; Campus-2 appendix A.II for SS10/SS20-class boards (DBRI, parallel port) |

These were cross-checked against two outside references:

- **QEMU** `hw/sparc/sun4m.c` (master, fetched 2026-09-28): the `ss5_hwdef`
  and `ss20_hwdef` address tables. QEMU runs the same OpenBIOS lineage, so
  its map is also what that firmware expects.
- **Strings in the two Sun PROM images** (`strings -n4`), for the device
  nodes and self-tests a real OBP expects (`SUNW,fdtwo`, `SUNW,bpp`,
  `eccmemctl`, `mxcc-*`, `SUNW,sx`, DBRI tests).

**What the core does.** The claims come from reading the address decoder
(`rtl/sun4m/ts_decode.vhd`), the I/O block (`rtl/sun4m/ts_io.vhd`), the machine top
(`rtl/sun4m/ts_core.vhd`), the board top (`rtl/mister/ss_core.vhd`), the
MiSTer top (`SunSparcStation.sv`), and the device files they
instantiate. Only files listed in `SS_MiSTer/files.qip` count as built.

**What the OS sees.** The core boots Grabulosaure's OpenBIOS fork
(`github.com/Grabulosaure/ss_openbios`, read at `6f3c0b7`, 2026-07-23), built
with `CONFIG_TACUS`. That build lays out a fixed device tree and does no SBus
probing. A device the core decodes but OpenBIOS does not describe is invisible
to Solaris, NetBSD and Linux. A node OpenBIOS describes but the core does not
decode reads as garbage. Section 3 lists that tree.

**How claims are labelled.** "Verified" means read in source or in a
reference in `scratch/`. **(unverified)** marks anything taken from general
knowledge of these machines that is not in `scratch/` and was not checked on
hardware. The phase 1e hardware-access maps (`docs/rom-disassembly/*/hardware-access.md`)
did not exist yet when this was written. Re-check the rows marked "real OBP"
once they do.

Legend used in the inventory tables:

- **yes**: implemented
- **partial**: implemented with known omissions
- **stub**: decoded, but reads and writes do nothing useful
- **no**: not decoded; the address reads `0xBADACCE5` (see §2.1)

Priorities and efforts used in §7:

| Priority | Meaning |
|---|---|
| **P0** | Blocks distribution or common use for an ordinary MiSTer owner |
| **P1** | Major user-visible gap; schedule early in phase 5 |
| **P2** | Needed by a specific OS, by the real Sun PROM, or for fidelity people will notice |
| **P3** | Rare, cosmetic, or only for completeness |

| Effort | Meaning (one developer) |
|---|---|
| **S** | A few days |
| **M** | Up to about two weeks |
| **L** | About one to two months |
| **XL** | More than that, or a new chip model from scratch |

---

## 2. The core at a glance

```
            CPU0..CPU2 (iu + fpu + mcu / mcu_mp, MESI on SS20)
                         |  plomb bus
                  plomb_sel (ts_core.vhd:483-504, 624-641 / 1015-1032)
          +--------------+-------------------------------+
          | MEM: RAM, video RAM, OpenBIOS image           | I/O
          v                                               v
   DDRAM2 port (plomb_avalon64,              ts_io.vhd -> ts_decode.vhd selects:
   ss_core.vhd:703-719)                       dmaux (DMA2 + private config), inter,
          ^                                   iommu, esp, lance, rtc, sport x2,
          | DVMA via IOMMU                    timer, tcx, cs4231, rom/ibram
   plomb_mux <- ESP, LANCE, CS4231 masters (ts_io.vhd:341-380)
                                              TCX scan-out -> DDRAM port
                                              (ss_core.vhd:723-739)
```

### 2.1 Behaviour that affects every row

1. **Unmapped addresses never fault.** When no select matches, `ts_io`'s read
   mux returns `0xBADACCE5` and still acknowledges the access
   (`ts_io.vhd:760`, `ts_io.vhd:790`). Writes are dropped. A real sun4m raises
   a bus time-out, which the CPU takes as a data-access exception. The SS5
   POST tests exactly that ("SBus Read Time-out Test", "EBus Read Time-out
   Test", SS5 service manual §3.5). The OS and the real PROM can therefore not
   probe for absent hardware.
2. **Memory is DDR3.** Both DDRAM ports are used and SDRAM is tri-stated
   (`ss.sv:175`). The core owns a 512 MiB DDR3 window at `0x2000_0000` with
   its 1 MiB blocks in reverse order (`"001" & NOT a[28:20]`,
   `ss_core.vhd:691-692`, `698-699`). *Inferred:* the reversal keeps the
   scaler's own buffers at DDR3 `0x2000_0000` (`sys/sys_top.v:638`) inside
   the unused top of the core's window.
3. **The OpenBIOS image and the TCX VRAM live in RAM.** Both are remapped into
   DDR3: OpenBIOS at `0x1D00_0000`, TCX VRAM at `0x1D40_0000`
   (`ss_core.vhd:153-154`, remap in `ts_core.vhd:1279-1300`).

### 2.2 The two builds

| Generic / setting | SS5 (`ss5.qsf`) | SS20 (`ss20.qsf`, `VERILOG_MACRO SS20`) | Where |
|---|---|---|---|
| `SYSFREQ` | 65 MHz | 50 MHz | `ss.sv:364-374` |
| CPUs (`NCPUS`) | 1 (forced) | 3 | `ss.sv:367,372`; `ts_core.vhd:179` |
| CPU personality | microSPARC-II (`CPUTYPE_MS2`) | SuperSPARC (`CPUTYPE_SS`), no MXCC | `ts_core.vhd:210-220`; `cpu_conf_pack.vhd:67,123` |
| `FPU_MULTI` | 0 (one FPU per CPU) | 0 | `ss.sv:375` |
| RAM (`RAMSIZE`) | 256 MiB | 464 MiB | `ss_core.vhd:156` |
| `TCX_ACCEL` | 1 | 1 | `ss.sv:376` |
| `ETHERNET` | true (commented "FAKE !") | true | `ss_core.vhd:291` |
| `PS2` (PS/2-to-Sun keyboard/mouse emulation) | true | true | `ss_core.vhd:292` |
| `SPORT2` (serial port B ACIA) | true, but the pins are unconnected | same | `ss_core.vhd:294`, `170-171` |
| `MISTER_FB` | 1 (palette macro commented out) | 1 | `ss5.qsf:56-59`, `ss20.qsf:50-53` |

`SYSCONF` gives OpenBIOS the RAM size, SS5 or SS20, and the CPU count
(`ts_core.vhd:193-196`). OpenBIOS reads it through an MMU register (fork
`arch/sparc32/openbios.c`, `machine_detect()` and `numcpu()`). All three are
**compile-time** values.

---

## 3. What the OS actually sees: the OpenBIOS device tree

The OpenBIOS fork, `drivers/sbus.c` and `drivers/obio.c` at `6f3c0b7`:

| Node | SS5 build | SS20 build | Core decodes it? |
|---|---|---|---|
| `SUNW,tcx` or `SUNW,cgthree` | SBus slot 3 (`0x5000_0000`), `sbus.c:330-335` | slot 2 (`0xE_2000_0000`), `sbus.c:364-369` | yes |
| `SUNW,CS4231` (audio) | slot 4, offset `0x0C00_0000`, intr 5 (`sbus.c:218-260`, `336-338`) | **not created** | SS5 yes; SS20 no (§5) |
| `power-management` (APC idle) | slot 4, `APC_OFFSET` = `0x6A00_0000` | slot `0xf` (code comment: "XXX should not exist") | **no** in either build |
| `ledma`/`le`, `espdma`/`esp` | slot 5, via `ob_macio_init` (`sbus.c:263-278`) | slot `0xf` | yes |
| `SUNW,bpp` (parallel) | commented out (`sbus.c:278`) | commented out | no |
| `zs` ×2, `eeprom` (mk48t08), `counter`, `interrupt`, `auxio`, `slavioconfig` | `/obio` (`obio.c:651-687`) | `/obio` | yes, except `slavioconfig` (§4) |
| `power` (AUX2 power-off) | `0x7191_0000` (`openbios.c:72`) | `0xF_F1A0_1000` (`openbios.c:97`) | aliases or stub (§4, §5) |
| `SUNW,fdtwo` (floppy) | not created: `fd_offset = -1` under `CONFIG_TACUS` (`openbios.c:64`) | not created (`openbios.c:89`) | no |
| `/idprom` | written at every boot, machine type `0x80` | machine type `0x72` | n/a |

**Every unit gets the same identity.** OpenBIOS rewrites the IDPROM at each
boot with a hard-coded MAC address, `08:00:20:12:34:56` (`obio.c:269`,
`obio.c:305-320`). The hostid is taken from the last three MAC bytes, so every
MiSTer also reports hostid `0x80123456` (SS5) or `0x72123456` (SS20). The
IDPROM baked into the NVRAM block RAM holds a QEMU-style `52:54:00:12:34:56`,
but it is overwritten at boot (`rtl/sun4m/iram_rtc.vhd`, image offset `0x1FD8`).

---

## 4. SPARCstation 5 inventory

A real SS5 is a single microSPARC-II board. The CPU contains the memory
controller and the SBus controller. The I/O is spread over the SBus: three
slots, plus an AFX slot for the S24 graphics card. The microSPARC-II decodes
`PA[30:28]` into memory, control space, and SBus slave selects
(microSPARC-II UM §1.3, §5.3). The addresses below follow the OBP/QEMU
convention, SBus slot *n* at `0x2000_0000 + n·0x1000_0000`.

| Block | Real SS5 (source) | Physical address | Core today | Status |
|---|---|---|---|---|
| CPU | microSPARC-II (MB86904), 70/85/100/125 MHz parts (MS2 UM §1.2.7); the SS5-170 uses TurboSPARC | on-chip | microSPARC-II personality at 65 MHz (`ss.sv:365`); caches are 4-way 16 KiB VT in the built config (`cpu_conf_pack.vhd:67-93`), the real part is direct-mapped | partial (fidelity is phase 4.4) |
| FPU | on-chip | on-chip | `fpu.vhd`, version 4 (`cpu_conf_pack.vhd:74`) | yes |
| Memory controller, DSIMMs | 8 slots × up to 32 MB = 256 MB, slot *n* at `n·0x0200_0000`, parity (SS5 service manual Table 4-4) | `0x0000_0000-0x0FFF_FFFF` | 256 MiB of DDR3, no parity (`ts_decode.vhd:54`, `ss_core.vhd:156`) | yes; real maximum reached |
| Control space / IOMMU | IOMMU plus SBus slot configuration (MS2 UM §5.7) | `0x1000_0000` | `ts_iommu.vhd`: control, base, flush all, flush address, mask-rev register at `0x3018`. AFSR, AFAR, arbiter and slot-configuration registers are listed in its header but not found in its decode (`ts_iommu.vhd:186-225`); IOPTE V and W bits are ignored (header comment). IMPL/VER reads `0x04` in both builds (`cpu_conf_pack.vhd:92,148`); QEMU uses `0x05` (SS-5) | partial |
| SBus slots 0-2 (cards) | 3 slots (SS5 service manual Table 1-1) | `0x2000_0000`, `0x3000_0000`, `0x4000_0000` | none; the addresses read `BADACCE5` | no (by design) |
| S24 (TCX) on the AFX bus | "accelerated 24-bit color graphics on the system AFX Bus" (SS5 service manual Table 1-1) | slot 3, `0x5000_0000`; AFX register `0x6E00_0000` (QEMU) | `ts_tcx.vhd`: TCX or CG3 (OSD), **8-bit only, 1024×768@60 fixed** (`ts_tcx.vhd:99`, `161`), stippler/blitter acceleration (`TCX_ACCEL=1`), no hardware-cursor registers found | partial |
| Audio | CS4231 codec with APC DMA ("SUNW,CS4231" in `ss5.bin`) | slot 4, `0x6C00_0000` | `ts_cs4231a.vhd`: CS4231 registers plus APC playback DMA, µ-law, A-law and linear formats; **capture not implemented** (`ts_cs4231a.vhd:896`); decode covers `0x6C00_0000-0x6FFF_FFFF` (`ts_decode.vhd:60`), which also swallows the AFX register at `0x6E00_0000` | partial |
| Power management (APC idle) | `power-management` node | `0x6A00_0000` (QEMU `apc_base`) | not decoded | no |
| Boot PROM | 256 KiB OBP; boot fetch forces `PA[30:28]=7` (MS2 UM Table 40) | `0x7000_0000` | ROM decoded at `0xF…`/`0xB…` instead (`ts_decode.vhd:79-81`), then remapped to DDR3 (OBRAM, `ts_core.vhd:1292-1294`); nothing at `0x7000_0000` | differs (matters only for the real OBP) |
| Keyboard/mouse ESCC | Z85C30 channel A keyboard, B mouse, 1200 baud | `0x7100_0000` | `ts_sport.vhd`, fed by the PS/2 emulation `ts_ps2sun.vhd` (`ts_io.vhd:480-557`) | yes (key coverage in §6) |
| Serial ESCC | Z85C30, ports A and B | `0x7110_0000` | `ts_sport.vhd`. A goes to the MiSTer UART, shared with the debug link through `ts_aciamux` (`ss_core.vhd:805-806`). B is instantiated but `rxd4`/`txd4` are never connected (`ss_core.vhd:170-171`) | partial |
| NVRAM/TOD | Mostek 48T08, 8 KiB, IDPROM at `+0x1FD8` (Sun-4M §9.3) | `0x7120_0000` | `ts_rtc.vhd` plus the 8 KiB block RAM `iram_rtc.vhd`; TOD seeded from the MiSTer RTC (`ss_core.vhd:831-855`); **not persistent** | partial |
| Floppy | 82077, level 11 ("SUNW,fdtwo" in `ss5.bin`; QEMU `fd_base`) | `0x7140_0000` | not decoded (`ts_decode.vhd:88` comment only); OpenBIOS creates no node | no |
| Diagnostic LED register | (sun4m "Diagnostic LEDs") | `0x7160_0000` | selected (`ts_decode.vhd:98`) but nothing handles it: writes dropped, reads `BADACCE5` | stub |
| Slavio configuration register | "slavioconfig" (`ss5.bin`; OpenBIOS node) | `0x7180_0000` | not decoded (`ts_decode.vhd:90,102-108` comments) | no |
| AUX1 register | LED, floppy density, terminal count, eject (Sun-4M §9.8) | `0x7190_0000` | **reused as the core's private configuration block**: SWCONF, HWCONF, I²C, MDIO, VGA control, mask rev, tick counter, SD registers (`ts_dmaux.vhd:35-81`, `247-323`). Only the LED bit keeps its Sun meaning (`ts_dmaux.vhd:247-250`), and it is not routed to any MiSTer LED | differs |
| AUX2 / power-off | `power` node | `0x7191_0000` | aliases AUX1 register 0, because `ts_dmaux` decodes only `a[4:2]`: a power-off write just rewrites the LED bit | no |
| `0x71A0_0000` | (not an SS5 device) | — | decoded as `auxio1`; acknowledged but routed nowhere, reads `BADACCE5` (`ts_io.vhd:733-760`) | stub (harmless) |
| Counter/timers | per-CPU counter or user timer, plus the level-10 system limit (Sun-4M §3.2.2.2) | `0x71D0_0000` | `ts_timer.vhd` | yes |
| Interrupt controller | sun4m pending, mask and target registers | `0x71E0_0000` | `ts_inter.vhd`. Sources wired: timers, SCSI, Ethernet, serial, keyboard/mouse, and video with audio on SBus level 5. Floppy, module-error and ECC bits are tied to 0 (`ts_inter.vhd:131-146`) | yes |
| System control/status | soft reset, reset reason | `0x71F0_0000` | a write of bit 0 resets the machine (`ts_io.vhd:232`, `ss_core.vhd:1019-1024`); reads return `BADACCE5` | partial |
| MACIO ID register | (QEMU `idreg_base`, 4 bytes) | `0x7800_0000` | not decoded | no |
| DMA2 | ESP channel (D_CSR, D_ADDR, D_BCNT, D_NADDR), LANCE channel (E_CSR, E_TST_CSR, E_VLD, E_BASE), parallel channel (P_CSR, P_ADDR, P_BCNT); all POST-tested (SS5 service manual §3.5) | `0x7840_0000` | `ts_dmaux.vhd`: D_CSR, D_ADDR, E_CSR, E_BASE_ADDR. D_BCNT and D_TEST are comments only (`ts_dmaux.vhd:218-220`). The P_* registers are absent | partial |
| SCSI | ESP 53C9x (FAS100A class) | `0x7880_0000` | `ts_esp.vhd`. Targets: image 0, image 1 or Direct SD at IDs 0/1, CD-ROM at ID 6 (`ss_core.vhd:408,447,471,496`) | yes (fidelity is phase 4.5) |
| Ethernet | LANCE Am7990, AUI plus TPE ("AUI network", "TPE" strings in `ss5.bin`) | `0x78C0_0000` | `ts_lance.vhd` (generated from `ts_lance.vhs`) plus the RMII MAC `ts_lance_mac_rmii_norxen.vhd`. **Reaches the wire only through an external RMII PHY on USER_IO** (§8) | partial; unusable without extra hardware |
| Parallel port | BPP ("SUNW,bpp" in `ss5.bin`; POST "PPORT Registers Tests") | `0x7C80_0000` (slot 5, offset `0x0C80_0000`, by analogy with SS20's `0xE_F480_0000`) (unverified) | not decoded; the OpenBIOS node is commented out | no |

---

## 5. SPARCstation 20 inventory

A real SS20 is an MBus machine. Up to two MBus modules carry the CPUs, the
SMC/EMC memory controller does ECC, the MSBI bridges MBus to SBus and holds
the IOMMU, and on the SBus side sit four card slots, the MACIO (DMA2, LANCE,
fast SCSI and parallel), the DBRI audio/ISDN chip, and the SEC (SBus to EBus:
two 85C30s, the 82077, the EEPROM, the NVRAM/TOD and the LEDs). Source: SS20
field service manual, Appendix B, Figure B-1. SBus slot *n* sits at
`0xE_n000_0000`.

| Block | Real SS20 (source) | Physical address | Core today | Status |
|---|---|---|---|---|
| CPU modules | Up to 2 MBus modules at 40/50 MHz MBus (FSM App. B), each with SuperSPARC or SuperSPARC-II, with or without the MXCC E-cache controller (TMS390Z55, Sun-4M B.III), or Ross HyperSPARC ("Ross" tests in the SS20 ROM); up to 4 CPUs (QEMU `max_cpus = 4`) | module control space `0xF_F8xx…0xF_FFxx` (Sun-4M §3.2.2.2); MXCC through ASI `0x02` | 3 × SuperSPARC-like at 50 MHz with MESI write-back (`ss.sv:370-372`; `ts_core.vhd:663-1084`). **No MXCC**: ASI `0x02` is unassigned (`asi_pack.vhd:21`). No HyperSPARC. CPU count is compile-time. SMP reportedly needs the ARM debug monitor (README) | partial |
| Memory controller | SMC/EMC with 144-bit ECC data path (FSM App. B "DSIMM"); registers at `0xF_0000_0000` (Sun-4M §3.2.2.1); "eccmemctl" node and "EMC/SMC MBus Timeout Tests" in the SS20 ROM | `0xF_0000_0000` | not decoded (`ts_decode.vhd:115-162`); no ECC | no |
| DSIMMs | 8 slots, 16/32/64 MB each, 512 MB maximum (FSM App. B) | `0x0_0000_0000…` | 464 MiB of DDR3 (`ss_core.vhd:156`); the remaining 48 MiB of the 512 MiB window holds OpenBIOS, TCX VRAM and the scaler buffers | partial (−48 MiB) |
| VSIMM, AVB, SX | up to two VSIMMs (4 or 8 MB VRAM with MDI, VBC and DAC) for 13W3 video; SX pixel processor ("SUNW,sx" in the ROM); NVSIMM (Prestoserve) | SX at `0xF_8000_0000`, VSIMM registers per QEMU `vsimm[]` | none | no |
| MSBI / IOMMU | IOMMU, base, control, arbiter enable, M-to-S async fault status and address (FSM App. B) | `0xF_E000_0000` | `ts_iommu.vhd`, same coverage as on SS5; IMPL/VER reads `0x04` (QEMU uses `0x13` for SS-20) (`cpu_conf_pack.vhd:148`) | partial |
| SBus card slots | 4 slots, 25 MHz (FSM Table 1-2) | `0xE_0000_0000`… | none; graphics sits in slot 2 (below) | no (by design) |
| Graphics | none on the board: SBus cards (TurboGX/cgsix and others) or VSIMM plus SX | card-dependent | TCX or CG3, 8-bit, 1024×768, placed as if it were a card in slot 2 (`ts_decode.vhd:121`). TCX was never an SS20 option (unverified), but QEMU uses the same placement | differs, works |
| MACIO: DMA2 | as on SS5 | `0xE_F040_0000` | `ts_dmaux.vhd`, same coverage as on SS5 | partial |
| MACIO: SCSI | fast SCSI | `0xE_F080_0000` | `ts_esp.vhd` | yes |
| MACIO: Ethernet | LANCE, AUI plus TPE | `0xE_F0C0_0000` | as on SS5 (RMII only) | partial |
| MACIO: parallel | BPP (Sun-4M A.II.6.3.1) | `0xE_F480_0000` | not decoded | no |
| Audio | DBRI (ISDN plus CHI) with the on-board codec on CHI; four audio jacks (FSM Figure B-1 "DBRI", "Audio on board"; the codec being a CS4215 is unverified); SS10-era SpeakerBox on CHI (Sun-4M A.II.6.4.1) | `0xE_E001_0000` (QEMU `dbri_base + 0x10000`); the SS10 had it at `0xE_F801_0000` (Sun-4M A.II.6.4.2) | **none.** The CS4231 is still synthesised (`ts_io.vhd:711-725`), but the SS20 branch of the decoder never drives `sel.audio` (`ts_decode.vhd:115-162`), so it is unreachable, and OpenBIOS creates no audio node | **no audio at all** |
| Boot PROM | 512 KiB OBP 2.25 | `0xF_F000_0000` | decoded (`ts_decode.vhd:142-145`, also aliased at `0xB_F000_0000`), holds OpenBIOS from DDR3 | yes |
| Keyboard/mouse, serial | 2 × 85C30 (FSM App. B "SEC") | `0xF_F100_0000`, `0xF_F110_0000` | as on SS5 | yes / partial |
| NVRAM/TOD | MK48T08 | `0xF_F120_0000` | as on SS5, not persistent | partial |
| Counters, interrupts | per-CPU plus system | `0xF_F130_0000`, `0xF_F140_0000` | `ts_timer.vhd`, `ts_inter.vhd` with 3 CPUs | yes |
| Audio/ISDN at `0xFF15` | "optional" in Sun-4M §3.2.2.2.1; not fitted on SS20 (unverified) | `0xF_F150_0000` | not decoded (comment at `ts_decode.vhd:153`) | n/a |
| Diagnostic LEDs | 12 LEDs, write-only (Sun-4M §5.4.1) | `0xF_F160_0000` | selected, nothing behind it (`ts_decode.vhd:154`) | stub |
| Floppy | 82077 ("Floppy 82077A Tests", "U0602 (FDC_82077)" in the SS20 ROM) | `0xF_F170_0000` | not decoded (`ts_decode.vhd:155` comment) | no |
| AUX1 | LED and floppy bits (Sun-4M §9.8) | `0xF_F180_0000` | the core's private configuration block, as on SS5 | differs |
| AUX2 / power-off | `power` node | `0xF_F1A0_1000` | decoded as `auxio1`; writes dropped, reads `BADACCE5` | stub |
| System control/status | as on SS5 | `0xF_F1F0_0000` | soft reset on write, no read-back | partial |
| MACIO ID register | (QEMU `idreg_base`) | `0xE_F000_0000` | not decoded | no |

---

## 6. MiSTer integration inventory

These are not blocks of the real machine. They are what a MiSTer user touches
instead of the hardware: disks, keyboard, video out, persistence.

| Area | Core today | Gap |
|---|---|---|
| Disk images | 3 VDs: HD, HD2, CDROM (`ss.sv:213-217`, `VDNUM=3` at `ss.sv:269`); SCSI configuration "Image / Direct SD / Image+Image / SD+Image / Image+SD" | fixed SCSI IDs (0/1 for disks, 6 for the CD) |
| Runtime mount and unmount | a mount latches the size and sets `imgN_mounted` for good; nothing ever clears it (`ss_core.vhd:514-528`). The SCSI target microcode declares `hd_mounted` but never reads it (`scsi_mist.vhd`, `scsi_mist_cdrom.vhd`: one occurrence each, the port) | no "medium not present", no UNIT ATTENTION after a swap, no eject. Swapping the CD mid-install is invisible to the OS |
| CD-ROM formats | raw ISO, 2048- or 512-byte sectors (OSD `O45`, `ss_core.vhd:492`); no READ TOC (corrected after [design/scsi-hps.md](design/scsi-hps.md) §3.5: the CD target's microcode has no opcode 0x43) | no BIN/CUE, no CHD, no CD audio (the real CD audio went by cable into the codec) |
| Direct SD | `scsi_sd` drives the SDIO pins itself (`ss.sv:404-406`, `ss_core.vhd:388-417`) and treats the whole secondary SD card as one raw SCSI disk | unusual on MiSTer. It writes raw sectors to whatever card sits in the slot. Keep it as an expert option and document it |
| NVRAM | 8 KiB block RAM, initialised from the bitstream (`iram_rtc.vhd`); survives a core reset, lost when the core is reloaded | not saved to the SD card, so OBP/OpenBIOS variables and Solaris `eeprom` settings are lost |
| RTC | seeded from the MiSTer RTC, with the year rebased to 1968 (`ss_core.vhd:831-855`) | none (done in `630d68e`) |
| Keyboard | PS/2 to Sun Type-5 with 4 layouts, US/FR/DE/ES (`ss.sv:336-338`); Win keys map to the ◊ keys, Menu to Compose (`ts_ps2sun.vhd:355-371`) | **no Stop (L1) key and no Again/Props/Undo/Front/Copy/Open/Paste/Find/Cut/Help.** No table entry produces Sun codes `0x01`, `0x03`, `0x19`, `0x1A`, `0x31`, `0x33`, `0x48`, `0x49`, `0x5F`, `0x61` or `0x76`, and the PS/2 Pause (`E1`) prefix is ignored (`ts_ps2sun.vhd:292,582`). So **Stop-A cannot be typed.** Keyboard LEDs are not passed through (`ss_core.vhd:819-820`) |
| Mouse | PS/2 to Sun 3-button mouse (`ts_ps2sun.vhd`) | fine |
| Serial | port A goes to the HPS UART (`/dev/ttyS1`), shared with the ARM debug monitor (`tools/debugarm/lib.h:14`) | CONF_STR has no `UART` declaration (first entry is `"SparcStation;;"`, `ss.sv:211`), so Main offers none of its UART modes (PPP, modem, console). Main enables them only when the core declares `UART…` (Main `user_io.cpp:754`, `1722`). Port B goes nowhere |
| Video, native | 1024×768@60 at 65 MHz (`ss_core.vhd:780-781`), always through the scaler (`VGA_SCALER=1`, `ss.sv:179`) | a single mode; see the resolution gap in §7 |
| Video, "Scaler framebuffer" | `FB_EN` from the OSD, 8 bpp, 1024×768, `FB_BASE = 0x3E40_0000` (`ss.sv:187-192`) | **suspected broken, from reading the code, not tested.** By the address mapping in `ss_core.vhd:698-699`, TCX VRAM at core `0x1D40_0000` lands at DDR3 `0x22B0_0000`, while DDR3 `0x3E40_0000` is core RAM `0x01B0_0000`. On top of that, `MISTER_FB_PALETTE` is commented out (`ss5.qsf:59`, `ss20.qsf:53`), so the `FB_PAL_*` outputs are not connected (`sys/sys_top.v:1603-1608`) and 8 bpp mode would use the wrong palette |
| Audio out | 16-bit signed stereo from the CS4231, SS5 only | none on SS20 |
| RAM | SS5 256 MiB (the real maximum); SS20 464 MiB (the real maximum is 512 MiB) | SS20 is 48 MiB short, and RAM size cannot be chosen |
| CPU count (SS20) | 3, compile-time | cannot be reduced for OSes that do not like SMP |
| Ethernet | "Ethernet PHY present" only enables the USER_IO output drivers (`ss.sv:497-500`); the LANCE is always present | see §8 |

---

## 7. Prioritised gap table

This is one table for both machines, sorted by priority. Within a priority,
the order is the suggested order of work. "Who needs it" names the OS, PROM or
user feature that breaks or goes missing without it.

| # | Gap | Real HW | Core today (file refs) | Who needs it | Pri | Effort | Notes |
|---|---|---|---|---|---|---|---|
| 1 | **Ethernet without extra hardware (HPS bridge)** | LANCE on AUI/TPE, 10 Mbit | LANCE model plus RMII MAC, only through a LAN8720-type PHY wired to USER_IO (`ss.sv:487-500`, `ss_core.vhd:793-801`, `ts_io.vhd:417-460`); no CRS_DV and no MDIO on the 7-pin port | Every OS, for NFS, FTP/HTTP, telnet/ssh, remote X11, package installs, and file exchange without re-imaging the SD card. An ordinary MiSTer has no PHY board, so today it has **no network** | **P0** | L (FPGA M, Main M, OpenBIOS S) | Design in §8. Keep RMII as an option. Upstream Main already has an Am7990 bridge for Minimig's A2065 (`support/minimig/minimig_a2065_ethernet.cpp`, PR #1247) whose Linux side can be reused |
| 2 | Unique MAC address and hostid per unit | unique IDPROM per machine | hard-coded `08:00:20:12:34:56` in OpenBIOS (`obio.c:269`, `305-320`); hostid follows from it | Two MiSTers on one LAN get the same MAC (ARP breaks); hostid-locked software | P1 | S | Ship with #1: Main derives the MAC (§8.4), the core exposes it, and OpenBIOS uses it |
| 3 | Serial port A through Main's UART modes | ttya | wired to the HPS UART, but CONF_STR lacks a `UART` declaration (`ss.sv:211`) | Serial console for headless use; **PPP over serial as a stopgap network** before #1 (SunOS, Solaris, NetBSD, Linux all ship PPP); modem emulation | P1 | S | Add e.g. `"SparcStation;UART115200;"`. Check the interaction with the `debugarm` link, which shares the line through `ts_aciamux` |
| 4 | Stop-A and the Sun-only keys | Type-5 keyboard: Stop, Again … Cut, Help | no PS/2 key maps to Sun codes `0x01` … `0x76`; Pause is ignored (`ts_ps2sun.vhd`, §6) | L1-A to break into the `ok` prompt (sync, `boot -s`, hung OS); OpenWindows/CDE Copy/Paste/Front/Open | P1 | S | Proposal: Pause → Stop, F13-style or Scroll-Lock chords for L2-L10, plus an OSD "Send Stop-A" entry |
| 5 | NVRAM persistence to SD | battery-backed MK48T08 | block RAM only, lost on core reload (`iram_rtc.vhd`, `ts_rtc.vhd:282`) | `boot-device`, `auto-boot?`, `diag-switch?`, the OpenBIOS reboot-args scratch (fork commit `6f3c0b7`), Solaris `eeprom` | P1 | M | Options: a fourth VD auto-mounted to `games/<core>/nvram.bin`, or the Template `ioctl_upload` path after phase 3. Keep the IDPROM region under firmware control |
| 6 | CD-ROM media change | removable medium | mount latched forever, `hd_mounted` unused (§6) | Multi-CD installs (Solaris 2.x "Software 1 of 2 / 2 of 2", NetBSD sets), eject | P1 | M | Edit `scsi_mist_cdrom.vhs` (not the generated `.vhd`): NOT READY with no image, UNIT ATTENTION `28h` after a swap, START STOP eject, clear the mount on unmount |
| 7 | SS20 SMP without the ARM debug monitor | OBP starts the secondary CPUs | NCPUS=3, but README says `tools/debugarm` is needed to activate SMP | Multiprocessor Solaris, NetBSD MP on a stock MiSTer (Main does not run `debugarm`) | P1 | L | Phase 4.2 owns the root cause. Listed here because it is the SS20's headline feature |
| 8 | "Scaler framebuffer" video mode | n/a | `FB_BASE` does not match where TCX VRAM lands (by arithmetic); palette macro off (§6) | Anyone who picks OSD "Video: Scaler framebuffer" | P1 if confirmed | S | Verify on hardware first. Fix `FB_BASE` or the remap, enable `MISTER_FB_PALETTE`, and feed `FB_PAL_*` from the TCX/CG3 DAC (the ports exist, `ss_core.vhd:322-325`) |
| 9 | Video resolutions | S24 did 1152×900 and 1024×768 (unverified); CG3 is natively 1152×900; Sun's usual default is 1152×900; cgsix up to 1280×1024 (unverified) | 1024×768@60 only (`ts_tcx.vhd:99`); `vid_pack.vhd` already has 1152×864 and 1280×1024 modelines | Desktop real estate, apps and window layouts that assume 1152×900 | P2 | M | Needs pixel clocks beyond the current PLL outputs (65/80/40 MHz, `ss_core.vhd:881-888`), a VRAM stride and OpenBIOS width/height |
| 10 | SS20 audio | DBRI plus on-board codec (§5) | none: CS4231 synthesised but not decoded on SS20 (`ts_decode.vhd:115-162`); no OpenBIOS node | Any SS20 OS that plays sound | P2 | S-M (CS4231 route) / XL (DBRI) | Cheap route: decode the existing CS4231 plus APC at an SS20 SBus address and add the node to OpenBIOS `sbus_probe_slot_ss10`. Not period-accurate, but Solaris `audiocs` and NetBSD `audiocs` bind by node name (unverified for SS20). A real DBRI model is item 30 |
| 11 | Runtime CPU count (SS20) | 1-4 CPUs by module choice | compile-time `NCPUS=3` (`ss.sv:372`), reported through `SYSCONF` (`ts_core.vhd:193-196`) | UP-only or SMP-shy OSes (README: Linux "hardly ever supported multicore"), and A/B debugging | P2 | M | Gate CPUs 1-2 in reset and report the OSD count through SYSCONF; OpenBIOS already reads it |
| 12 | SCSI target IDs selectable | any ID 0-6; Sun's internal disk is target 3 | disks at 0/1, CD at 6, fixed (`ss_core.vhd:408,447,471,496`) | Disk images from real machines or QEMU installed at `c0t3d0`: `/etc/vfstab` and `boot-device` point at t3, so a disk at t0 fails to mount root | P2 | S | OSD ID per VD. Also document which OS numbering results |
| 13 | Bus time-out on unmapped addresses | data-access exception, AFSR/AFAR set | read returns `0xBADACCE5` with ack (`ts_io.vhd:760,790`) | Real OBP POST ("SBus/EBus Read Time-out Test"); OS and firmware probes of optional devices; debugging (garbage instead of a fault) | P2 | M | Needs an error path from `io_r` into the MMU fault logic. Check nothing relies on the silent ack first (for example the stubbed regions in items 26-27) |
| 14 | 24-bit TCX (S24) | 8-bit plus 24-bit planes | 8-bit only (`ts_tcx.vhd:161`) | 24-bit desktops on Solaris/CDE and NetBSD `tcx` (unverified per OS) | P2 | L | 1024×768×32 is 3 MiB of VRAM; the DDR3 window has room |
| 15 | cgsix (TurboGX/GX+) | the most common Sun SBus framebuffer | none | Best-supported accelerated X on Sun OSes (Solaris, SunOS 4, NetBSD/OpenBSD, Linux fbdev) (unverified per OS); SunOS 4 may lack TCX support (unverified). CG3 already covers unaccelerated 8-bit | P2 | XL | New model (FBC/TEC/THC/DAC) plus an OpenBIOS node or FCode. FPGA space on SS20 is the main risk (open question 5) |
| 16 | Real Sun OBP boots on the core | — | pieces missing: PROM at `0x7000_0000` on SS5 (`ts_decode.vhd:79-81` vs MS2 UM Table 40), FCode PROMs in the TCX/CG3 slot, ECC registers (#27), floppy (#20), AUXIO semantics (#23), time-outs (#13), DMA2 D_BCNT/P_* (#24), MXCC (#28) | POST as a hardware test oracle (phase 1g); users who want the real `ok` prompt | P2 | XL (aggregate) | Owned by phase 4.3; listed so each piece has a row |
| 17 | Ethernet MAC details: PROM mode, LADRF, RX chaining | Am7990 | the RMII MAC filters on own-address or group bit only, ignoring LADRF and PROM (`ts_lance_mac_rmii_norxen.vhd:368-369`); `crcok` forced to 1 (`:470`); RX FIFO wraps silently (`:449`); the LANCE model assumes no RX chaining (`ts_lance.vhs:16`) | tcpdump/snoop, bridging in the guest, drivers with small RX buffers | P3 | S-M | Partly solved by #1 (whole-frame buffering removes the overrun). PROM needs the mode bit in `type_mac_rec_w` (`ts_pack.vhd:63-68`) |
| 18 | Serial port B | ttyb | ACIA built, pins unconnected (`ss_core.vhd:170-171`) | a second console or modem line | P3 | S | MiSTer has one HPS UART: OSD choice of A or B, or a Main-side pty |
| 19 | Keyboard layouts and LEDs | Type-5 in about 20 layouts | 4 layouts; LEDs not forwarded (`ss_core.vhd:819-820`) | UK, IT, SE, JP … users; Caps Lock feedback | P3 | S | |
| 20 | Floppy 82077 | 1.44 MB 3.5" | absent; OpenBIOS `fd_offset=-1` (`openbios.c:64,89`) | Solaris driver-update disks, SunOS/Solaris `fd`, the real OBP's floppy POST | P3 | L | Also needs the AUX1 floppy bits (#23), level-11 interrupt bit (`ts_inter.vhd:136`), an OSD floppy image and an OpenBIOS node |
| 21 | Parallel port BPP | DMA2 P_* plus BPP registers | absent; node commented out (`sbus.c:278`) | printing; the real OBP's "PPORT Registers Tests" | P3 | M | |
| 22 | Power-off and the diagnostic LED | AUX2 power-off; front LED via AUX1 bit 0; 12-LED register on SS20 | power-off write is a no-op or LED alias (§4, §5); AUX1 LED latched but not routed; LED register stubbed (`ts_decode.vhd:98,154`) | `poweroff`, `shutdown -p`, `halt` UX; activity feedback | P3 | S | Power-off could blank video or return to a reset state; route the LED to `LED_USER` |
| 23 | AUX1 register semantics | LED, floppy density, terminal count, eject, disk change (Sun-4M §9.8) | replaced by the private configuration block (`ts_dmaux.vhd:35-81`) | the real OBP and OS floppy drivers read these bits | P3 | S-M | Move the private block elsewhere (for example an unused `0x71B`/`0xFF1B` page) in step with OpenBIOS |
| 24 | DMA2 register completeness | D_BCNT, D_TEST, E_TST_CSR, E_VLD, P_* | missing (`ts_dmaux.vhd:218-220`) | the real OBP's DMA2 POST; drivers that read back D_BCNT (unverified) | P3 | S | |
| 25 | IOMMU fault reporting and IDs | AFSR/AFAR, arbiter, slot configuration, IOPTE V/W checks | not decoded or ignored (`ts_iommu.vhd` header, `186-225`); IMPL/VER `0x04` in both builds | DVMA error handling, the real OBP's "IOMMU SBUS Config Regs Test", OS CPU/IOMMU detection (verify the IDs in phase 1e) | P3 | S-M | |
| 26 | Slavio misc registers | configuration register `0x7180_0000`, system status read-back, APC idle `0x6A00_0000`, MACIO ID `0x7800_0000`/`0xE_F000_0000`, AFX register `0x6E00_0000` | not decoded, or aliased into the audio window (§4) | OpenBIOS `slavioconfig` node, Solaris idle power management, the real OBP | P3 | S | Mostly read-as-zero or read-back stubs |
| 27 | SS20 ECC memory controller registers | EMC/SMC at `0xF_0000_0000` | not decoded | the real SS20 OBP ("eccmemctl", "EMC/SMC MBus Timeout Tests"); Solaris memory-error reporting (unverified) | P3 (P2 if the real OBP is targeted) | S-M | No ECC is needed; a register model is enough (QEMU `eccmemctl.c` is the reference) |
| 28 | MXCC / E-cache, 4th CPU, HyperSPARC, TurboSPARC | SS20 modules with MXCC, dual-CPU modules, HyperSPARC; SS5-170 TurboSPARC | none (`asi_pack.vhd:21`; `NCPUS` limited by the FPGA) | OS paths for those modules; the real OBP's MXCC tests | P3 | L-XL each | Cacheless SuperSPARC is a genuine module configuration (unverified which Sun modules), so the current choice is legitimate |
| 29 | SS20 RAM to 512 MiB, selectable RAM size | 512 MB maximum | 464 MiB fixed (`ss_core.vhd:156`) | memory-hungry workloads; old OSes that dislike large memory (unverified) | P3 | S-M | Freeing 48 MiB means moving OpenBIOS/TCX VRAM, perhaps into the unused SDRAM (`ss.sv:175`) |
| 30 | DBRI, ISDN, SpeakerBox (period-accurate SS20 audio) | DBRI T5900FC | none | Solaris `dbri`, NetBSD `dbri`, Linux `snd-sun-dbri` (unverified); ISDN has no MiSTer use | P3 | XL | Prefer #10's CS4231 route unless accuracy is the goal |
| 31 | VSIMM, SX, AVB, NVSIMM | SS20 memory-bus graphics and Prestoserve | none | Solaris SX/VSIMM desktops | P3 | XL | |
| 32 | CD-ROM formats and CD audio | real CDs | ISO only | multi-track images; CD audio | P3 | M | |
| 33 | Audio capture | CS4231 record | playback only (`ts_cs4231a.vhd:896`) | recording apps | P3 | M | |
| 34 | Direct SD safety | n/a | raw writes to the secondary SD card (`ss_core.vhd:388-417`) | expert users only | P3 | S | Document it; consider a read-only default |

**Outside this table, but still blocking:** the licence (REWORK.md phase 0)
blocks MiSTer-devel distribution more than any hardware gap does.

**The agreed P0/P1 list** (REWORK.md phase 2 "done when" needs the user to
confirm): #1 HPS Ethernet (P0), then #2 unique MAC/hostid, #3 UART
declaration, #4 Stop-A, #5 NVRAM persistence, #6 CD media change, #7 SMP
without debugarm, and #8 the scaler framebuffer (if confirmed). #3 and #4 are
small and can go first.

---

## 8. Ethernet: HPS bridge design sketch

### 8.1 What exists today, and where the seam is

The Ethernet path is split cleanly into a **chip model** and a **MAC**:

| Layer | File | What it does |
|---|---|---|
| DMA2 Ethernet channel | `ts_dmaux.vhd:228-243` | E_CSR (INT_EN, RESET, device ID `1010`), E_BASE_ADDR high byte; interrupt gating at `ts_io.vhd:462` |
| LANCE chip model | `ts_lance.vhd`, generated from `ts_lance.vhs` by `asm_lance.rb` | RAP/RDP, CSR0-3, init block, TX and RX descriptor ring walking, DVMA as a plomb bus master through `plomb_mux` and the IOMMU (`ts_io.vhd:341-360`), interrupts. Assumptions stated in the source: no RX chaining, full duplex, no collisions or retries, 16-bit buffer alignment (`ts_lance.vhs:15-24`) |
| MAC boundary | `ts_pack.vhd:46-77` | four records. `type_mac_emi_w` (TX word `d`, `push`, `stp`, `enp`, byte `len`, `crcgen`, `clr`) and `type_mac_emi_r` (`fifordy`, `busy`); `type_mac_rec_w` (`pop`, `padr`, `ladrf`, `clr`) and `type_mac_rec_r` (word `d`, `deof`, `fifordy`, `len`, `crcok`, `eof` pulse) |
| MAC, built | `ts_lance_mac_rmii_norxen.vhd` (entity `ts_lance_mac`, architecture `rmii_norxen`) | RMII at a forced 100 Mbit (`:211`, `:260`). Frame start is found from the preamble, because USER_IO has no CRS_DV pin (`ss_core.vhd:799-801` ties `rx_dv`/`crs` to 0). CRC generation; address filter; 128-word TX and RX FIFOs in two clock domains. TX starts after 64 words or the whole frame (`:715`); `fifordy` is forced to 1 when no PHY clock is seen (`:707`) |
| MAC, alternatives in the tree | `ts_lance_mac_rmii.vhd` (uses CRS_DV), `ts_lance_mac_void.vhd` (stub) | not in `files.qip` |
| Board wiring | `ss.sv:487-500`, `ss_core.vhd:793-801` | USER_IO 0 RX1, 1 RX0, 2 REF_CLK (from the PHY), 3 TXEN, 4 TX1, 5 TX0; outputs enabled only when OSD "Ethernet PHY present" = YES (`ss.sv:497`); no MDIO, no PHY reset or interrupt |

**The handshake the LANCE model relies on** (`ts_lance.vhs:653-665`,
`846-876`, `900-912`, `988-1004`):

- **TX.** The LANCE starts a frame only when `mac_emi_r.busy = 0`. It pushes
  16-bit words while `fifordy = 1`, and treats the frame as sent once `busy`
  falls again.
- **RX.** The LANCE starts a receive when `fifordy` is high or it has latched
  an `eof` pulse. It pops words until `deof`, then writes the RMD with
  `mac_rec_r.len` as MCNT. MCNT *includes* the 4 FCS bytes
  (`ts_lance.vhs:80`). `len` is sampled asynchronously, so it must stay stable
  until the RMD is written.

**The seam is therefore the four MAC records.** An HPS bridge replaces only
the MAC and leaves the LANCE model, its DMA and its descriptor handling alone.

### 8.2 Why not the A2065 or Quadra split

The two existing MiSTer bridges put more of the chip on the ARM:

- **A2065 (Minimig, upstream Main).** The whole Am7990 model runs on the ARM.
  That works because the A2065's LANCE only ever DMAs into its own 32 KiB
  board RAM, and that RAM is placed in DDR3 where both sides can reach it
  (`minimig_a2065_ddr3.h`).
- **Quadra 800 SONIC (Main fork).** The chip model runs on the ARM, and the
  FPGA keeps the register file, the ISR, and a DMA engine into guest RAM
  (`MacQuadra800_MiSTer/docs/ethernet.md`, `rtl/sonic_mbx.sv`).

On the SPARCstation the LANCE DMAs into main memory through the IOMMU, and a
working FPGA model of it already exists. Moving it to the ARM would mean
rebuilding DVMA translation and a bus-master engine for nothing.

**Recommendation: a frame-level bridge.** The FPGA keeps the chip; the ARM
only moves whole frames between a DDR3 mailbox and Linux. This is the
smallest Main-side change of the three, and the guest never waits on
software for a register access.

### 8.3 FPGA side

1. **Export the MAC records to the board level.** Today `ts_io` instantiates
   the MAC (`ts_io.vhd:439-458`). Pass the four records out through `ts_io` and
   `ts_core` ports, and instantiate MACs in `ss_core.vhd`, which is
   board-specific and already owns both DDR3 ports.
2. **Add a new entity `ts_lance_mac_hps`** with the same four records, plus a
   64-bit DDR3 master port (`mem_addr`, `mem_rd`, `mem_we`, `mem_wdata`,
   `mem_be`, `mem_busy`, `mem_rdata`, `mem_rvalid`) and `ena`, `present`,
   `mac_addr`. Everything runs in `clk_sys`; there is no PHY clock domain.
   - **TX.** Collect pushed words into a 2 KiB block RAM from `stp` to `enp`.
     If `crcgen = 0` the guest supplied its own FCS; strip the last 4 bytes,
     because Linux adds its own. Burst the frame into the next TX ring slot,
     write the slot's length word *last*, then advance `TX_WPTR`. The "status
     word last" ordering is the one the Quadra doc calls the MacLC card's
     ordering law. Hold `busy` from `stp` until the slot is published. If the
     ring is full, keep `busy` high: backpressure, never loss.
   - **RX.** While idle, poll `RX_WPTR` every few µs (one 64-bit read). When a
     slot is waiting, read it into a 2 KiB block RAM. Pad to 60 bytes if
     shorter, and append a real FCS; the CRC function in the RMII MAC can be
     reused, and MCNT must include it. Apply the address filter: own address,
     broadcast, LADRF multicast hash, and PROM if the mode bit is exported
     (#17). Then present the frame. Raise `fifordy` because the whole frame is
     buffered, serve `d`/`deof` per `pop`, pulse `eof` after the last word,
     and hold `len` until the next frame starts. Advance `RX_RPTR` once the
     LANCE has consumed the frame. Because the frame is fully buffered, the
     FPGA side can never overrun; the RMII MAC's FIFO wraps silently. A guest
     with no free descriptor simply leaves frames in the DDR3 ring.
   - **Presence.** Active only when the OSD selects HPS and the Main MAGIC word
     has been seen since reset, following the Quadra's rule. Otherwise behave
     like the void MAC (`fifordy = 1`, `busy = 0`), so TX never hangs.
3. **DDR3 access.** Arbitrate the new master onto the **DDRAM (video) port**.
   It carries only TCX scan-out today (`ss_core.vhd:723-739`), about 65 MB/s
   of reads on a 64-bit port. The mailbox address path must bypass the
   `"001" & NOT …` transform (`ss_core.vhd:698-699`), because the window sits
   below `0x2000_0000`.
4. **Keep RMII.** Instantiate both MACs and mux the four records by an OSD
   choice latched in reset: Off, HPS, or RMII PHY (USER_IO). With Off, use
   the void behaviour. The cost is a few hundred ALMs plus 2-4 M10Ks
   (unverified until fitted).
5. **Tests.** A GHDL or nvc bench with a DDR3 model and a C model of the Main
   side, like the Quadra's `tb_sonic_mbx`: 1514-byte frames, back-to-back
   frames, ring full, `crcgen = 0` frames, runt padding, and reset during a
   transfer.

**Proposed DDR3 window.** This follows the A2065 and Quadra convention: ARM
physical `0x1FF0_0000`, Avalon word `0x03FE_0000`. Only one core runs at a
time, so reusing the region is safe. Sizes are a proposal to agree with the
Main side.

| Offset | Dir | Content |
|---|---|---|
| `+0x0000` | ARM→FPGA | `MAGIC` ("SSETH001"): the service is up |
| `+0x0008` | ARM→FPGA | `MAC` (6 bytes) plus valid bit |
| `+0x0010` | FPGA→ARM | `TX_WPTR`, free-running |
| `+0x0018` | ARM→FPGA | `TX_RPTR` |
| `+0x0020` | ARM→FPGA | `RX_WPTR` |
| `+0x0028` | FPGA→ARM | `RX_RPTR` |
| `+0x0030…` | FPGA→ARM | debug and stats: LANCE CSR0, frames each way, drops, ring-full stalls |
| `+0x1000` | FPGA→ARM | TX ring: 16 slots × 2 KiB (`{len, flags}` word, then up to 1536 bytes) |
| `+0x9000` | ARM→FPGA | RX ring: 32 slots × 2 KiB |

### 8.4 Main_MiSTer side

- **A new module, `support/sparc/sparc_eth.{cpp,h}`.** It maps the window with
  `shmem_map(0x1FF00000, …)` (as `minimig_a2065.cpp:578` does), writes `MAC`
  and then `MAGIC` at core start, and in the poll loop:
  - drains the TX ring into the socket;
  - moves received frames into the RX ring, dropping and counting them when
    the ring is full;
  - rewrites `/tmp/ss_eth_stats` every second;
  - can write a pcap, like the Quadra's `/tmp/mac_eth.pcap`.

  All of it is bounded and non-blocking, like `a2065_poll()`.
- **Reuse the Linux side.** `support/minimig/minimig_a2065_ethernet.cpp` is
  already upstream and has what is needed: an AF_PACKET raw socket, a cBPF
  filter for sharing `eth0`, a macvlan child, `tap0`, offload control, and
  dhcpcd deny. Better still, factor it into a shared `support/net/` used by
  minimig, the Mac fork and sparc, rather than copying it.
- **Interface choice.** An OSD option mirroring `A2065_STATUS_OPT`: Off,
  `eth0`, `eth1`, `macvlan`, `tap0`, plus RMII for the core-side mux.
  Unavailable modes fall back to Off, as `a2065_mode_available()` does.
  Wi-Fi-only boxes need `tap0` plus routing or NAT: a Wi-Fi station cannot
  send frames with a foreign source MAC (A2065 header; Quadra doc).
- **MAC derivation.** Sun OUI `08:00:20` plus the last three bytes of the
  MiSTer's own interface MAC. This is the Quadra rule with Apple's `08:00:07`
  replaced by Sun's, and it needs no configuration. The core exposes the
  value in a free word of the private configuration block (`ts_dmaux.vhd`
  `a[4:2]` = `010`/`011` are unused). OpenBIOS `obio.c:269`/`317` use it
  instead of `tacus_macaddr` when it is valid. That also makes the hostid
  unique (item #2).
- **Core detection.** Enable it by core name in `user_io.cpp`
  (`SparcStation`, or `SunSparcStation` after the phase 3 naming decision).
  It is off for every other core.

### 8.5 Risks and unknowns

- **Throughput** is bounded by Main's poll-loop period, not by the FPGA. A
  real LANCE does 10 Mbit/s, so a target of about 1 MB/s FTP is reasonable.
  Measure it; batching several frames per pass is the lever, as it is in the
  A2065 code's `rx_batching`.
- **LANCE-model edge cases.** These may surface once traffic is real: RX
  chaining is unsupported (`ts_lance.vhs:16`); MISS/BUFF are not reported
  when the guest has no free descriptor; and `len` is sampled asynchronously.
  Phase 4.5 should audit `ts_lance.vhs` alongside this work. Regenerate
  `ts_lance.vhd` with `asm_lance.rb`; never hand-edit it.
- **FPGA space.** SS20 with 3 CPUs is described as close to full (README "Up
  to 3 CPUs can fit").
- **Upstreaming.** A frame-mailbox service in Main is small and generic. It
  is a better upstream candidate than a chip model, and the same code could
  serve other cores with FPGA-side NICs.

---

## 9. Open questions for the user

1. **P0/P1 agreement.** Is the list at the end of §7 the right P0/P1 set?
   Should SMP without `debugarm` (#7) stay P1, or move behind the audio and
   resolution work?
2. **Main_MiSTer target.** Upstream Main (factor out a shared `support/net/`
   next to the A2065 code), or your Quadra fork's `mac_eth` personality
   scheme? The answer decides where `sparc_eth` lives and how the OSD
   interface choice is stored.
3. **Stopgap networking.** Ship the one-line CONF_STR `UART` change (#3) now,
   so PPP over serial works before the HPS bridge lands?
4. **SS20 audio.** Accept a non-period CS4231 on the SS20 (#10, cheap), or
   hold out for DBRI (#30, XL)?
5. **FPGA budget.** Do you have fit reports (ALM/M10K use) for the current
   `ss5` and `ss20` rbfs? cgsix, 24-bit TCX and a 4th CPU all depend on
   headroom, especially on SS20.
6. **Scaler framebuffer mode.** Have you seen OSD "Video: Scaler framebuffer"
   work? §6 suggests it shows the wrong memory with the wrong palette.
7. **Real Sun OBP as a goal.** Should the core aim to boot the real OBP
   (#16: PROM at `0x7000_0000` on SS5, the AUX1 semantics, bus time-outs,
   EMC registers, FCode PROMs), or stay OpenBIOS-only and use the ROM
   disassembly purely as documentation?
8. **Disk identity.** Should SCSI IDs be selectable per image (#12), and
   should the default HD move to target 3 to match real Sun machines? That
   default would change device names for existing users' installs.
9. **Floppy and parallel.** Any real use case (driver disks, printers), or
   leave them at P3?
10. **NVRAM file.** Where should NVRAM persist: one file per build
    (`games/<core>/nvram_ss5.bin`, `nvram_ss20.bin`) or one per HDD image?
    Should the IDPROM part stay firmware-owned, so the per-unit MAC always
    wins?
