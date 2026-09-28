# Implementation gaps: the sun4m chipset devices

Phase 4 of [REWORK.md](../REWORK.md), chipset part. The question is not which
devices are missing (phase 2, [HARDWARE_GAPS.md](../HARDWARE_GAPS.md)) but what
`rtl/sun4m/` implements incompletely or incorrectly, register by register:
the address decode and the unmapped-access behaviour (`ts_decode.vhd`,
`ts_io.vhd`, `ts_core.vhd`), the interrupt controller (`ts_inter.vhd`), the
counter/timers (`ts_timer.vhd`), the IOMMU and SBus controller
(`ts_iommu.vhd`), DMA2 and the AUX registers (`ts_dmaux.vhd`), the ESP
(`ts_esp.vhd`), the LANCE (`ts_lance.vhs` → `ts_lance.vhd`, plus the MAC
`ts_lance_mac_rmii_norxen.vhd`), the ESCCs (`ts_sport.vhd`) with the keyboard
and mouse emulation (`ts_ps2sun.vhd`, `ts_sunkb.vhd`), the NVRAM/TOD
(`ts_rtc.vhd`, `iram_rtc.vhd`) and the system control register. The CPU side
is [cpu.md](cpu.md); video, audio and the MiSTer glue are
[video-audio-glue.md](video-audio-glue.md). Where a defect has a CPU half and
a chipset half, both documents carry it under their own ID and point to each
other.

**Method.** Everything was read from source; no VHDL simulator is installed,
so nothing here was simulated. Statements marked *(inference)* are reasoned
from the code and need a simulation or a hardware check.

**Evidence.**
- Sun PROM analyses: [`ss5-obp/`](../rom-disassembly/ss5-obp/) (README,
  `post-tests.md`, `hardware-access.md`, `forth-dictionary.txt`,
  `device-tree.md`, `fcode-70011f00-espdma.txt`, `qemu-console.txt`) and
  [`ss20-obp-2.25/`](../rom-disassembly/ss20-obp-2.25/) (same set).
- Manuals in `scratch/SparcStation/text/`: *Sun-4M System Architecture*
  rev 50 ("[S4M]"), microSPARC-II User's Manual ("[MS2]"), SS5 and SS20
  service manuals.
