# Implementation gaps

Phase 4 of [REWORK.md](REWORK.md) asks what the core implements
incompletely or incorrectly, register by register. (Which devices are
missing altogether was phase 2, [HARDWARE_GAPS.md](HARDWARE_GAPS.md).) The
audit is in four parts, each with its own evidence (file:line, manual
section, OS driver code, the Sun PROM disassembly) and severity:

| Part | Scope | Findings |
|---|---|---|
| [impl-gaps/cpu.md](impl-gaps/cpu.md) | IU, FPU, MMU, caches, SMP, reset/config | 32 rows |
| [impl-gaps/chipset.md](impl-gaps/chipset.md) | decode, interrupts, timers, IOMMU/MSI, DMA2, ESP, LANCE, ESCC, NVRAM/TOD, AUX; a reset-state audit | 62 rows |
| [impl-gaps/video-audio-glue.md](impl-gaps/video-audio-glue.md) | TCX/CG3, CS4231, the MiSTer top, loader, DDR map, the phase 3 changes | 25 rows |
| [impl-gaps/keyboard-mouse-serial.md](impl-gaps/keyboard-mouse-serial.md) | Sun keyboard translator, mouse, ESCC behaviour, debug port, ef5ef21 | A-G |

Severity:
- **S1**: breaks an OS or a feature, or stops the real Sun OBP.
- **S1-diag**: fails only the PROM's diagnostic-mode POST.
- **S2**: wrong but tolerated.
- **S3**: cosmetic or diagnostic.

Nothing was simulated (no VHDL simulator on the box); every finding is
marked verified or *inference*.

## 1. What stops the real Sun OBP

The user has made the real OBP the target firmware (REWORK Decisions). Its
blockers, merged across the four parts and ordered, are in
[design/sun-obp-boot.md](design/sun-obp-boot.md), which is the work plan for
REWORK phase 5.1. In short:

**SS5 (OBP 2.15)**, in the order the PROM hits them:
1. The PROM is not decoded at pa `0x7000_0000`, and boot-mode fetches go
   to `0xF_F000_0000` (glue §1; cpu MMU-9).
2. The system control register has no read side, so every soft reset
   looks like power-on and the PROM loops forever (chipset AUX-1; kms A.1).
3. `sta %g0,[0x1000] 4` in `tlb_init_clear` clears the PCR through the
   ASI 4 alias, so the PROM dies on every boot (cpu MMU-1).
4. The bitstream NVRAM is in OpenBIOS format: POST runs in diag mode and
   the IDPROM is invalid (chipset TOD-5).
5. No TCX/CG3 FCode, so no screen console (glue V4).
6. No bus errors: empty SBus slots read as present. This is noise on the
   normal path, but a real defect (cpu MMU-4, chipset DEC-1).
7. No LANCE loopback, so `boot net` fails (chipset LAN-1).
8. No Stop key or BREAK, so there is no way into `ok` from a running OS
   (kms A.8/A.9).

**SS20 (OBP 2.25)** adds:
- no per-CPU MID: ASI 0x38 storage and the MSI MID register are missing,
  so every CPU runs the master path (cpu SMP-1; chipset IOM-1);
- IOMMU IMPL 0 (chipset IOM-2);
- no arbiter enable (cpu SMP-2);
- the top-of-RAM memory probe overwrites the PROM image (glue G6);
- 8-bit contexts against `mmu-nctx` 0x10000 (cpu MMU-3).

## 2. Other S1 findings (OSes and features)

| ID | Finding | Who | Fix |
|---|---|---|---|
| kms D | ESCC: "Reset highest IUS" clears a pending TX interrupt and "Reset TX int pending" arms a mask, so NetBSD serial output deadlocks after 2 characters (Linux stalls) | NetBSD, Linux serial ttys | under 1 h |
| V1 | "Scaler framebuffer" OSD mode: wrong `FB_BASE` (`0x3E40_0000` → VRAM is DDR `0x22B0_0000`) and no palette | anyone using the mode | S |
| V2 | CG3 DAC address register takes the index from D[31:24]; Linux/NetBSD write D[7:0] | Linux console colours on CG3 | XS |
| A1, A2 | CS4231: I12 ID nibble missing (Linux probe fails); STATUS.INT / I24 never set (IRQ handler returns `IRQ_NONE`) | Linux audio | XS, M |
| LAN-2 | LANCE: no receive-buffer size check; 1792-byte frames overrun 1536-byte buffers | becomes S1 with HPS Ethernet | M |
| MMU-3 | see §1: also affects Linux/NetBSD/Solaris on the SS20 under the real OBP | SS20 | M |

## 3. Likely causes of "reboot MiSTer between OSes"

The README's advice, explained. None of these state holders is reset by a
core reset:

- **L2TLB RAM** keeps stale translations (only its generation counter
  resets) (cpu CFG-1).
- **Interrupt Target Register** (chipset INT-1).
- **ESP**: the state machine, the interrupt flags and D_CSR, so a stale
  level-4 interrupt can be live (chipset ESP-1 + DMA-1).
- **Ethernet E_BASE_ADDR** keeps the previous OS's value (chipset DMA-2).
- **LANCE**: E_CSR RESET is only a partial reset (chipset LAN-4).
- **CG3 interrupt enable and TCX THC_MISC**, so the next OS gets stray
  level-9 interrupts (glue V3).
- **Cache tag RAMs**: flash clear is a no-op (cpu C-2).

## 4. Quick wins (XS/S effort, S1/S2 impact)

| ID | Fix | Effort |
|---|---|---|
| kms D | ESCC 0x38 → no-op; 0x28 clears `tx_ip` without arming `tx_mip` | < 1 h |
| MMU-1 | decode ASI 4 VA[12:8]; implement 0x1000/0x1300/0x1400/0x500/0x600 | S |
| AUX-1 | a system control read side; RS bit survives SW_RST; SW_RST without the DRAM wipe | S-M |
| TMR-1 | SS5 prescaler: 65 MHz / 32 is 1.5625 % fast | S |
| TMR-2 | user-timer RUN bit from D<0> (CPU1-3 user timers never start) | S |
| TOD-1 | TOD write with W=1, R=0 swaps the user registers and the counters | S |
| V2, A1, V3 | CG3 index byte; CS4231 ID nibble; reset CG3/TCX control registers | XS each |
| C (mouse) | signed 9-bit deltas, saturated, split over the two halves | S |
| kms A.6 | stop sending ED to the PS/2 port (lost bytes and stuck keys); drive `ps2_kbd_led_*` | S |
| DMA-2 | E_BASE_ADDR resets to `0xff` | XS |
| INT-1, ESP-1, DMA-1, CFG-1 | reset what §3 lists | S each |
| T2, T3 | CONF_STR: 2-bit aspect ratio field; `UART` declaration (PPP / console modes) | XS |

## 5. Corrections to earlier documents

- [HARDWARE_GAPS.md](HARDWARE_GAPS.md) called the mouse fine; it is not
  (kms C).
- HARDWARE_GAPS said Pause is ignored; it sends Ctrl + Num Lock (kms B).
- HARDWARE_GAPS §6 said READ TOC is implemented; it is not (already
  corrected there).
- `ss20-obp-2.25/post-tests.md` said the LANCE has LOOP; it is declared
  and never used (corrected there).
- Why `debugarm` is "needed for SMP" is not explained by the RTL. The best
  lead is OpenBIOS starting the secondaries with MCNTL.SE = 0, so they don't
  snoop (cpu SMP-3, *inference*).