- The NCR chip documents that QEMU cites, fetched from
  `ibiblio.org/pub/historic-linux/early-ports/Sparc/NCR/`: NCR89C105 Slave I/O
  ("[Slavio]", the SS5's counters, interrupts, AUX, system control), DMA2
  ("[DMA2]"), NCR89C100 MACIO, NCR53C9X.
- QEMU master: `hw/sparc/sun4m.c`, `sun4m_iommu.c`, `hw/timer/slavio_timer.c`,
  `hw/intc/slavio_intctl.c`, `hw/dma/sparc32_dma.c`, `hw/misc/slavio_misc.c`.
- Linux master: `arch/sparc/kernel/sun4m_irq.c`, `drivers/scsi/esp_scsi.c` and
  `sun_esp.c`, `drivers/net/ethernet/amd/sunlance.c`, `drivers/rtc/rtc-m48t59.c`,
  `arch/sparc/kernel/time_32.c`.
- NetBSD trunk: `sys/dev/ic/lsi64854.c`, `ncr53c9x.c`, `mk48txx.c`,
  `sys/dev/sbus/esp_sbus.c`, `sys/arch/sparc/sparc/timer_sun4m.c`, `iommu.c`.
- Grabulosaure's `ss_openbios` (HEAD): `drivers/obio.c`, `esp.c`, `sbus.c`,
  `arch/sparc32/openbios.c`.

**Severity** (same scale as [cpu.md](cpu.md)). The firmware target is the
**real Sun OBP** (SS5 OBP 2.15, SS20 OBP 2.25; REWORK Decisions, phase 5.1).
- **S1**: stops the real PROM from reaching `ok` and booting an OS, or breaks
  an OS or a feature. **S1-diag**: breaks only the POST, which runs only in
  diagnostic mode (`diag-switch?` true, Stop-D held, or no keyboard;
  [ss5-obp/README.md](../rom-disassembly/ss5-obp/README.md) §3.2). Lower
  priority than a normal-path S1.
- **S2**: wrong but tolerated, or only on an error path, a warm reboot or an
  opt-in feature.
- **S3**: cosmetic, diagnostic-only (beyond POST) or performance.

Effort: **S** up to a day, **M** a few days, **L** a redesign.

**One fact that explains many resets.** `reset_n`, the only chipset reset, is
asserted for an OSD reset, a PLL unlock, a BIOS download and a software reset
through the system control register, and each time `ss_core` zeroes all of
DRAM except the OpenBIOS image first (`rtl/mister/ss_core.vhd:928-1031`,
`sysreset` at `:1019-1024`). A register that is not in a `reset_n` block
therefore keeps its value across every reset until the FPGA is reconfigured.
The reset-state audit (§11) lists them; they are the chipset's share of the
README's "reboot MiSTer between OSes".

---

## Contents

1. [Summary](#summary)
2. [Blocks the real OBP](#blocks-the-real-obp)
3. [Address decode and bus errors](#1-address-decode-and-bus-errors)
4. [Interrupt controller](#2-interrupt-controller)
5. [Counter/timers](#3-countertimers)
6. [IOMMU and the SBus controller (MSI)](#4-iommu-and-the-sbus-controller-msi)
7. [DMA2](#5-dma2)
8. [ESP 53C9x](#6-esp-53c9x)
9. [LANCE](#7-lance)
10. [ESCC, keyboard and mouse](#8-escc-keyboard-and-mouse)
11. [NVRAM, TOD, IDPROM](#9-nvram-tod-idprom)
12. [System control, AUX, LED, power](#10-system-control-aux-led-power)
13. [Reset-state audit](#11-reset-state-audit)
14. [Test plan](#12-test-plan)
15. [Open questions](#13-open-questions)

## Summary

| ID | Device | Finding | Sev | Effort |
|---|---|---|---|---|
| AUX-1 | syscon | System control/status register has no read side (reads `0xBADACCE5`): the software-reset status bit RS reads 0, so both PROMs, which end every power-on path with SW_RST, come back on the power-on path forever; SW_RST also wipes DRAM | **S1** | S (+glue) |
| TOD-5 | NVRAM | The bitstream NVRAM image is OpenBIOS-formatted: byte 1 (`diag-switch?` for both PROMs) is `0x1a`, so the real OBP runs POST in diag mode; IDPROM type `0x72` in the SS5 build too, and one MAC/hostid for every unit | **S1** (diag byte) / S2 (IDPROM) | M |
| DEC-1 | decode | Unmapped physical addresses never fault: reads return `0xBADACCE5` and every access is acknowledged; the I/O bus has no error return at all (chipset half of cpu.md MMU-4) | **S1** | M (+CPU) |
| IOM-1 | MSI | SBus-controller registers absent (read 0, writes dropped): AFSR/AFAR, slot config, SS20 arbiter enable, MID register (SS5 SBAE/MID 8, SS20 per-requester MID), MFSR/MFAR (chipset half of SMP-1/SMP-2) | **S1** (SS20) / S1-diag (SS5) | M |
| IOM-2 | IOMMU | IMPL/VER is `0x04` (microSPARC-II's) in the SS20 build too; the SS20 OBP picks its MID source from IMPL | **S1** (SS20) | S |
| LAN-1 | LANCE | No loopback (LOOP/INTL ignored); the OBP `le` driver runs an internal loopback test in `open`, so `boot net` fails ("Can't open boot device") | **S1** (net boot) | M |
| DMA-2 | DMA2 | E_BASE_ADDR resets to FPGA power-up 0 instead of `0xff` and survives resets; byte writes ignored. Solaris is said to assume `0xff` (OpenBIOS comment); with the real OBP and a disk boot nothing sets it *(inference)* | **S1** (Solaris net, real OBP) / S2 | S |
| TOD-1 | TOD | With W=1, R=0 (the state Linux, NetBSD and the PROM TOD test use to set the clock) the user registers and the counters swap every clock, so each written field randomly keeps its old value | S2 (S1-diag) | S |
| TMR-1 | timer | SS5 prescaler divides 65 MHz by 32: 492.3 ns ticks, every OS clock runs 1.5625 % fast (22.5 min/day; beyond NTP's 500 ppm) | S2 | S |
| ESP-1 | ESP | ESP state machine, interrupt flags and mode are not reset by `reset_n`; a reset during a transfer leaves the ESP deaf to commands until software pulses D_CSR RESET | S2 | S |
| ESP-2 | ESP | Register `0x38` (TCHI / chip UID) missing and reads stale data; NetBSD uses it for the 24-bit residual, Linux for the chip family | S2 | S |
| ESP-3 | ESP | Message Accepted always reports "disconnected" | S2 | M |
| ESP-4 | ESP | Unknown commands (SELATN3, RESET ATN, target mode…) are ignored with no Illegal Command interrupt: the driver waits forever | S2 | S |
| DMA-1 | DMA2 | D_CSR INT_EN/RESET/WRITE/EN_DMA not reset by `reset_n` (real: 0 on SBus reset); with ESP-1 a stale level-4 interrupt can be live after a reset | S2 | S |
| DMA-5 | DMA2 | DATA IN that stops mid-word (phase change before TC=0) never writes its last 1-3 bytes to memory | S2 *(inference)* | M |
| INT-1 | intctl | Interrupt Target Register not reset (real: 0) | S2 (SS20) | S |
| LAN-2 | LANCE | No receive-buffer size check or chaining; frames up to 1792 bytes overrun a 1536-byte buffer | S2 (S1 with HPS Ethernet) | M |
| LAN-4 | LANCE | E_CSR RESET resets only CSR0 flags, not the microcode, DMA, TXON/RXON/MISS | S2 *(inference)* | S |
| ZS-2 | ESCC | No break detection / external-status interrupts; ttya BREAK is consumed by the debug-monitor mux, so a serial console can never reach `ok` from a running OS | S2 | M |
| KBD-1 | keyboard | No Stop (L1) or other left-block keys: no Stop-A, Stop-N, Stop-D | S2 | S |
| TMR-2 | timer | User-timer RUN bit taken from D<n> instead of D<0>: CPU1-3 user timers never start | S2 (S1-diag SS20) | S |
| TOD-6 | NVRAM | NVRAM is not persistent across core loads (see video-audio-glue.md) | S2 | M (glue) |
| DEC-3 | decode | Unimplemented/reserved offsets of `ts_inter`, `ts_timer`, `ts_esp` return the previous access's data | S2 (ESP) / S3 | S |
| IOM-3 | IOMMU | SS5: IOCR DE bit writable and IBAR bits 31:27 stored (microSPARC-II has neither) | S1-diag | S |
| IOM-7 | IOMMU | Address flush flushes everything; no tag/TLB/comparator diagnostic windows | S1-diag | M |
| INT-2 | intctl | Mask register stores reserved bits; reset value `0x7FFFFFFF` (spec: all set) | S1-diag (SS20) | S |
| TMR-3 | timer | Reading the user-timer MSW clears L | S1-diag (SS20) | S |
| TMR-4 | timer | Timer-config readback masked to the fitted CPUs (SS20 POST wants `0xF`; OpenBIOS counts CPUs with it) | S1-diag (SS20) | S (+BIOS) |
| DMA-4 | DMA2 | Most D_CSR/E_CSR bits, D_BCNT, next-address chain, SLAVE_ERR, E test/valid registers absent; EN_DMA and WRITE stored but ignored | S1-diag / S3 | M |
| DEC-2 | decode | Wrong-size and reserved accesses are accepted and aliased; no SBus error ack / slave-size error | S1-diag | M |
| INT-3 | intctl | No level-15 broadcast; INT<15>.CLR ignored | S3 | S |
| INT-4 | intctl | Mask-All does not mask the processor timer (level 14) | S3 | S |
| INT-5 | intctl | Audio bit 17 mapped to level 9 (spec 13); dead today | S3 | S |
| TMR-5 | timer | Period one tick long (counter shows the limit value); counter resets to `0x200` not 0 | S3 | S |
| TMR-6 | timer | Free-run (limit 0) never interrupts; the Slavio document says it does (open) | S3 | S |
| TMR-7 | timer | 64-bit user-timer reads are two unsynchronised word reads | S3 | S |
| IOM-4 | IOMMU | DVMA below the window is passed through (VA[31]=0) or aliased (VA[31]=1) instead of erroring | S3 | S |
| IOM-5 | IOMMU | IOPTE valid and writable bits ignored | S3 | S |
| IOM-6 | IOMMU | DVMA can only reach PA < 1 GB | S3 | S |
| IOM-8 | IOMMU | Separate 2-entry IOTLB (microSPARC-II shares its 64-entry TLB) | S3 | – |
| IOM-9 | IOMMU | CONF3 mask-rev write stored but ignored | S3 | S |
| DMA-3 | DMA2 | E_INT_PEND is gated by E_INT_EN | S3 | S |
| DMA-6 | DMA2 | ESP DVMA is one single-word request per 4 bytes | S3 | M |
| ESP-5 | ESP | FLUSH sets "function complete" without an interrupt | S3 | S |
| ESP-6 | ESP | Chip reset leaves CFG2/CFG3/command; misc status bits | S3 | S |
| LAN-3 | LANCE | Promiscuous mode and the multicast hash (LADRF) not implemented | S3 (S2 bridging) | S |
| LAN-5 | LANCE | CSR0/CSR3 read details (TDMD, IDON on STOP, CSR3 debug bits) | S3 | S |
| LAN-6 | LANCE | Alignment limits on init block, TX buffers and chained segments | S3 | S |
| LAN-7 | LANCE | With no PHY every frame "transmits" successfully into nothing | S3 | – |
| ZS-1 | ESCC | Master Interrupt Enable ignored | S3 | S |
| ZS-3 | ESCC | Baud rate and character format ignored; ttya is fixed 115200 8N1 | S3 | S (doc) |
| ZS-4 | ESCC | "Reset highest IUS" clears a pending TX interrupt | S3 *(inference)* | S |
| ZS-5 | ESCC | Channel reset leaves the RX interrupt pending | S3 | S |
| ZS-6 | ESCC | RR15, RR1 error bits, local loopback missing | S3 | S |
| ZS-7 | ESCC | ttyb receive pin undriven in `ss_core` | S3 | S |
| KBD-2 | mouse | PS/2 9-bit deltas truncated, not clamped: fast moves jump backwards | S3 | S |
| KBD-3 | keyboard | No idle code 0x7F after the last key-up; bell/click ignored | S3 | S |
| TOD-2 | TOD | Calibration, sign, FT, KS bits not stored | S3 | S |
| TOD-3 | TOD | Leap-year rule wrong when the stored year's tens digit is odd | S3 | S |
| TOD-4 | TOD | ST (oscillator stop) cleared by reset | S3 | S |
| AUX-2 | AUX | Core-private register at the real AUXIO1 address; AUXIO2 (power) aliases it on the SS5, missing on the SS20 | S3 | S |
| AUX-3 | slavio | Configuration, diagnostic-message and modem registers missing | S3 | S |

S1 count: 7 (AUX-1, TOD-5, DEC-1, IOM-1, IOM-2, LAN-1, DMA-2).

---

## Blocks the real OBP

The order is the order in which each PROM reaches the device. The IDs are
this document's; `cpu.md` IDs are cited for the CPU side. **Normal path**
means `diag-switch?` false and a keyboard attached (the emulated Sun keyboard
answers, so the core is always "keyboard present").

### SS5, OBP 2.15

Reset and machine code ([ss5-obp/README.md](../rom-disassembly/ss5-obp/README.md) §3):

| # | PROM step | Chipset dependency | Core | ID, Sev |
|---|---|---|---|---|
| 1 | `reset_entry` `0x7000bda0`: `lda [0x71f00000]`, bit 4 = watchdog, bit 1 = SW reset | Slavio system control/status: SR, RS (bit 1), WD (bit 4) [Slavio "System Status and System Control"] | reads `0xBADACCE5`: RS=0, WD=0 → always the power-on path | AUX-1 **S1** |
| 2 | `reset_power_on` step 3/8: `boot_puts` and the POST decision read NVRAM byte 1 = `diag-switch?` | NVRAM contents | image byte 1 = `0x1a` → diag mode, POST runs | TOD-5 **S1** |
| 3 | ttya and keyboard Z85C30 init, polled RR0/RR1 | ESCC polled mode | works; ttya really runs at 115200 (the PROM programs 9600) | ZS-3 S3 |
| 4 | processor counter 0 as a 64-bit user timer for the 1 s keyboard timeout (`0x71d10010`=1, start/stop, `ldda`) | UT mode, RUN bit D<0>, config T0 | works on CPU0; tick 1.56 % short | TMR-1 S2, TMR-7 S3 |
| 5 | keyboard reset `0x01` → `ff 04 7f`, Stop/`d` scan | Sun keyboard protocol | works; no Stop key exists, so Stop / Stop-D / Stop-N cannot be used | KBD-1 S2 |
| 6 | POST, only if diag (see below) | | | |
| 7 | `post_exit_soft_reset` or, when the POST is skipped, `soft_reset_via_boot_space` (`0x7000bc8c`, `0x7000bd04`) → `sysctl_soft_reset`: `sta 1,[0x71f00000]` (SW_RST) on **every** path | SW_RST must reset, RS must read 1 afterwards | `ss_core` does a full reset + DRAM wipe; RS reads 0 → back to step 1, forever | AUX-1 **S1**; cpu.md CFG-2 |
| 8 | `obp_start_after_sw_reset`: TLB, caches, `obp_cold_entry` memory search | CPU and memory map | — | cpu.md MMU-1, MMU-9 |

Forth side ([ss5-obp/device-tree.md](../rom-disassembly/ss5-obp/device-tree.md)):

| # | Step | Dependency | Core | ID, Sev |
|---|---|---|---|---|
| 9 | NVRAM configuration checksum | a Sun-format NVRAM, persistent | invalid on every core load → "Setting NVRAM parameters to default values" | TOD-6 S2 |
| 10 | IDPROM check: byte 0 = 1, byte 1 = `real-machine-type` (`0x80`), XOR checksum (`forth-dictionary.txt`, word at `0x7002ddd0`) | IDPROM at NVRAM `0x1fd8` | image has type `0x72`: banner "The IDPROM contents are invalid"; MAC/hostid shared by every unit | TOD-5 S2 |
| 11 | `/iommu` set-up: base, control = RANGE<<2 \| ME, reads RANGE back; `-1 aer!` | IOCR/IBAR | works (IMPL/VER `0x04` matches [MS2] §5.7.1) | — |
| 12 | `probe-sbus` `541230`: slots 5 and 4 use the PROM's own FCode (espdma, esp, le, bpp, CS4231, power-management); slots 1, 2 (and 0 if the AFX byte at pa `0x6e000000` says so) are `cprobe`d | reads of an empty slot must fault | `cprobe` succeeds, first byte `0xBA` → "Invalid FCode start byte at …" instead of "Nothing there" (noise, not a hang: `probe`/`probe-virtual`, `forth-dictionary.txt:13017`) | DEC-1 **S1** (with cpu.md MMU-4) |
| 13 | slot 3: the TCX FCode | display FCode PROM | none | video-audio-glue.md V4 |
| 14 | `boot disk`: the PROM's esp FCode: D_CSR RESET pulse, waits on bit 10 (REQ_PEND) = 0, polls D_CSR bit 0 (`fcode-70011f00-espdma.txt` 0x1f8-0x36d) | DMA2/ESP as OpenBIOS drives them | same register subset OpenBIOS uses; not verified against the Sun driver | ESP-1…4 S2, open question 6 |
| 15 | `boot net`: `le` `open` runs the internal loopback test (`t9da`, "Internal loopback test --", `fcode-…espdma.txt` 0x3551) and fails the open if it fails; `dma-alloc` writes E_BASE (0x24d6) | LANCE LOOP+INTL | not implemented → "Can't open boot device" | LAN-1 **S1** |
| 16 | the OS after a disk boot: Solaris `le` with E_BASE never written by OBP | E_BASE default `0xff` | 0 | DMA-2 **S1** *(inference)* |

Diagnostic mode only (POST, in `post_sequencer` order; the POST stops at the
first failing group, and QEMU already stops at the MMU TLB test):
MMU tests (cpu.md MMU-1, MMU-2) → IOMMU group: SSCR (IOM-1), IOCR (IOM-3),
IBAR (IOM-3), IOMMU TLB flush (IOM-8, uses the CPU TLB), SBus/EBus read
time-out (DEC-1) → caches, memory, FPU (cpu.md) → interrupt registers and soft
interrupts (pass) → user timer, counter/timer (pass, timing-sensitive) →
DMA2/LANCE/ESP/BPP register tests (DMA-4, DEC-2; BPP absent) → NVRAM (pass)
→ TOD registers (TOD-1). All S1-diag.

### SS20, OBP 2.25

Reset and machine code ([ss20-obp-2.25/README.md](../rom-disassembly/ss20-obp-2.25/README.md) §3, §8):

| # | PROM step | Dependency | Core | ID, Sev |
|---|---|---|---|---|
| 1 | `reset_entry`: arbiter enable `0xf_e000_1008 \|= 0xf` | MSI arbiter (bit 0 reads 1, bits 3:1 park CPUs 9-B) | not decoded: reads 0, writes dropped; all CPUs run | IOM-1 **S1**; cpu.md SMP-2 |
| 2 | Viking: MID to ASI 0x38 | CPU | — | cpu.md SMP-1 |
| 3 | `reset_find_mid`: IOMMU IMPL ≠ 0 → MSI MID register `0xf_e000_2000`; IMPL = 0 → ASI 0x38 / MXCC | IOMMU IMPL (`0x13` on a real SS20 per QEMU `sun4m.c` SS-20 def), per-requester MID register | IMPL = 0, MID register reads 0 | IOM-2 **S1**, IOM-1 **S1** |
| 4 | `reset_mid_known` (master): AUXIO0 LED \|= 1, NVRAM release flags `0x0f..0x12` = `0xff` | AUXIO0, NVRAM | works | — |
| 5 | `reset_check_sysctl`: syscon bit 3 (switch reset) or bit 1 (SW reset) → `obp_start` | syscon | reads `0xBADACCE5`: bits 1, 3 = 0 | AUX-1 **S1** |
| 6 | `reset_power_on`: MID register > 8 → slave; ESCC; user timer on CPU0; keyboard; `diag-switch?` | MID register, NVRAM byte 1 | MID reads 0 (all masters); byte 1 = `0x1a` | IOM-1 **S1**, TOD-5 **S1** |
| 7 | `obp_prep`: master writes SW_RST | as SS5 step 7 | loops | AUX-1 **S1** |
| 8 | `obp_start`: AUXIO0 \|= 4, cache init | AUXIO0 byte read-modify-write | works (bit 2 is dropped) | AUX-2 S3 |
| 9 | `rom-cold-code`: EMC delay register `0xf_0000_0004`; SIMM/VSIMM probing; DMA2 D_ADDR used as a mailbox for the slaves' context-table pointer | EMC (absent: HARDWARE_GAPS), D_ADDR read/write | EMC writes dropped silently; D_ADDR works as a 32-bit read/write register (`ts_dmaux.vhd:208-216`, `ts_esp.vhd:753-757`, `824`) as long as no ESP DMA runs | HARDWARE_GAPS; memory map: cpu.md, glue |
| 10 | Forth: IDPROM type `0x72` (matches this build), NVRAM defaults, MP release | NVRAM, per-CPU interrupt/timer blocks | per-CPU blocks for CPUs 0-2 work | TOD-6 S2 |
| 11 | SBus probe, `boot net` | as SS5 12-16 | as SS5 | DEC-1, LAN-1, DMA-2 |

Diagnostic mode only ([ss20-obp-2.25/post-tests.md](../rom-disassembly/ss20-obp-2.25/post-tests.md) §8-9):
System Interrupt Regs (INT-2), PROCn User Timer (TMR-2, TMR-3, TMR-4),
MSI/MSBI control regs (IOM-1), IOMMU CAM/TLB/comparator/flush (IOM-7), TOD
(TOD-1), DMA2/MACIO registers (DMA-4, DEC-2), ESP registers (pass), LANCE
ports (DEC-2 slave errors). All S1-diag.

**What QEMU gives the PROM.** Under QEMU the SS5 OBP reaches `ok`
(`ss5-obp/qemu-console.txt`) because QEMU keeps `SYS_RESETSTAT` across the
reset it performs for SW_RST (`slavio_misc.c:337-350`, and the reset handler
leaves `sysctrl` alone, `:106-111`), faults unassigned SBus reads ("Nothing
there" for slots 0-2), and writes the IDPROM with type `0x80` at start-up
(`sun4m.c` `nvram_init`, SS-5 `nvram_machine_id = 0x80`). QEMU's NVRAM also
starts with an OpenBIOS partition, so `diag-switch?` reads true there as well
("Power-ON Reset" is printed only when it is set); QEMU also has no keyboard,
which alone forces the POST. QEMU's
SS-5 IOMMU version (`0x05000000`) is not the one the SS5 POST expects
(`0x04000000`), and QEMU fails that test; the core is right there.

---

## 1. Address decode and bus errors

`ts_decode.vhd` produces one select per device from PA[35:20] (SS5
`:51-112`, SS20 `:115-162`); `ts_io.vhd` muxes the answers
(`ReadMux`, `:730-793`). `ts_core.vhd` first splits memory from I/O
(`sel_decodage_nosmp` `:483-493`, `sel_decodage_smp` `:495-504`).

### DEC-1 Unmapped physical addresses never fault (S1, M + CPU)

- **Real hardware.** A CPU read of an SBus slot with no device times out and
  becomes a synchronous `data_access_error` (tt 0x29) with SFSR TO; an EBus
  (slavio) hole or a wrong-size access gets an SBus error acknowledge (SFSR
  BE) [Slavio "Reads or writes of reserved addresses … result in an SBus
  error acknowledgement"; MS2 §5.6.4; S4M §6.4]. Writes are write-buffered:
  the error lands in the M-to-S AFSR/AFAR and raises a level-15 interrupt
  [S4M §5.2].
- **Core.** Any address with no select reads `x"BADACCE5"` (`ts_io.vhd:760`)
  and is acknowledged at once (`:790`). The I/O bus cannot say anything
  else: `type_pvc_r` is `ack` + `dr` only (`rtl/plomb/plomb_pack.vhd:35-38`),
  and the plomb bridge hardwires `bus_r.code <= PB_OK`
  (`rtl/plomb/plomb_pvc.vhd:86`). Byte reads see `0xBA`, `0xDA`, `0xCC`,
  `0xE5` by lane.
- **Who is affected.**
  - Real OBP, normal path: `probe` `cprobe`s every empty SBus slot and finds
    "something" (step 12 above); the SS5 AFX slot-0 decision reads pa
    `0x6e000000`.
  - Real OBP, diag: SS5 POST 4.6/4.7 (SBus read of `0x7cc00000`, EBus read of
    `0x71400300`), SS20 MBus-to-SBus/EBus time-out tests (dead code).
  - Every register the core does not implement returns a plausible non-zero
    word (`0xBADACCE5` for the syscon, AUX2, config, the floppy, BPP, the
    MACIO ID register, the EMC…), so a driver cannot tell "absent" from
    "present" (for example the SS5 `SUNW,fdtwo` node is static in the PROM,
    and a Solaris/SunOS floppy driver would find a phantom 82077; *inference*).
- **Fix.** Add an error field to `type_pvc_r`; in `ts_io` set it for
  `sel.vide` reads (time-out for SBus slot space, error-ack for slavio/EBus
  space) and for the "absent" register holes; map it to `PB_ERROR` in
  `plomb_pvc`; the MCU turns it into tt 0x29 with SFSR/SFAR (cpu.md MMU-4).
  Writes: drop, and latch AFSR/AFAR (IOM-1) with an optional level-15
  interrupt (INT-3). Keep a debug switch for the old behaviour.
- **Test.** Lift SS5 POST 4.6/4.7 into `tests/cpu`: read `0x7cc00000`,
  expect tt 0x29, SFAR `0x7cc00000`, `SFSR & ~0x3e0` = `0x816`; read
  `0x71400300`, expect `0x416`.

### DEC-2 Wrong-size and reserved accesses are accepted (S1-diag, M)

- **Real.** Slavio registers take only their documented sizes, reserved
  addresses and wrong sizes error-ack [Slavio address map]; DMA2/LANCE/BPP
  registers answer a byte store with SLAVE_ERR in their CSR plus an error ack
  that the M-to-S buffer latches as AFSR `0x93820000` (SS5,
  `post-tests.md` §9.0) [DMA2 D_CSR bit 6].
- **Core.** Blocks decode a few address bits and ignore the rest: per-CPU
  interrupt and timer blocks use A[16:12] and A[3:2]
  (`ts_inter.vhd:165-264`, `ts_timer.vhd:170-221`), the IOMMU A[13:2]
  (`ts_iommu.vhd:186-227`), AUXIO0 A[4:2] (`ts_dmaux.vhd:247-323`), the ESP
  A[6:2]/A[5:2] (`ts_esp.vhd:169-319`). Byte stores to word registers are
  either ignored (`w.be="1111"` guards) or applied.
- **Affected.** The SS5 and SS20 DMA2/LANCE "slave error" halves of their
  POST tests; nothing in the OSes found.
- **Fix.** With DEC-1's error path in place, error-ack reserved offsets per
  block and set DMA-4's SLAVE_ERR. **Test:** the POST slave-error sequences.

### DEC-3 Stale read data from unimplemented offsets (S2 for the ESP, S3 elsewhere; S)

- **Core.** `ts_inter`, `ts_timer` and `ts_esp` assign their read register
  `dr` only inside the branches of implemented offsets; there is no default
  (compare `ts_iommu.vhd:183` and `ts_dmaux.vhd:193`, which default to 0). A
  read of a reserved offset, an absent CPU's block, or the ESP's `0x24`,
  `0x28`, `0x38`, `0x3c` returns whatever the previous access of that block
  left. See ESP-2 for the case that matters.
- **Fix.** `dr <= (OTHERS => '0')` at the top of each process.

### Other decode notes (S3)

- SS5: `0x7191_0000` (AUXIO2, power) falls inside `sel.auxio0` (`x"719"`,
  `ts_decode.vhd:91`) and aliases the core's AUXIO0 register (AUX-2).
  `0x7180_0000` (configuration), `0x71B0_0000` (modem), `0x7130_0000`
  (generic port) are not decoded; `0x71A0_0000` (diagnostic message) and
  `0x7160_0000` (LED) are selected but have no register and read
  `0xBADACCE5` (AUX-3).
- SS20: every pa below `0x8_0000_0000` is memory (`ts_core.vhd:499`), so the
  `aa(28)` IOMMU alias in `ts_decode.vhd:134-136` is dead, and the PROM's VSIMM
  control reads and memory time-out probe hit DRAM (memory map: cpu.md, glue).

---

## 2. Interrupt controller

`ts_inter.vhd`. Per-CPU pending/clear/set at `0x…4n000`, system pending,
mask, mask clear/set and ITR at `+0x10000` [S4M §3.2.2.2.3]. Soft interrupts
set and clear correctly per CPU (`:165-264`), the level encoder is a plain
priority encoder (`:328-432`), per-CPU pending shows HARD_INT<13:1> only for
the current target and only for unmasked sources, which matches [S4M §5.7.1.1,
§5.7.3] ("the current Interrupt Target will not see any effect"; QEMU shows
unmasked sources there). The per-CPU and soft-interrupt POST tests of both
PROMs pass on this logic (the SS20 mask test does not, INT-2). The level map
(`hardint`, `:102-127`) matches [S4M §6.3] and Linux `sun4m_imask` except
INT-5. The CS4231 is wired as SBus level 5 (bit 11 →
PIL 9, `:144`), which is what the real SS5 OBP publishes for `SUNW,CS4231`
(`intr 0x39`, `device-tree.md` §2).

### INT-1 Interrupt Target Register not reset (S2 on the SS20, S)

- **Real.** ITR = 0 after power-on or software reset [Slavio Table 6-21;
  QEMU `slavio_intctl_reset` `target_cpu = 0`].
- **Core.** `itr` (`ts_inter.vhd:93`) is written at `:297-302` and never
  reset (`:308-314`).
- **Affected.** SS20 with more than one CPU: after an OS moved undirected
  interrupts to CPU n (Linux `sun4m_irq_rotate`, Solaris interrupt
  distribution), a reset leaves every device interrupt on CPU n while the
  PROM and the next OS start on CPU 0. The SS20 OBP writes ITR only in its
  POST and MP-dispatch code (`ss20-obp-2.25/hardware-access.md`); Linux
  writes 0 at init only when the PROM lists four per-CPU interrupt blocks
  (`sun4m_irq.c:466-467`, `num_cpu_iregs == 4`; OpenBIOS lists four on the
  SS20). A candidate for "reboot MiSTer between OSes".
- **Fix.** `itr <= "00"` in the reset block. **Test:** write ITR = 2, SW
  reset, expect 0.

### INT-2 Mask register: reserved bits and reset value (S1-diag on the SS20, S)

- **Real.** Reserved bits read 0 (bits 26:23 in [S4M §5.7.3.2]; in the SS5
  Slavio also 27, 21, 17 and 6:0 [Slavio Fig. 6-12]); "all mask bits are SET
  upon system reset" [S4M §5.7.3, Slavio].
- **Core.** `mask` keeps all 32 bits (`:283`, `:291`) and resets to
  `0x7FFFFFFF` (`:313`): MA clear, reserved bits set.
- **Affected.** SS20 POST "System Interrupt Regs Tests" writes `0xf87fffff` to
  mask-set and expects to read exactly that (xor `0x07800000`). QEMU also
  resets to `0x7FFFFFFF`.
- **Fix.** AND the stored value with an implemented-bits constant per build.
  **Keep MA clear at reset**: OpenBIOS only clears bits 30:0
  (`obio.c` `intregs->clear = ~SUN4M_INT_MASKALL`) and Linux never touches MA
  (`sun4m_irq.c:463` sets bits 30:0, then unmasks per source), so a reset
  value with MA set would mask every interrupt under those; the real OBP must clear MA itself, which is
  unverified (open question 9).

### INT-3 No level-15 broadcast; INT<15>.CLR ignored (S3, S)

- **Real.** Level-15 sources (ME, I, M, V) set HARD_INT 15 in *every*
  processor's pending register; each CPU clears its copy with bit 15 of its
  clear-pending register [S4M §5.7.1.2, §6.2.1].
- **Core.** No source drives bits 30:27 (`:132-134`); level 15 would only go
  to the target (`:109`); clear-pending uses bits 31:17 only (`:174`).
- **Affected.** Nothing today. It becomes necessary with DEC-1/IOM-1 (async
  write errors) and the watchdog (cpu.md IU-1).

### INT-4 Mask-All does not mask the processor timer (S3, S)

`hardint` returns `int_timer_p` whatever `mask(31)` is (`:110`, `:125`).
QEMU masks level 14 and 15 with MA only; [S4M] describes MA as masking all
external interrupts. Harmless in practice.

### INT-5 Audio (bit 17) routed to level 9 (S3, S)

`hardint` puts `pend(17)` on level 9 (`:115`); [S4M §6.3], Linux
(`sun4m_imask` 0x2d) and QEMU (`intbit_to_level[17] = 13`) put Audio/ISDN on
level 13. Dead, because bit 17 is tied to 0 (`:139`). Fix when an onboard
audio source (SS20 DBRI) is added.

---

## 3. Counter/timers

`ts_timer.vhd`. One 54-bit counter per CPU (22-bit counter + 22-bit limit in
counter mode, a 54-bit count in user-timer mode) and a 22-bit system counter,
clocked by `pulse` every `SYSFREQ/2/1_000_000` clocks (`:82`, `:107-120`).
Limit write resets the count to 1 (`0x200`), the non-resetting port does not,
any access to the limit clears L, the counter read leaves L alone, limit 0
free-runs (`:132-245`) — all as [S4M §5.3.2] and [Slavio]. Linux, NetBSD
(`timer_sun4m.c` uses `t_limit_nr` for statclock) and OpenBIOS use only these.

### TMR-1 SS5 prescaler is 1.5625 % fast (S2, S)

- **Real.** The counters increment every 500 ns [S4M §5.3.2].
- **Core.** `PULSE_PER = SYSFREQ/2/1000000` is an integer division; the SS5
  build runs at 65 MHz (`SunSparcStation.sv:299`, `ss_core.vhd:22`), so
  `PULSE_PER` = 32 and a tick is 492.3 ns. The SS20 build (50 MHz) is exact.
  The TOD is exact (`ts_rtc.vhd:60`, one pulse per `SYSFREQ` clocks), so the
  two clocks disagree.
- **Affected.** Every OS on the SS5: Linux's clocksource assumes 2 MHz
  (`SBUS_CLOCK_RATE`), so the system clock gains 22.5 min/day; ntpd cannot
  discipline 15 625 ppm (its limit is 500 ppm) and gives up. OBP's measured
  `clock-frequency` (ms-factor calibration) is off by the same amount.
- **Fix.** Generate the 2 MHz enable with the existing fractional divider
  `rtl/peri/synth.vhd` (`FREQ => SYSFREQ, RATE => 125_000` gives 16 × 125 kHz
  = 2 MHz on average), or a phase accumulator. **Test:** count user-timer
  ticks across two TOD second edges; expect 2 000 000 ± 2.

### TMR-2 User-timer RUN bit taken from D<n> (S2, S1-diag on the SS20; S)

- **Real.** RUN is D<0> of each processor's start/stop register [S4M §5.3.4,
  Slavio Fig. 6-17; QEMU `val & 1`].
- **Core.** `p_run(I) <= w.dw(I)` (`ts_timer.vhd:216-217`): CPU1 needs D<1>,
  CPU2 D<2>. Readback puts `p_run(I)` in bit 0 (`:219`).
- **Affected.** SS20 POST "PROC1/PROC2 User Timer Test" ("Processor User
  Timer Not Incrementing"); any OS using the user timer on CPUs 1-3 (none
  known).
- **Fix.** `w.dw(0)`.

### TMR-3 Reading the user-timer MSW clears L (S1-diag on the SS20, S)

`p_ov(I) <= '0'` on any access to `+0` (`:180`), also in user-timer mode;
the user-timer L bit is cleared only by writes [S4M §5.3.3, Slavio]. SS20
POST user-timer step 9 reads the MSW twice (`post-tests.md` §8). Fix: clear
only on reads in counter mode, on writes in both.

### TMR-4 Timer configuration readback masked to the fitted CPUs (S1-diag on the SS20, S + BIOS)

`p_mode <= w.dw(3 DOWNTO 0) AND CPUEN` (`:250`): with 3 CPUs, writing
`0xffffffff` reads back `0x7`. The SS20 POST expects `0xf` ("all four T bits
are RW regardless of how many CPUs are fitted"); the SS5 Slavio has only T0
and its POST expects `0x1`, which the SS5 build gives. **OpenBIOS depends on
the masking**: `ob_counter_init` writes `0xffffffff` and counts CPUs from the
readback (`obio.c`, CONFIG_TACUS). Fix together with OpenBIOS (the SYSCONF
register, ASI 4 VA `0xD00`, already carries NCPU-1: `ts_core.vhd:193-196`) or
leave as is while OpenBIOS is supported.

### TMR-5 Period one tick long; counter reset value (S3, S)

The counter resets to 1 on the tick where it *equals* the limit
(`:135-137`, `:154-156`), so the limit value is visible for one tick and the
period is L ticks. [S4M]/[Slavio]: "when a counter reaches the value in the
limit register … it is reset to 500 ns", i.e. period L−1 (QEMU:
`LIMIT_TO_PERIODS(l) = (l>>9) - 1`). Linux and NetBSD program
`(n+1) << 10`, which fits the real behaviour. Error: 500 ns per period
(0.005 % at HZ=100). The reset value of the counters is `0x200` (`:260-265`);
[Slavio]: all count and limit bits are 0 after reset.

### TMR-6 Free-run interrupt (S3, open)

With limit 0 the core never sets L (no match, `:135`), as [S4M §5.3.2] and
QEMU say. [Slavio] says instead "setting the limit register to 0 causes the
counter to free-run. Interrupts will be generated when the counter
overflows, approximately every two seconds". Needs a hardware check (open
question 1).

### TMR-7 64-bit user-timer reads are not atomic (S3, S)

An `ldda` reaches the timer as two independent word reads (`plomb_pvc.vhd`
is single-beat), so a carry from the LSW between them gives a value off by
2^23 ticks; [S4M §5.3.3] promises 64-bit consistency ("`<AFAIRE>` Cohérence
64bits", `ts_timer.vhd:15`). The PROMs' keyboard time-out uses `ldda`; a rare
early time-out is the only effect. Fix: latch the MSW when the LSW is read
(or vice versa).

---

## 4. IOMMU and the SBus controller (MSI)

`ts_iommu.vhd`. Implemented: control (ME, DE, RANGE, IMPL/VER), base,
flush-all, address flush, the microSPARC-II mask ID at `0x3018`, and a
2-entry IOTLB with a hardware table walk; DVMA with ME=0 passes through.
Correct for what Linux (`arch/sparc/mm/iommu.c`), NetBSD (`iommu.c`,
including `iommu_copy_prom_entries`), OpenBIOS and the OBP's own IOMMU words
(`iommu-ctl@`, RANGE readback) use.

### IOM-1 SBus-controller / MSI registers absent (S1 on the SS20, S1-diag on the SS5; M + CPU)

- **Real.**
  - SS5 (microSPARC-II control space [MS2 §5.7]): AFSR `0x1000_1000`
    (bits 23:20 forced to `1000`), AFAR `+4`, SSCR0-4 `+0x10..0x20`
    (SA30, BA8, BY), MFSR/MFAR `+0x50/0x54`, **MID register** `0x1000_2000`
    (MID = 8 read-only, SBAE[5:0] RW at bits 21:16).
  - SS20 (MSI [S4M §3.2.2.4, §5]): AFSR/AFAR `0xf_e000_1000/1004`,
    **arbiter enable** `+0x1008` (bit 0 reads 1; POR `0x00000003`; bits 3:1
    enable CPUs 9-B, 20:16 SBus masters), slot config `+0x1010..0x101c`,
    **MID register** `0xf_e000_2000` (the MBus ID of the requesting master).
- **Core.** Only `0x0`, `0x4`, `0x14`, `0x18` and `0x3018` are decoded
  (`ts_iommu.vhd:186-227`); everything else reads 0 (`:183`) and writes are
  dropped.
- **Affected.**
  - SS20 real OBP, normal path: the arbiter (`reset_entry`, `mp_dispatch`,
    master/slave parking) and the MID register (`reset_find_mid` when IMPL ≠
    0, "MID > 8 → slave" in `reset_power_on`). With the register reading 0
    every CPU is the master. This is the chipset half of cpu.md SMP-1
    (per-CPU MID) and SMP-2 (parking CPUs): the MID register needs the
    requesting CPU's identity, which the I/O bus does not carry today
    (`smpmux` knows the source; `type_pvc_w` has no master ID), and the
    arbiter bits need a CPU hold input.
  - SS5 POST (diag): SSCR walk (4.1), `report_async_trap` reads AFSR/AFAR,
    every DMA2/LANCE slave-error test expects AFSR `0x93820000`; POST entry
    writes the MID register (SBAE = 0). SS20 POST MSI/MSBI test (slot config),
    every DMA2 test (AFSR).
  - OSes: NetBSD prints AFSR/AFAR on an IOMMU error (`iommu.c:459`); no OS
    found that needs the MID or slot config registers on these machines.
- **Fix.** Add the registers in `ts_iommu` (or a new `ts_msi`): AFSR/AFAR
  latched by DEC-1/DEC-2 errors, clear-on-write; SSCR/slot config as RW with
  the documented masks (SS5 `0x00010003`, SS20 `0x3800f`); the SS5 MID
  register (constant 8 + RW SBAE); for the SS20 a MID field on the I/O
  request (from `smpmux`) and arbiter bits wired to the CPU hold (cpu.md
  SMP-2). **Test:** SS20: read `0xf_e000_2000` from each CPU (expect
  8, 9, 10); write arbiter `0x1f0001`, check CPUs 9-A stop.

### IOM-2 SS20 IMPL/VER (S1 on the SS20, S)

- **Real.** The SS20 IOMMU reports a non-zero IMPL: QEMU's SS-20 definition
  uses `0x13000000` (IMPL 1, VER 3; SS-10 `0x03000000`). The SS20 OBP uses
  IMPL = 0 to mean "first MSI, whose MID register is broken" [S4M §5.4.3] and
  then takes the MID from the CPU (ASI 0x38 on a Viking without MXCC), and
  IMPL ≠ 0 to take it from the MSI MID register and to run the
  arbiter/ESP-reset branch of `reset_check_sysctl`
  (`ss20-obp-2.25/README.md` §3.1). IMPL = 0 also makes the POST comparator
  test run (it skips when IMPL ≠ 0).
- **Core.** Every CPU configuration has `IOMMU_VER => x"04"`
  (`rtl/cpu/cpu_conf_pack.vhd:92`, `:120`, `:148`), read at
  `ts_iommu.vhd:192`. For the SS5 this is right ([MS2 §5.7.1]: IMPL 0, VER 4;
  SS5 POST 4.2 expects `0x04000000`).
- **Fix.** `CONF_SuperSparc.IOMMU_VER := x"13"` once IOM-1's MID register
  works (with IMPL = 1 and a MID register reading 0 the SS20 OBP is no better
  off). Confirm the value on a real SS20 (open question 3).

### IOM-3 SS5 IOCR DE bit and IBAR width (S1-diag, S)

[MS2 §5.7.1-2]: IOCR bits 23:5 and 1 are not implemented (read 0); IBAR is
IBA[30:14] in bits 26:10, bits 31:27 read 0. The core stores DE
(`ts_iommu.vhd:189`) and IBA[35:14] in bits 31:10 (`:198`), the generic
Sun-4M format the SS20 wants. SS5 POST 4.2 and 4.3 fail (they expect
`0x04000018`/`0x04000005` and `0x025a5800`/`0x05a5a400`). Fix: per-build
write masks.

### IOM-4 DVMA outside the translation window (S3, S)

[MS2 §5.7.1]: "All VA bits above this limit must be set to one … Any access
using a DVMA virtual address that is out of that range will receive an SBus
error acknowledge". The core translates whenever ME=1 and VA[31]=1, indexing
the table with VA[23+RANGE:12] so that out-of-window addresses alias
(`ts_iommu.vhd:136-143`, `157-165`), and passes VA[31]=0 straight through
even with ME=1 (`:166-171`). Only a buggy driver notices; the error would
feed DMA-4's ERR_PEND.

### IOM-5 IOPTE V and W ignored (S3, S)

The TLB fill stores W but never checks it, and marks every fetched PTE valid
(`ts_iommu.vhd:47-52`, `318-323`). A stale or read-only mapping is used
instead of an error; a runaway DMA corrupts memory instead of stopping with
D_ERR_PEND.

### IOM-6 DVMA limited to PA < 1 GB (S3, S)

`pa_v(35 DOWNTO 30) := "000000"` (`:256`) folds any IOPTE that points above
1 GB (or into I/O space, e.g. SBus-to-SBus DVMA) into DRAM. Nothing uses it
today.

### IOM-7 Address flush flushes everything; no diagnostic windows (S1-diag, M)

Both flush registers invalidate the whole IOTLB (`:203-218`), correct for
software. The IOMMU tag/TLB diagnostic windows (`+0x100`, `+0x200`), the
SS20 comparator (`+0x140`, `+0x150`) and the address-matched single flush
the POSTs check are absent: SS20 "IOMMU CAM/TLB NTA", "Comparator" and "TLB
Flush" tests fail. On the SS5 the POST instead checks IOPTEs in the CPU TLB
(IOM-8). The flush is also deferred until no DVMA request is pending
(`flushpend`, `:352-362`), a window too short to matter (*inference*).

### IOM-8 Separate 2-entry IOTLB on the SS5 (S3)

microSPARC-II keeps IOPTEs in its shared 64-entry TLB (entries 48-63 with
TRCR.IL) [MS2 §5.6.6]; SS5 POST 4.4/4.5 flush and inspect them through ASI 6.
The core's IOTLB is separate and has two entries (`N_IOTLB`, `:107`):
correct for software, a performance point for DVMA-heavy loads, and part of
cpu.md MMU-2 for the POST.

### IOM-9 Mask-rev register (S3, S)

The OSD "IOMMU rev" reaches `0x3018` (`ts_iommu.vhd:225-227`) through
`mask_rev <= reset_mask_rev` (`ts_dmaux.vhd:356`); the CONF3 register
(`ts_dmaux.vhd:284-289`) stores writes but its output is unused, so reading
CONF3 back can disagree with `0x3018`. `0x3018` also answers on the SS20,
where it is not a SuperSPARC register. OpenBIOS reads it for the SS5 CPU's
`mask_rev` property (`openbios.c` `mb86904_init`). See cpu.md CFG-3.

---

## 5. DMA2

`ts_dmaux.vhd` holds the CSRs; the ESP's DMA address counter and engine live
in `ts_esp.vhd`, the LANCE's in `ts_lance.vhs`.

| Offset | Register | Core |
|---|---|---|
| `0x00` | D_CSR | DEV_ID `0xA`, INT_PEND (= ESP interrupt), INT_EN, RESET, WRITE, EN_DMA (`:197-206`) |
| `0x04` | D_ADDR | read/write (the counter is in `ts_esp`) |
| `0x08` | D_BCNT | absent (`:218`) |
| `0x0c` | D_TEST | absent |
| `0x10` | E_CSR | DEV_ID, INT_PEND (gated, DMA-3), INT_EN, RESET (`:228-235`) |
| `0x14`, `0x18` | E_TST_CSR, E_VLD | absent ("Inutile") |
| `0x1c` | E_BASE_ADDR | bits 31:24 (DMA-2) |

Linux (`sun_esp.c`, `sunlance.c`), NetBSD (`lsi64854.c`), OpenBIOS
(`esp.c`, `sbus.c`) and the OBP esp FCode use INT_PEND, ERR_PEND (read as 0),
the DRAINING bits (0), bit 10 (0), INT_EN, RESET, WRITE, EN_DMA, the device ID
and read-modify-write of the rest, so the subset is enough for them.

### DMA-1 D_CSR bits not reset (S2, S)

[DMA2 note under the D_CSR table]: "All bits in the D_CSR default to 0 on a
D_RESET or SBus reset". The core resets the E_CSR bits (`:327-328`) but not
`dma_esp_iena_i`, `dma_esp_reset_i`, `dma_esp_write_i`, `dma_esp_endma_i`
(`:167-170`, reset block `:326-339`). After a reset in the middle of disk I/O,
INT_EN can still be 1 while the ESP's `inter` is also stale (ESP-1): the
next OS or PROM sees a level-4 interrupt as soon as it unmasks SCSI. Fix:
reset them. **Test:** set INT_EN, reset, read D_CSR = `0xa0000000`.

### DMA-2 E_BASE_ADDR default and byte writes (S1 for Solaris networking with the real OBP *(inference)*; S2; S)

- **Real.** "High order 8 bits of address for Ethernet DMA transfers
  (defaults to 0xff)" [DMA2 E_BASE_ADDR]. The OpenBIOS source records that
  Solaris never programs it and assumes `0xff000000` (`sbus.c` `ob_le_init`,
  which therefore writes `0xff000000` at every boot). The real OBP writes it
  only when its `le` driver allocates DMA memory (`dma-alloc`, FCode
  `0x24d6`), i.e. only for a network boot.
- **Core.** `dma_eth_ba_i` has no reset (power-up 0) and survives `reset_n`
  (`ts_dmaux.vhd:238-243`); the write is gated by `w.be(3)` while the data is
  taken from lane 0 (`w.dw(31 DOWNTO 24)`), so a byte store to `+0x1c` (lane
  0) is ignored, and a byte store to `+0x1f` loads whatever lane 0 of the
  store data holds (the byte only if the CPU replicates it; *inference*).
- **Affected.** Real OBP + disk boot + Solaris: the LANCE DMAs to DVMA
  `0x00xxxxxx`, which the IOMMU passes through untranslated (IOM-4) into low
  physical memory: corruption as soon as the interface comes up
  (*inference*, from the OpenBIOS comment). Linux and NetBSD write it.
  The SS20 POST's (dead) loopback uses byte accesses.
- **Fix.** Reset to `0xff` on `reset_n`; gate by `be(0)`. **Test:** after
  reset, read `+0x1c` = `0xff000000`; `stb 0x12,[+0x1c]` then read
  `0x12000000`.

### DMA-3 E_INT_PEND gated by E_INT_EN (S3, S)

[DMA2 bit 0]: "Set when e_irq_ active" — independent of INT_EN, which only
gates `sb_e_irq_`. The core reads `eth_int = int_ether AND dma_eth_iena`
(`ts_io.vhd:462`) into bit 0 (`ts_dmaux.vhd:233-234`). A polling driver with
INT_EN = 0 never sees it (the OBP `le` driver polls CSR0 instead). The D_CSR
side is right (`dma_esp_int` is the raw ESP interrupt, `ts_esp.vhd:659`).

### DMA-4 Missing CSR bits and registers (S1-diag; S3 for OSes; M)

- D_CSR: SLAVE_ERR (6), ERR_PEND (1) and their causes, DRAIN/INVALIDATE
  effects, BURST_SIZE (19:18) readback, TWO_CYCLE/FASTER (21/22), TCI_DIS
  (23), EN_CNT (13)/TC (14) with D_BCNT, EN_NEXT (24) with D_NEXT_ADDR and
  D_NEXT_BCNT, DMA_ON (25), A_LOADED/NA_LOADED (26/27) [DMA2 D_CSR table].
- E_CSR: SLAVE_ERR, ERR_PEND, DRAIN, DSBL_* (11, 12, 16, 17), ILACC (15),
  BURST_SIZE, LOOP_TEST (21), TP_AUI (22) are not stored and read 0.
- EN_DMA and WRITE are stored but ignored: the ESP DMA runs whenever the ESP
  command has its DMA bit (`ts_esp.vhd:369`), and the direction comes from
  the SCSI phase (`ts_esp.vhd:699`) [DMA2: "D_EN_DMA … enables DMA requests
  from SCSI"].
- Affected: SS5 POST 9.2-9.10 and SS20 §9 DMA2 tests (diag). No OS found that
  needs them (Linux uses DMA_COUNT only for the ESC1 revision).
- Fix: store the RW bits; A_LOADED/DMA_ON are cheap; D_BCNT/EN_NEXT only for
  the POST. EN_DMA gating is cheap and closer to the hardware.

### DMA-5 Partial word lost at the end of a short DATA IN (S2 *(inference)*, M)

- **Real.** DMA2 drains its D-FIFO to memory on the ESP interrupt, on
  D_INVALIDATE/D_RESET and when the FIFO line fills [DMA2 "D_INVALIDATE",
  D_DRAINING].
- **Core.** Bytes from the target collect in `dma_buf`; the word is written
  only when the address reaches a word boundary or the count reaches 1
  (`ts_esp.vhd:788-792`). When the target changes phase before the count
  runs out and the last word is incomplete, those 1-3 bytes are never
  written, and the next D_ADDR write clears the byte enables (`:753-757`).
- **Affected.** Replies shorter than the allocation length whose length is
  not a multiple of 4 (for example an 18-byte REQUEST SENSE into a 255-byte
  buffer, odd INQUIRY lengths), if the target stops at the reply length
  (depends on the target engine; the current `scsi_mist*` targets were not
  checked).
- **Fix.** Flush `dma_buf` when the transfer ends (phase change, TI done),
  i.e. model the drain. **Test:** OS-level: `sg_requests`/`sg_inq` with a
  large allocation, compare the tail bytes.

### DMA-6 One single-word request per 4 bytes (S3, M)

`pw.burst <= PB_SINGLE` and one request per word (`ts_esp.vhd:718`, `:766`,
`:791`), where DMA2 uses 16- or 32-byte bursts [DMA2 D_BURST_SIZE]. Affects
disk throughput (see `design/scsi-hps.md` D9); the LANCE already uses
16-byte bursts.

---

## 6. ESP 53C9x

`ts_esp.vhd`, initiator only; the record bus to the targets is described in
[design/scsi-hps.md](../design/scsi-hps.md) §3.3, and §3.5 D11 already lists
the ESP-side protocol limits (no reselection, ENSEL/sync ignored, 16-bit TC,
no `0x38`, no D_BCNT). This section adds register and reset behaviour.

Chip detection works as follows on the core. CFG2 write/read-back masks bit 1
(`:295-300`), CFG3 is RW (`:304-310`), so NetBSD finds an **ESP200** and
turns on CFG2.FE (24-bit counts, `esp_sbus.c:442-446`); Linux finds a "FAST"
chip and reads the UID register to refine it (`esp_scsi.c:258`).

### ESP-1 State machine and interrupt flags survive `reset_n` (S2, S)

- **Real.** SBus reset (and D_RESET) resets the ESP completely [DMA2
  D_RESET "resets all SCSI interface state machines"].
- **Core.** `reset_n` resets only the FIFO, ATN, BSY and the command
  (`ts_esp.vhd:642-648`). `state`, `state_pre`, `inter`, `int_rst/disc/sr/so`,
  `istate`, `dma_mode`, `dma_stc`/`dma_ctc`, CFG1-3 and `dest_id` keep their
  values; only a D_CSR RESET clears the FSM and the interrupt
  (`:628-638`). Commands are accepted only in `sIDLE` (`:365-368`).
- **Effect.** A MiSTer reset during a transfer leaves the FSM in
  `sINFO_TRANSFER`/`sINFO_TRANSFER_CHANGE`/`sICCS`, waiting for a REQ from
  a target that `reset_n` has already idled: every command is ignored until
  software pulses D_CSR RESET. OpenBIOS (`esp.c espdma_init`), Linux
  (`sbus_esp_reset_dma`), NetBSD (`lsi64854_reset`) and the OBP esp FCode
  (`t81e`: wait bit 10 = 0, set and clear `0x80`) all pulse it before use, so
  it recovers; any code that talks to the ESP first does not. With DMA-1 the
  stale `inter` is also a live level-4 interrupt.
- **Fix.** Put the FSM, interrupt and mode registers in the `reset_n` block.

### ESP-2 Register `0x38` (TCHI / UID) missing, reads stale data (S2, S)

- **Real.** On the FAS family, register 0xE (`0x38`) is the high byte of the
  24-bit transfer counter when CFG2.FE is set, and reads the chip's unique ID
  after a reset [Linux `esp_scsi.h`: `ESP_TCHI`/`ESP_UID` 0x0e; NetBSD
  `NCR_TCH`, `NCR_UID`].
- **Core.** Not decoded; with no default `dr` (DEC-3) it returns the data of
  the previous ESP access.
- **Affected.**
  - NetBSD (ESP200, FE on): the DMA completion computes the residue as
    `TCL | TCM<<8 | TCH<<16` when TC is not reached
    (`lsi64854.c:442-445`); TCH returns the value of the preceding register
    read (usually TCM), so the residue is overestimated, `trans` goes
    negative and is clamped to the full size (`:453-465`): a short transfer
    is reported as complete. TCH is also written for every transfer, and a
    transfer of exactly 64 KiB works only because the core treats TC = 0 as
    65 536.
  - Linux: `esp_reset_esp` reads UID after writing the command `0x80`, gets
    `0x80`, family `0x10`, and settles on FAS100A — deterministic by
    accident.
- **Fix.** Implement TCHI (extend `dma_stc`/`dma_ctc` to 24 bits when CFG2.FE)
  and return a fixed UID after reset (FAS236 family `0x02` per Linux, or 0;
  open question 5).

### ESP-3 Message Accepted always means "disconnected" (S2, M)

`CMD_MSGACC` flushes the FIFO and raises a Disconnected interrupt
(`:424-435`, "we assume a disconnection after this command"). On a real ESP
Message Accepted releases ACK and the *target* decides what follows; only
after COMMAND COMPLETE does it go bus-free. Any other message-in (an SDTR or
WDTR reply, SAVE DATA POINTER, MESSAGE REJECT) ends the nexus on the core.
It works today only because the targets never send such messages; the
Solaris/NetBSD sync negotiation (INQUIRY advertises Sync, scsi-hps D10) and
disconnect/reselect cannot. Fix together with the new target engine: after
MSGACC, wait for the next REQ (phase) or bus-free, like `sINFO_TRANSFER`.

### ESP-4 Unknown commands ignored silently (S2, S)

`WHEN OTHERS => NULL` (`:475`): Select with ATN3 (`0x46`), Reset ATN
(`0x1b`), Disable Selection (`0x45`), the target-mode commands (`0x2x`) and
Transfer Pad in the wrong phase produce no interrupt. The real chip reports
Illegal Command (INTR bit 6) with an interrupt, so drivers do not hang.
NetBSD and Linux use SELATN3 for tagged commands (only if the target
advertises tagged queuing). Fix: raise ILL CMD for anything unimplemented;
implement SELATN3 and RATN (small).

### ESP-5 FLUSH sets "function complete" without an interrupt (S3, S)

`CMD_FLUSH` sets `int_so` (`:388`) but not `inter`; the next INTR read shows
a stale FC bit. The real Flush FIFO command generates no interrupt and sets
no status.

### ESP-6 Other ESP details (S3)

- Chip reset (`0x02`, `:391-405`) leaves CFG2/CFG3, the command register
  readback and `dest_id`; the real reset clears CFG2/3 (Linux rewrites them).
- STATUS bits 3 (GCV), 5 (parity), 6 (gross error) never set (`:220`);
  INTR bit 0-2 (target-mode selected/reselected) never set (reselection is
  absent, D11).
- Selection time-out is immediate and the time-out register is ignored
  (`:547-566`, `:613-621`) — fine without real cabling.
- INTR read sets the sequence step to 4 (`:242`) instead of clearing it;
  drivers read SEQ before INTR (Linux `esp_process_event`), so harmless.

---

## 7. LANCE

`ts_lance.vhs` (the `.vhd` is generated; `asm_lance.rb`) is a microcoded
Am7990: RAP/RDP, CSR0-3, the init block, TX/RX rings, 16-byte DVMA bursts
with E_BASE as A[31:24] (`:1089`), a 1.6 ms TX poll (`:235`, `:631-641`).
Enough for Linux `sunlance`, NetBSD `le`, OpenBIOS and the OBP `le` driver's
normal path. The only MAC in `files.qip` is `ts_lance_mac_rmii_norxen.vhd`
and its PHY pins are tied off (`SunSparcStation.sv:409-412`,
`ss_core.vhd:793-801`); phase 5.2 replaces it with an HPS-bridged MAC, so
LAN-2/LAN-3/LAN-7 are requirements for that MAC as much as fixes.

### LAN-1 No loopback (S1 for net boot, M)

- **Real.** Init-block MODE bit 2 LOOP (with bit 6 INTL, internal) sends
  transmitted frames straight back into the receiver [Am7990 MODE; DMA2
  E_LOOP_TEST for the transceiver side].
- **Core.** `lopo` (LOOP) is declared and never used (`ts_lance.vhs:246`,
  same in the generated `.vhd`); INTL is not even aliased; the MAC interface
  has no loop path (`ts_pack.vhd:47-77`).
- **Affected.** The OBP `le` driver's `open` runs the internal loopback test
  (`t9da` in `fcode-70011f00-espdma.txt` at `0x3551`; messages "Internal
  loopback test --", "Did not receive expected loopback packet.", "Wrong
  packet length; expected 36") and fails the open when it fails: `boot net`
  on the real OBP prints "Can't open boot device", as it does under QEMU
  whose loopback returns the wrong length (`ss5-obp/qemu-console.txt`). The
  SS20 POST's LANCE loopback tests are dead code.
- **Fix.** In `ts_lance` (independent of the MAC): when LOOP is set, feed
  the TX byte stream into the RX path with a computed CRC (INTL) or through
  the MAC (external). **Test:** bare-metal: init block MODE `0x0044`, one
  36-byte frame, expect it in RMD0's buffer with MCNT 40 (with CRC); then OBP
  `test net`.

### LAN-2 No receive-buffer size check or chaining (S2; S1 once HPS Ethernet lands; M)

`rmd_bcnt` (RMD2 BCNT) is declared (`ts_lance.vhs:292`) and never used: the
copy loop writes until the MAC's end-of-frame (`LOOP_STORE`, `:846-876`)
whatever the buffer size, and never chains to the next descriptor
("no receive chaining", header `:15-22`). The MAC accepts frames up to 1792
bytes (`ts_lance_mac_rmii_norxen.vhd:343`). Drivers use 1536/1544-byte
buffers (Linux `PKT_BUF_SZ`, NetBSD `LEBLEN`), so a long frame overwrites the
next buffer or descriptor. A Linux tap on the HPS can deliver frames larger
than 1518 bytes unless offloads are off (*inference*). Fix: stop at BCNT and
continue in the next descriptor (STP/ENP), or at least drop with BUFF/OFLO.

### LAN-3 Promiscuous mode and multicast hash (S3; S2 for bridging; S)

MODE PROM (`initvec(15)`, `ts_lance.vhs:244`) is never used and is not in
`type_mac_rec_w`; the MAC accepts a frame if the destination equals PADR or
has the group bit (`ts_lance_mac_rmii_norxen.vhd:363-369`) and never
compares LADRF (it computes `rec_dhash`, `:306`, and drops it). So all
multicast is received (harmless) and promiscuous mode (tcpdump, bridging,
some routing daemons) cannot work. Requirement for the HPS MAC.

### LAN-4 E_CSR RESET is partial (S2 *(inference)*, S)

The `reset` input (E_CSR bit 7) clears RAP, RINT, TINT, IDON, INEA, STOP=1,
STRT, INIT (`ts_lance.vhs:480-489`) but not TXON, RXON, MISS, TDMD,
`init_pulse`/`init_pend`, the microcode PC, `tx_act`/`rx_act` or the DMA
burst state, which only `reset_n` clears (`:490-504`, `:1048-1068`,
`:1117-1128`). [DMA2]: E_RESET asserts the LANCE's reset pin and resets the
Ethernet state machines. A driver restart during traffic (Linux
`lance_reset` on a TX time-out, `ifconfig down/up`) can let the microcode
finish a descriptor write-back into the ring the driver is re-initialising.
Fix: OR `reset` into the microcode and DMA resets.

### LAN-5 CSR0/CSR3 read details (S3, S)

- TDMD reads 0 (`:416`); on the Am7990 it reads 1 until the demand is served.
- STOP clears TINT/RINT/MISS/TXON/RXON but not IDON (`:435-443`); the real
  STOP clears every CSR0 bit but STOP.
- CSR3 bits 15:4 return a debug word (microcode PC, DMA state,
  `:428-429`) instead of 0.
- BABL, CERR, MERR are never set; CSR1/CSR2 are writable while running
  (real: only with STOP).
- `bswp` (CSR3.BSWP) is stored but the byte order is fixed big-endian.

### LAN-6 Alignment limits (S3, S)

The init block must be 32-bit aligned (datasheet: 16-bit), TX buffers 16-bit
aligned (datasheet: any byte), and chained TX segments even-sized
(`ts_lance.vhs:15-22`; `iadr & '0'` at `:755`, halfword steps at `:879-897`).
Linux, NetBSD, OpenBIOS and the OBP use aligned buffers; a driver that
chains odd-length mbufs would send corrupt frames (*inference*).

### LAN-7 No PHY, no errors (S3)

With `rmii_clk` tied to 0 the PHY domain never leaves reset, `live` stays 0,
and `fifordy` is forced to 1 (`ts_lance_mac_rmii_norxen.vhd:185-197`,
`:707`): every frame "transmits" at once with no LCAR/RTRY, and nothing is
ever received. The FIFO level counter keeps counting with nobody draining it
(`natural RANGE 0 TO 128`, `:701-705`), which would be a range error in
simulation. Expected until the HPS MAC.

---

## 8. ESCC, keyboard and mouse

Two `ts_sport` instances: `sel.kbm` (keyboard on A, mouse on B) and
`sel.sport` (ttya on A → the MiSTer UART through `ts_aciamux`; ttyb on B →
an ACIA on `rxd4/txd4`), `ts_io.vhd:480-521`, `ts_core.vhd:1114-1140`. The
register pointer, WR1/3/4/5/9/12/13/15 storage, RR0/1/2/3/8/10/12/13, the
status-modified vector and TX/RX interrupts are implemented; the PROMs'
polled init tables and Linux `sunzilog`/NetBSD `zs` normal paths work.

### ZS-1 MIE ignored (S3, S)

WR9 bit 3 (Master Interrupt Enable) is not stored (`ts_sport.vhd:296-318`);
`int` is simply RX-IP or TX-IP of either channel (`:693`). On the chip no
interrupt leaves without MIE. Only code that enables RX interrupts with MIE
off (none found) would see a difference.

### ZS-2 No break detection or external/status interrupts (S2, M)

- **Real.** RR0 bit 7 Break/Abort, bits 3/5 DCD/CTS, bit 4 SYNC; WR15 enables
  and the External/Status interrupt report them; a BREAK on the console line
  is the serial-console abort (Stop-A) for OBP, SunOS, Solaris and Linux
  (`sunzilog` sends it to SysRq/the PROM).
- **Core.** `rx_break` is a constant `"00"` (`:120`); RR0 returns
  `break & 1000 & TxE & 0 & RxA` (`:389`): CTS and DCD always 0; no
  ext/status IP in RR3 (`:431-434`). On ttya the BREAK is consumed by
  `ts_aciamux`, which uses BREAK+`'3'`/`'4'` to switch between the console
  and the debug monitor (`ts_aciamux.vhd` header; `ACIABREAK => true`,
  `ss_core.vhd:286`).
- **Affected.** With a serial console (OSD "boot console serial") there is no
  way to break into `ok` from a running OS or during auto-boot; together with
  KBD-1 there is no way at all. `getty` on ttya with modem control waits for
  DCD (*inference*; the Sun ports' DCD behaviour with no cable is open).
- **Fix.** Pass a BREAK (or an OSD "send break") through to RR0 bit 7 + ext
  status IP, keep the debug switch on a different key; report DCD/CTS = 1
  when nothing is attached (open question 8).

### ZS-3 Baud rate and format ignored (S3, S + doc)

WR12/13 are stored and readable (`:338-346`, `:443-459`) but the line rate
is fixed by the sink: ttya is the MiSTer UART at 115200 8N1
(`ts_core.vhd:1090-1112`, `SERIALRATE => 115200`), the keyboard/mouse ACIAs
at 1200 (PS/2 build: byte streams). WR3/4/5 character size, parity and stop
bits are ignored. The PROMs program 9600; the user must set the terminal to
115200. `tests/cpu/README.md` says to read ttya "at 9600 baud", which is
probably wrong on the core (*inference*).

### ZS-4 "Reset highest IUS" clears a TX interrupt (S3 *(inference)*, S)

WR0 command 7 clears channel A's TX IP, else channel B's (`:214-221`). On the
chip it only resets the highest Interrupt Under Service bit, which is never
set on a Sun (no interrupt-acknowledge cycle), and leaves IP alone. A driver
that ends its handler with this command after servicing an RX interrupt can
lose a pending TX-empty interrupt and stall output until the next write
(Solaris `zs` issues it at the end of each interrupt; *inference*).

### ZS-5 Channel reset leaves RX IP set (S3, S)

A WR9 channel/hardware reset clears `rx_en`/`rx_ie` (`:306-318`), which
clears `rx_avail` but not `rx_ip`: only a data read clears it (`:666-674`).
A reset with a character pending leaves level 12 asserted until the driver
reads the data register.

### ZS-6 RR15, RR1 errors, loopback (S3, S)

RR15 reads 0 instead of the WR15 enables (`:461-471`); RR1 never reports
parity, overrun or framing (`:401`); WR14 local loopback/auto echo are not
implemented (the Sun OBP's `test ttya`-style checks and NetBSD's `zs` don't
need them on the normal path).

### ZS-7 ttyb receive pin undriven (S3, S)

`rxd4` is declared in `ss_core.vhd:170` and never assigned, so synthesis ties
it to 0 (*inference*: Quartus implicit default). The ACIA sees a permanent
start bit, waits for a stop bit that never comes (`rtl/peri/acia.vhd`
receive process) and delivers nothing; `txd4` goes nowhere. ttyb is present
but dead; tie `rxd4` to 1 and, if wanted, route it to a MiSTer port.

### KBD-1 No Stop key or left-block keys (S2, S)

The PS/2 → Sun table (`ts_ps2sun.vhd:62-580`) produces 102 Sun keycodes and
none of `0x01` (Stop/L1), `0x03` (Again), `0x19` (Props), `0x1a` (Undo),
`0x31` (Front), `0x33` (Copy), `0x48` (Open), `0x49` (Paste), `0x5f` (Find),
`0x61` (Cut), `0x76` (Help). Stop-A (abort to `ok`), Stop (skip POST),
Stop-D (force diag) and Stop-N (reset NVRAM to defaults — the standard
recovery with the real OBP) are impossible. Fix: map free PS/2 keys (for
example F11 → Stop, the E0-prefixed Windows/Menu keys or the Pause key → L
block) and document it.

### KBD-2 Mouse deltas wrap (S3, S)

Byte 2/3 of the PS/2 packet are sent as the Mouse Systems X/Y without using
the X8/Y8 sign bits or the overflow bits (`ts_ps2sun.vhd:861-866`); a delta
beyond ±127 (fast movement) changes sign. Fix: clamp to −128..127 using the
9-bit value. The emulation never sends a command to the PS/2 mouse
(`m_tx_req <= '0'`, `:817`); MiSTer's HPS PS/2 mouse streams anyway.

### KBD-3 Keyboard protocol details (S3, S)

`ts_sunkb` answers reset with `ff 04 7f`, layout with `fe <layout>`, latches
LEDs (`ts_sunkb.vhd:63-199`). It never sends the idle code `0x7f` after the
last key is released (Sun type 4/5 keyboards do; kernels use it to release
stuck modifiers), and bell/click (`0x02/0x03/0x0a/0x0b`) are ignored.
`ts_kms.vhd` is in `files.qip` but instantiated nowhere.

---

## 9. NVRAM, TOD, IDPROM

`ts_rtc.vhd` (MK48T08 clock at `0x1ff8-0x1fff`) in front of `iram_rtc.vhd`
(8 KiB block RAM initialised from the bitstream, never saved). Register
widths match the PROMs' masks (SS5 POST 10.2, SS20 TOD test). The MiSTer RTC
seeds the clock, re-based to 1968 as Linux (`time_32.c` `yy_offset = 68`),
NetBSD and QEMU (`base-year 1968`) expect (`ss_core.vhd:831-852`).

### TOD-1 W=1, R=0 swaps the registers every clock (S2; S1-diag; S)

- **Real.** "Setting the WRITE bit to 1 halts updates to the TIMEKEEPER
  registers … resetting the WRITE bit to 0 then transfers the values of all
  time registers to the actual counters" (MK48T08 data sheet); READ freezes
  the user registers for reading.
- **Core.** Every clock, `IF cr='0' THEN mem_* <= cpt_*` (`ts_rtc.vhd:144-152`)
  and `IF cw='1' THEN cpt_* <= mem_*` (`:196-204`). With W=1 and R=0 both
  run: a field written by the CPU (`:154-193`) and the old counter value
  trade places on every clock, and whichever is in `cpt_*` on the clock W
  goes back to 0 is kept. Each field ends up new or old at random (clock
  parity of the write versus the W clear).
- **Affected.** Exactly the sequence OSes use to set the clock: Linux
  `rtc-m48t59.c:116-132` and NetBSD `mk48txx.c:236-238` set W by
  read-modify-write with R = 0 — `date`/`hwclock -w`, ntpd's 11-minute sync,
  Solaris `date` (*inference* for Solaris). The PROMs' TOD test (control
  `0x80`) reads back while W=1 and fails at random (diag). The HPS re-seeds
  the clock only when it pushes a new RTC value (`rtcset`).
- **Fix.** Copy `cpt → mem` only when `cr='0' AND cw='0'`, and load
  `mem → cpt` on the W falling edge (or continuously while W=1, which is
  then safe). **Test:** control `0x80`, write seconds `0x42`, read it 1000
  times (always `0x42`), clear W, after 1.5 s read `0x43`/`0x44`.

### TOD-2 Calibration, sign, FT, KS not stored (S3, S)

The control byte keeps only W and R (`:157-160`) and reads CAL[4:0] and S as
0 (`:294`); FT (day bit 6) and KS (hours bit 7) are not implemented. Only
calibration software notices.

### TOD-3 Leap-year rule (S3, S)

February 29 exists when `cpt_y(1 DOWNTO 0) = "00"` (`ts_rtc.vhd:132`), the
low two bits of the *BCD* year. That equals year mod 4 = 0 only when the
tens digit is even. With the 1968 re-basing the stored years 0x50-0x59
(2018-2027) and 0x70-0x79 (2038-2047) get it wrong (2024 not leap, 2022 and
2026 leap); 2028-2037 are right. Only matters if the core runs across the end
of February without a re-seed. Fix: leap = (T even and U ∈ {0,4,8}) or
(T odd and U ∈ {2,6}).

### TOD-4 ST cleared by reset (S3, S)

`st` (seconds bit 7, oscillator stop) is reset by `reset_n` (`:268-272`); on
the chip it is battery-backed and survives resets. Resetting W and R is
fine.

### TOD-5 The initial NVRAM image (S1 for the diag byte; S2 for the IDPROM; M)

Decoded from `iram_rtc.vhd` INIT0-3 (byte n is in `INIT(n mod 4)(n / 4)`):

| Offset | Content | Meaning for the real OBP |
|---|---|---|
| `0x0000` | `70 1a 00 02 "system"` | an OpenBIOS/CHRP partition header; **byte 1 = `0x1a` is `diag-switch?`** for both PROMs (non-zero = true) |
| `0x0020` | `7f 20 01 fb "free"` | OpenBIOS free partition |
| `0x1fd8` | `01 72 52 54 00 12 34 56 00 00 00 00 00 00 00 05` | IDPROM: format 1, type **`0x72`** (SS10/20) in both builds, MAC `52:54:00:12:34:56` (QEMU's default), date 0, serial 0, checksum `0x05` (valid) |

- OpenBIOS rewrites the IDPROM at every boot (`obio.c ob_nvram_init`: type
  `0x80` or `0x72`, MAC `08:00:20:12:34:56` — a Sun OUI, identical for every
  unit, hostid `12 34 56`) and uses its own partition layout, so it never
  looks at `diag-switch?`.
- The real OBP reads byte 1 in machine code before any Forth runs (SS5
  `boot_puts` `0x7000c28c` and the POST decision; SS20 `rputs_if_diag`,
  `reset_kbd_decide`): with `0x1a` it prints the boot messages and **runs the
  POST in diagnostic mode on the first boot**, where cpu.md MMU-1/MMU-2 stop
  or crash it. The Forth side then finds a bad configuration checksum and
  writes defaults (QEMU shows the same: "Incorrect configuration checksum;
  Setting NVRAM parameters to default values"), which fixes byte 1 only until
  the core is reloaded (TOD-6).
- The SS5 OBP accepts the IDPROM only if type = `real-machine-type` (`0x80`,
  `forth-dictionary.txt` word at `0x7002ddd0`): the SS5 build prints "The
  IDPROM contents are invalid" and publishes a wrong `idprom` property. Every
  unit has the same MAC and hostid; two cores on one LAN (HPS Ethernet)
  collide, and hostid-licensed software sees the same host.
- **Fix.** Per-build images: zeros (so `diag-switch?` is false and OBP writes
  its defaults) plus a valid IDPROM with type `0x80` (SS5) / `0x72` (SS20); a
  locally administered MAC and serial derived per MiSTer (for example from
  the HPS's own MAC through `hps_io`, or a random seed saved with the NVRAM).
  Keep OpenBIOS working: it overwrites the IDPROM anyway.

### TOD-6 NVRAM not persistent (S2, M, glue)

The NVRAM is FPGA block RAM initialised from the bitstream: it survives
`reset_n` (correct) but not a core reload, so the real OBP's variables
(`boot-device`, `auto-boot?`, `diag-switch?`, `nvramrc`) are lost at every
start. Saving it to the SD card is a MiSTer-glue item (video-audio-glue.md);
the chipset side is a second port on `iram_rtc` for the HPS.

---

## 10. System control, AUX, LED, power

### AUX-1 System control/status register (S1, S + glue)

- **Real.** SS5 Slavio `0x71f0_0000` [Slavio Fig. 6-6]: bit 0 SR (write 1 =
  software reset, reads 0), bit 1 RS (set by a software reset, cleared by
  power-on; read/clear), bit 4 WD (set by a watchdog reset request from the
  CPU's error mode; read/clear), other bits read 0. SS20 `0xf_f1f0_0000`
  [S4M §5.1.1]: bit 0 SW_RST, bit 1 SW_RST_STAT, bit 2 DIAG switch, bit 3
  RST.SW (switch reset). A software reset resets everything but leaves the
  CPU registers (the PROM passes the POST result in `%g1-%g7`) and memory.
  QEMU keeps `SYS_RESETSTAT` across its reset (`slavio_misc.c:106-111`,
  `:337-350`).
- **Core.** Writes: `sysreset <= req AND wr AND sel.syscon AND dw(0)`
  (`ts_io.vhd:232`) → `ss_core` restarts its reset FSM with
  `reboot_pending`, which **zeroes all of DRAM** and holds `reset_n`
  (`ss_core.vhd:1019-1024`, `:928-976`). Reads: `sel.syscon` is not in the
  read mux, so the register reads `0xBADACCE5` (`ts_io.vhd:760`): SR=1,
  RS=0, bit 2 (SS20 DIAG) = 1, bit 3 = 0, WD=0, reserved bits set.
- **Affected.** Both real PROMs: every power-on path ends with SW_RST
  (SS5 `post_exit_soft_reset` → `sysctl_soft_reset`, whether the POST ran or
  not; SS20 `obp_prep`), and only RS (SS20: RS or RST.SW) sends the restarted
  PROM to `obp_start`. On the core the PROM restarts on the power-on path,
  sends SW_RST again, and never reaches OBP. The watchdog path (WD) cannot be
  taken either (cpu.md IU-1: error mode halts instead of resetting). OpenBIOS
  uses SW_RST only for `reset-all` and never reads the register.
- **Fix.** A syscon register (in `ts_io`, with its RS/WD flops in `ss_core`,
  outside `reset_n`): RS set by SW_RST and cleared by power-up and the OSD
  reset (or map the OSD reset to the SS20's RST.SW), WD set by the CPU's
  error mode (cpu.md IU-1), bit 2 = 0 (no diag switch) or an OSD option, all
  other bits 0; W1C semantics for RS/WD. Keep DRAM on a software reset
  (cpu.md CFG-2) and make sure the IU register file survives `preset` (CPU
  side). **Test:** bare-metal: read `0x71f00000` after power-up (expect 0),
  write 1, after the reset expect bit 1 set and `%g1` preserved.

### AUX-2 AUXIO layout (S3, S)

- **Real.** SS5 AUX1 `0x7190_0000` (byte) [Slavio Fig. 6-21]: bit 0 LED,
  bit 1 floppy TC (write 1 → pulse, reads 0), bit 2 monitor/mouse mux, bit 3
  link-test enable, bit 5 floppy density sense, others 0. AUX2 `0x7191_0000`:
  bit 0 power off, bit 1 clear power-fail, bit 5 power fail, reset 0.
  SS20 AUXIO0 `0xf_f180_0000`, AUXIO2/power at `0xf_f1a0_1000`.
- **Core.** The address holds a core-private word: byte 0 bit 0 = LED
  (write `w.dw(24)` with `be(0)`), bytes 1-3 = HWCONF, the ETHERNET flag and
  `swconf` (OSD switches read by OpenBIOS) (`ts_dmaux.vhd:247-254`).
  +4..+0x1c hold the core's I²C/MDIO/video-control, mask-rev, tick counter and
  SD registers. On the SS5 the AUX2 address aliases this register, so a
  power-off write (bit 0) turns the LED on; on the SS20 AUX2 is selected
  (`sel.auxio1`) but has no register and reads `0xBADACCE5`. The SS20 OBP's
  `AUXIO0 |= 4` is dropped. No OS found depends on the other AUX bits (Linux read-modify-writes AUX1
  with `AUXIO_ORMEIN4M` set, `auxio_32.c:94-95`, and uses it for the LED).
- **Fix.** Decode AUX2 separately; add the TC/mux/LTE bits as RW-ignored;
  move the private configuration word away from the real AUXIO byte once the
  real OBP is the default (OpenBIOS reads it; coordinate).

### AUX-3 Missing slavio registers (S3, S)

SS5 configuration register `0x7180_0000` (S = SuperSPARC mode, PFD enable,
modem ring; reset 0), diagnostic message `0x71a0_0000` (8-bit RW, kept across
resets), modem `0x71b0_0000` [Slavio]: absent, read `0xBADACCE5`. The SS20
LED register (16-bit write-only [S4M §5.4.1]) is selected but ignored (fine),
the SS20 diagnostic message registers `0xf_0000_1000-3` are in the absent EMC
space. OBP creates a `slavioconfig` node for `0x7180_0000` but no code found
reads it.

Power-off (`AUX2` bit 0, Linux `auxio_power` / OpenBIOS `power` node) has no
MiSTer equivalent; the OS halts and spins, which is acceptable.

---

## 11. Reset-state audit

"Real" is the value after power-on or SBus/software reset, from the cited
source; "Core" is the value after `reset_n` (which every reset asserts, see
the introduction). Registers the core does not implement are omitted.

| Block | Register / state | Real reset value (source) | Core after `reset_n` (file:line) | OK | ID |
|---|---|---|---|---|---|
| intctl | per-CPU soft pending | 0 [S4M §5.7.1] | 0 (`ts_inter.vhd:309-312`) | yes | |
| intctl | mask (ITMR) | all mask bits set [S4M §5.7.3, Slavio] | `0x7FFFFFFF` (`:313`) | no (MA, reserved) | INT-2 |
| intctl | ITR | 0 [Slavio Table 6-21] | **not reset** (`:93`, `:297-314`) | no | INT-1 |
| intctl | IRL outputs | 0 | recomputed from state (`:421-431`) | yes | |
| timer | limits, counters | 0 [Slavio]; limit 0 [S4M] | limit 0, counter `0x200` (`ts_timer.vhd:260-265`) | ~ | TMR-5 |
| timer | L bits | 0 | 0 (`:257`, `:267`) | yes | |
| timer | config T0-T3 | 0 (counter/timer) [S4M §5.3.1] | 0 (`:258`) | yes | |
| timer | user-timer RUN | 0 [Slavio] | 0 (`:259`) | yes | |
| timer | prescaler phase | – | not reset (`:83`) | n/a | |
| IOMMU | control ME/DE/RANGE | 0 [S4M §5.8.1] | 0 (`ts_iommu.vhd:230-232`) | yes | |
| IOMMU | base | undefined | 0 (`:234`) | yes | |
| IOMMU | IOTLB | invalid | invalid (`:378-380`) | yes | |
| IOMMU | mask rev (`0x3018`) | chip constant | OSD value (`ts_dmaux.vhd:338`, `:356`) | yes | |
| MSI | arbiter enable (SS20) | `0x00000003` [S4M §5.1.2] | absent, reads 0 | no | IOM-1 |
| MSI | MID/SBAE (SS5) | MID 8, SBAE [MS2 §5.7.10] | absent, reads 0 | no | IOM-1 |
| MSI | AFSR (SS5) | bits 23:20 = `1000` [MS2 §5.7.5] | absent, reads 0 | no | IOM-1 |
| DMA2 | D_CSR INT_EN, RESET, WRITE, EN_DMA | 0 [DMA2 D_CSR note] | **not reset** (`ts_dmaux.vhd:167-170`, `:326-339`) | no | DMA-1 |
| DMA2 | D_ADDR | indeterminate [DMA2] | not reset (`ts_esp.vhd` `dma_a`) | yes | |
| DMA2 | E_CSR INT_EN, RESET | 0 [DMA2 E_CSR note] | 0 (`ts_dmaux.vhd:327-328`) | yes | |
| DMA2 | E_BASE_ADDR | `0xff` [DMA2] | **not reset**, FPGA power-up 0 (`:238-243`) | no | DMA-2 |
| ESP | FIFO, ATN, BSY, command | cleared by chip/SBus reset | cleared (`ts_esp.vhd:642-648`) | yes | |
| ESP | FSM, interrupt flags, seq step, DMA mode, TC, CFG1-3, dest ID | idle / 0 (SBus reset → ESP reset) | **not reset** (only D_CSR RESET clears FSM and flags, `:628-638`) | no | ESP-1 |
| ESP | DMA engine request/ready flags | idle | reset (`:814-819`) | yes | |
| LANCE | CSR0 (STOP=1), RAP, INEA, TXON/RXON, MISS, TDMD | STOP=1, others 0 | reset (`ts_lance.vhs:490-504`) | yes | |
| LANCE | CSR3 BSWP | 0 | not reset (`:201`) | no (harmless) | LAN-5 |
| LANCE | microcode, rings, DMA | idle | reset (`:1048-1068`, `:1117-1128`) | yes | |
| LANCE | state after E_CSR RESET only | full LANCE reset [DMA2 E_RESET] | CSR0 flags only (`:480-489`) | no | LAN-4 |
| ESCC | WR1/3/4/5/9/12/13 fields, pointer, vector | hardware reset values | reset (`ts_sport.vhd:512-538`) | yes | |
| ESCC | TX/RX buffers, IP, mask flags | 0 | reset (`:624-632`, `:677-681`) | yes | |
| ESCC | WR15 break enable | 0 | not reset (`:367`) | no (unused) | |
| keyboard | emulation FSM, PS/2 FIFOs | – | reset (`ts_sunkb.vhd:203-205`, `ts_ps2sun.vhd`) | yes | |
| TOD | clock counters | keep running | keep running (not reset) | yes | |
| TOD | W, R | battery-backed | 0 (`ts_rtc.vhd:268-271`) | ~ (harmless) | |
| TOD | ST | battery-backed | 0 (`:271`) | no | TOD-4 |
| NVRAM | contents | battery-backed | kept across `reset_n`, lost on core reload | ~ | TOD-6 |
| syscon | RS / WD / RST.SW | RS=1 after SW reset, 0 after POR | not implemented (`0xBADACCE5`) | no | AUX-1 |
| AUX | AUX1 LED/TC/MMUX/LTE | 0 [Slavio] | LED 0 (`ts_dmaux.vhd:329`) | yes | |
| AUX | AUX2 | 0 [Slavio] | not implemented | n/a | AUX-2 |
| core-private | CONF0 video control, I²C | – | reset (`ts_dmaux.vhd:330-337`) | yes | |
| core-private | MDIO out/enable, tick counter | – | not reset (`:268-270`, `:293-302`) | n/a | |

**Candidates for "reboot MiSTer between OSes"** on the chipset side: INT-1
(ITR on the SS20), ESP-1 + DMA-1 (stuck ESP, stale level-4 interrupt),
DMA-2 (E_BASE left from the previous OS), LAN-4 (only if the reset comes
through E_CSR). On the CPU side see cpu.md C-2 and CFG-1.

---

## 12. Test plan

Bare-metal tests in the `tests/cpu` style (boot PROM image, ttya output),
one group per block, most lifted from the POST catalogues:

| Test | Checks | Findings |
|---|---|---|
| `syscon_reset` | syscon reads 0 at power-up; SW_RST; after it RS = 1 and `%g1` kept; watchdog sets WD | AUX-1 |
| `bus_error` | SS5 POST 4.6/4.7: SBus `0x7cc00000` → tt 0x29, SFSR `0x816`; EBus `0x71400300` → `0x416`; SS20: `0xe_0000_0010` | DEC-1 |
| `slave_size_error` | byte store to D_CSR/E_CSR/RAP/RDP → SLAVE_ERR, AFSR `0x93820000`, AFAR | DEC-2, DMA-4, IOM-1 |
| `intctl_regs` | SS20 System Interrupt Regs (`0xf87fffff`), ITR reset, level-15 clear | INT-1, INT-2, INT-3 |
| `timer_rate` | ticks per TOD second = 2 000 000 | TMR-1 |
| `user_timer_n` | PROCn user timer on every CPU (RUN bit, L bit) | TMR-2, TMR-3, TMR-4 |
| `timer_period` | limit L → L−1 ticks between L bits | TMR-5 |
| `iommu_regs` | SS5 POST 4.1-4.3 masks; SS20 MSI/MSBI walk; IMPL | IOM-1, IOM-2, IOM-3 |
| `dma2_regs` | reset values (D_CSR `0xa0000000`, E_BASE `0xff000000`), byte write to E_BASE | DMA-1, DMA-2 |
| `esp_regs` | SS5 POST 9.11 plus `0x38` after reset, illegal command interrupt, reset during a transfer | ESP-1, ESP-2, ESP-4 |
| `lance_loopback` | MODE `0x0044`, one 36-byte frame → RX with MCNT 40; E_CSR reset mid-transfer | LAN-1, LAN-4 |
| `tod_write` | W=1/R=0 write-read-back loop, then run | TOD-1 |
| `zs_break` | BREAK on ttya → RR0 bit 7 and ext/status IP (needs a UART break from the host) | ZS-2 |

OS-level checks: Linux `hwclock -w` then `hwclock -r` 50 times (TOD-1);
`ntpd -q` drift on the SS5 (TMR-1); NetBSD `dmesg` ESP variant and a
`scsictl inquiry` with a large allocation (ESP-2, DMA-5); OBP `boot net` and
`test net` (LAN-1); an OSD reset during `dd if=/dev/sd0` followed by a boot
(ESP-1, DMA-1); SS20 Linux SMP: move IRQs to CPU 2, reset, boot (INT-1).

---

## 13. Open questions

1. **Free-run limit 0**: does the counter interrupt on overflow (every ~2 s,
   [Slavio]) or never ([S4M], QEMU)? (TMR-6)
2. **Counter period**: does a real counter show the limit value for one tick
   (period L) or skip it (period L−1, as QEMU and the drivers' "+1" suggest)?
   (TMR-5)
3. **SS20 IOMMU IMPL/VER**: QEMU's `0x13000000` is the only source; confirm
   on a real SS20 (read pa `0xf_e000_0000` at the OBP `ok` prompt, or
   NetBSD's "iommu0: version" attach line). (IOM-2)
4. **E_BASE_ADDR lane**: [DMA2] documents the register as bits 7:0 of an
   8-bit register, Linux and OBP write the value in bits 31:24 of a word at
   `+0x1c`, the SS20 POST uses byte accesses at `+0x1c`. The byte at offset
   `0x1c` is bits 31:24 on a big-endian bus, so all three may agree; confirm
   that a word write carries the base in 31:24 on the real chip. (DMA-2)
5. **ESP identity**: what does the real SS5/SS20 ESP return in register 0xE
   after reset, and is it an ESP200/FAS236 (the SS5 service manual and a
   real `dmesg` would tell)? This decides what ESP-2 should return.
6. **OBP's own esp FCode** (`fcode-70011f00-espdma.txt`): does it use any
   command or status the core lacks (SELATN3, the Illegal Command interrupt,
   TCHI)? A simulation of `boot disk` with the real PROM answers it; OpenBIOS
   uses a very similar subset.
7. **Solaris and E_BASE**: the OpenBIOS comment is the only evidence that
   Solaris relies on the reset value `0xff`; check with Solaris 2.x on the
   real OBP (network up after a disk boot). (DMA-2)
8. **DCD/CTS with nothing attached**: what do the Sun ttya/ttyb DCD and CTS
   inputs read with no cable (they decide whether a modem-controlled `getty`
   opens)? (ZS-2)
9. **Mask All after the real OBP**: does OBP 2.x clear ITMR.MA before booting
   the OS? If yes, INT-2 can also move the MA reset value to "set" for the
   real-OBP configuration. (INT-2)
10. **The AFX slot-0 byte at pa `0x6e000000`** is read by the SS5 OBP to
    decide whether slot 0 is probed; it falls in the core's audio decode —
    see video-audio-glue.md.
11. **`SUNW,bpp` and `power-management` FCode**: do they touch the (absent)
    BPP at `0x7c800000` or the APC at `0x6a000000` at probe time (reads of
    `0xBADACCE5` there would then matter before DEC-1 is fixed)?
