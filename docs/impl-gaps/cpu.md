# Implementation gaps: the CPU complex

Phase 4 of [REWORK.md](../REWORK.md), CPU part. The question is not which
devices are missing (that was phase 2, [HARDWARE_GAPS.md](../HARDWARE_GAPS.md))
but what `rtl/cpu/` implements incompletely or incorrectly: the IU
(`iu_pipe5.vhd`, `iu_pack.vhd`), the FPU (`fpu_simple.vhd`), the MMU and caches
(`mcu_simple.vhd` for the SS5, `mcu_multi.vhd` + `mcu_multi_ext.vhd` +
`mcu_tw.vhd` for the SS20, `mcu_pack.vhd`), the SMP glue (`smpmux.vhd`,
`iu_debug_mp.vhd`) and the build options (`cpu_conf_pack.vhd`).

**Method.** Everything was read from source; no VHDL simulator is installed, so
nothing here was simulated. Statements marked *inference* are reasoned from the
code and need a simulation or a hardware check. Evidence: the PROM analyses in
[`../rom-disassembly/`](../rom-disassembly/), the manuals in
`scratch/SparcStation/text/`, Linux (`arch/sparc/mm/srmmu.c`, `viking.S`,
`swift.S`, `kernel/sun4m_smp.c`, master), NetBSD (`sys/arch/sparc/sparc/cpu.c`,
`cache.c`, `pmap.c`, `locore.s`, `include/ctlreg.h`, trunk), QEMU 8.2.2
`target/sparc/cpu.c`, and Grabulosaure's `ss_openbios` (`arch/sparc32/entry.S`,
`openbios.c`, `boot.c`, `drivers/obio.c`), the BIOS the core ships today.

**Severity.** Firmware target: the user decided (REWORK Decisions, phase 5.1)
that the core must boot the **real Sun OBP** (SS5 OBP 2.15, SS20 OBP 2.25).
- **S1**: stops the real PROM from reaching `ok` and booting an OS, or breaks
  an OS or a feature. **S1-diag**: breaks only the POST, which runs only in
  diagnostic mode (`diag-switch?` true, Stop-D held, or no keyboard attached;
  [ss5-obp/README.md](../rom-disassembly/ss5-obp/README.md) §3.2). It is lower
  priority than a normal-path S1.
- **S2**: wrong, but tolerated or worked around (or only on an error path, a
  warm reboot, or an opt-in OSD option).
- **S3**: cosmetic, diagnostic-only or performance.

Effort: **S** up to a day, **M** a few days, **L** a redesign.

## Summary

| ID | Block | Finding | Sev | Effort |
|---|---|---|---|---|
| MMU-1 | MMU | ASI 4 decoded on VA[11:8] only: `0x1000` (TLB replacement control) aliases the PCR, `0x1300`/`0x1400` alias SFSR/SFAR, `0x500`/`0x600` (AFSR/AFAR) read as the PCR. The SS5 OBP writes 0 to `[0x1000]` on every boot and so clears the PCR, boot mode included | **S1** | S |
| MMU-9 | MMU | SS5 MMU has the SS20's 36-bit physical address model: boot-mode fetches go to pa `0xF_F000_0000`+VA[27:0], not `0x7000_0000`+VA[27:0]; pass-through and bypass keep VA[31]; PTE[31:27] not ignored | **S1** | S (+chipset) |
| MMU-4 | MMU | Bus errors never become traps: the MCUs force `PB_OK` on external reads, SFSR EBE/BE/TO are constant 0. The OBP's SBus/EBus probing cannot see an empty slot | **S1** | M (+chipset) |
| SMP-1 | SMP/MMU | No per-CPU MID: ASI 0x38 (SuperSPARC MMU breakpoint registers, where OBP 2.25 keeps the MID) is not stored, the MSI MID register reads 0; every CPU runs the OBP master path | **S1** | S (+chipset) |
| MMU-3 | MMU | SS20 context register has 8 bits; SuperSPARC has 16, OBP 2.25 publishes `mmu-nctx` 0x10000, so OSes will use contexts ≥ 256 and alias; POST wants ≥ 12 | **S1** | M |
| SMP-2 | SMP | No way to park or release a CPU (MSI arbiter enable); all CPUs leave reset together | **S1** | M (+chipset) |
| FPU-1 | IU/FPU | Trap priority inverted: a pending `fp_exception` (11) wins over `mem_address_not_aligned` (10) on an FP load/store (verified) | S1-diag | S |
| MMU-2 | MMU | TLB diagnostic ASIs 5/6/7 ignored; TLBs are 4 I + 4 D entries, not 64 | S1-diag | L |
| C-1 | Cache | Cache diagnostic ASIs: data 0x0d/0x0f ignored, tag 0x0c/0x0e read way 0 and write all ways, real tag formats and way selects not modelled | S1-diag | M |
| C-2 | Cache | Flash clear (ASI 0x36/0x37) not implemented; tag RAMs survive a reset while `ss_core` zeroes DRAM behind them: stale lines after a warm reboot under the SS20 OBP (*inference*) | S2 | S |
| CFG-1 | MMU | L2TLB RAM is not cleared by reset and not swept while the option is off: stale translations after a core reset or an OSD toggle (likely one cause of "reboot MiSTer between OSes") | S2 (S1 with L2TLB on) | S |
| IU-1 | IU | Error mode (trap with ET=0) halts the CPU forever instead of a watchdog reset | S2 | M (+chipset) |
| C-3 | Cache | SS20 line flushes (ASI 0x10-0x1d, the `FLUSH` instruction) take the PA from the TLB without a hit check; on a DTLB miss they flush PA = VA | S2 | S |
| C-4 | Cache | Snoop enable (MCNTL.SE) masks every tag hit, the CPU's own included: with SE=0, no invalidation on remote/DMA writes, and dirty victims are dropped in write-back mode | S2 | S |
| SMP-3 | SMP | OpenBIOS starts secondaries with MCNTL = 0x001 (SE=0); NetBSD never sets SE, so under OpenBIOS the secondaries do not snoop (*inference*) | S2 (OpenBIOS only) | S (BIOS) |
| C-5 | SMP | `smpmux` forces its arbiter idle after 128 busy cycles, whatever the transaction is doing (*inference*: a hang breaker that can break a slow transaction) | S2 | S (instrument) |
| IU-3 | IU | op3 0x30-0x37 (V8 LDC/STC family) executed as V9-style FP alternate-space loads/stores (`FPU_LDASTA`), and not privileged: user code can use any ASI, 0x20 bypass included | S2 | S |
| MMU-12 | MMU | ASIs truncated to 6 bits: 0x40-0xff alias 0x00-0x3f (0x4c ACTION writes the I-cache tag at index 0) | S3 | S |
| MMU-5 | MMU | Probe returns the raw table word on an invalid entry or error, instead of 0 | S3 | S |
| MMU-6 | MMU | `BSD_MODE`: every probe also flushes the TLB entries it names, plus the whole L2TLB and PTD caches | S3 | S |
| MMU-7 | MMU | Context flush keeps supervisor (ACC 6/7) entries; microSPARC-II removes them | S3 | S |
| MMU-8 | MMU | SFSR.L = 0 for faults found on a TLB hit | S3 | S |
| MMU-10 | MMU | SS5 PCR: AC, RC, PE, PC, PMC, AP, BF, WP, ST not stored; bit 6 is a private L2TLB enable | S3 | S |
| MMU-11 | MMU | SS20 MCNTL: SB, PE, TC, PSO, AC not stored, bit 15 returns a debug flag, bits 3:2 return a private CPU number | S3 | S |
| FPU-2 | FPU | No FPU exception mode / `sequence_error`; `STDFQ` not privileged | S3 | S |
| IU-2 | IU | An interrupt overrides a synchronous trap of the same instruction | S3 | S |
| IU-5 | IU | `WRPSR` with CWP ≥ NWINDOWS wraps instead of `illegal_instruction` | S3 | S |
| IU-6 | IU | `CASA` (op3 0x3c) executes instead of trapping; `WRASR` with rd != 0 writes Y (a NOP on the microSPARC) | S3 | S |
| C-6 | Cache | Cache geometry differs from both modules (VIVT 4-way on the SS5) | S3 | – |
| CFG-2 | Config | Reset: only `reset_n` exists (processor reset = delayed global reset); a software reset also clears DRAM | S2 | M (glue) |
| CFG-3 | Config | "IOMMU rev" (mask rev) never reaches the CPU; only the IOMMU's `0x3018` and a private copy | S3 | – |
| CFG-6 | Config | AOW OSD option is dead; WB overrides MCNTL bit 4 | S3 | S |

## Blocks the real OBP

In the order the PROM hits them. CPU items only; each line says which chipset
work belongs with it (the other phase 4 reports cover those registers).

### SS5, OBP 2.15 ([ss5-obp/README.md](../rom-disassembly/ss5-obp/README.md) §2-3)

Normal boot path (runs on every boot):

1. **Reset, first fetch** (MMU-9). The PROM's reset vector is fetched in boot
   mode. microSPARC-II sends boot fetches to PA[30:28]=7, PA[27:0]=VA[27:0]
   (User's Manual Table 40); the core sends them to pa `0xF_F000_0000` |
   VA[27:0] (`mcu_simple.vhd:1390-1395`). Needs the chipset to decode the PROM
   at `0x7000_0000` as well (REWORK 5.1).
2. **`obp_start_after_sw_reset` → `tlb_init_clear`** (MMU-1). After the POST
   decision (POST skipped or finished) the PROM software-resets and then runs
   `tlb_init_clear` (`0x7000be70`), which zeroes the TLB through ASI 6 and the
   TLB replacement control register with `sta %g0,[0x1000] 4`. On the core
   that store writes the PCR: EN, IE, DE and **BM** go to 0, and the next
   fetch (PC alias `0x0000xxxx`) goes to RAM. The PROM dies here on every
   boot.
3. **Forth: SBus/EBus probing** (MMU-4). The Forth side probes SBus slots and
   decodes the SFSR fields `BE` (bit 10), `TO` (bit 11), `PERR`, `CS`
   (`.sfsr` in [forth-dictionary.txt](../rom-disassembly/ss5-obp/forth-dictionary.txt));
   the POST's time-out tests expect SFSR `0x816` (SBus) / `0x416` (EBus). The
   MCU never reports a bus error, and the chipset acknowledges unmapped
   addresses with `0xBADACCE5`, so empty slots read as present.
4. **Forth: CPU probe** (MMU-1, harmless). `(ffd30320)` does `trcr@ 0x100000
   or trcr!` (ASI 4 `0x1000`): on the core it reads the PCR and writes it back
   unchanged. `(ffd3b8cc)` prints "DRAM Speed Setting" from `trcr@`: wrong
   digits only. Fixed by MMU-1.

Diagnostic POST only ([post-tests.md](../rom-disassembly/ss5-obp/post-tests.md) §2):

5. Test 3 "MMU TLB Replace Ctrl Reg" writes walking patterns into the PCR
   through the alias: the second pattern (`0xa5a5a5e5`) sets EN and clears BM,
   so the POST crashes instead of reporting (MMU-1). Tests 4-5 fail (MMU-1).
6. Tests 6-8 (TLB RAM/CAM/LCAM, ASI 6) fail (MMU-2); tests 12-13 (IOMMU flush,
   the IOPTEs live in the CPU TLB) fail (MMU-2).
7. Tests 16-19 (cache RAM/tag, ASIs 0x0c-0x0f) fail (C-1).
8. Tests 30 and 36 (FPU trap priority "<") fail (FPU-1).
9. Watchdog path (`reset_watchdog`, error path only): loads TLB entries with
   ASI 6 (MMU-2) and needs a watchdog reset to exist at all (IU-1).

### SS20, OBP 2.25 ([ss20-obp-2.25/README.md](../rom-disassembly/ss20-obp-2.25/README.md) §2-5)

Boot-mode fetch (`0xF_F000_0000`+VA[27:0], `mcu_multi.vhd:1492`) and the module
identification (PSR 0x40, MCNTL 0x01000800: "TMS390Z50(3.x) 0Mb External
cache", README §4) are right. Normal boot path:

1. **`reset_entry` / `reset_find_mid`** (SMP-1). Every CPU copies the MSI MID
   register (pa `0xF_E000_2000`, reads 0 on the core) into ASI 0x38 va 0; with
   IOMMU IMPL = 0 it then reads its MID back from ASI 0x38 va 0 (the core drops
   the store and returns cache data) and ORs in 8. **Every CPU becomes MID 8**,
   so all three CPUs run the master path (serial init, NVRAM release flags,
   memory sizing, page tables) at the same time. With `NCPUS=3` this breaks
   the uniprocessor boot too. Needs ASI 0x38 storage (CPU) and a per-requester
   MSI MID register (chipset, or answered inside the MCU).
2. **Arbiter enable** (SMP-2). The master parks the slaves by clearing their
   bits in pa `0xF_E000_1008`; not decoded, so they keep running. Once MIDs are
   right the PROM tolerates free-running slaves (README §5.1), so this is S1
   for MP start-up and for POST, not for the first `ok`.
3. **`obp_start` → `obp_cache_init`** (C-2, warm reboot only). The only
   whole-cache invalidate is flash clear (ASI 0x36/0x37), a no-op on the core;
   the tag loops (ASI 0x0c at `0x40000000 + 64n`) clear only the even sets of
   the core's 32-byte-line I-cache. Harmless on a cold boot (the tag RAMs power
   up as 0); after a warm reset stale lines can survive (*inference*). Store
   buffer ASIs 0x30/0x32 and ACTION 0x4c are ignored or aliased, harmlessly.
4. **`rom-cold-code`** (SMP-1 again: the same four-way MID lookup).
5. **Forth: SBus probing** (MMU-4), as on the SS5.
6. **OS start** (MMU-3). The CPU node carries `mmu-nctx` = 0x10000
   (`forth-dictionary.txt:9036`), and the context table is sized for it. Linux
   (`num_contexts` from `mmu-nctx`), NetBSD and Solaris will hand out contexts
   above 255; the core keeps 8 bits, so contexts alias, the table walk indexes
   the wrong context-table entry (`mcu_tw.vhd:359-360`) and processes see each
   other's memory. Linux takes `num_contexts` from `mmu-nctx` (`srmmu.c:889`),
   NetBSD `mmu_ncontext` likewise (`cpu.c:1297`). OpenBIOS avoids this today
   by publishing 0x100.
7. **MP start** (SMP-1, SMP-2). `romvec_cpustart` → the slave's idle loop →
   `cpu_enter_client` is pure software once every CPU knows its MID.

Diagnostic POST only ([post-tests.md](../rom-disassembly/ss20-obp-2.25/post-tests.md)):

8. `post_main` #5 "MMU Context Register" (walking one over 12 bits) is the
   first failure (MMU-3).
9. TLB diagnostics (ASI 5/6), cache diagnostics and flash-clear tests (MMU-2,
   C-1, C-2), the store buffer ASIs, and the SP/DP "Trap Priority <" tests
   (FPU-1).
10. Watchdog path: SFSR bit 17 (EM) as the error-mode reset flag, D-TLB dump
    through ASI 6 into NVRAM (IU-1, MMU-2).

---

## 1. Integer unit

### IU-1 Error mode halts instead of a watchdog reset (S2, M + chipset)

- **Real:** V8 error mode; microSPARC-II §3.11.4 ("The IU will remain in
  error mode until it is reset"). On sun4m the module turns error mode into a
  **watchdog reset** of that processor plus a level-15 broadcast (Sun-4M §12
  "Resets"; state table: boot mode 1, caches/MMU unchanged, watchdog bit 1).
  The SS5 PROM checks system status bit 4, the SS20 PROM checks SFSR bit 17
  (EM), and both have a `reset_watchdog` path that re-enters OBP and prints
  "Watchdog Reset".
- **Core:** `iu_pipe5.vhd:1286-1290` sets `halterror` and `dstop`; only the
  debugger's `run` clears them (`:1343`). No reset, no status bit (SFSR EBE is
  a constant 0, `mcu_multi.vhd` `MMU_FSR_EBE`), no level-15.
- **Who:** every OS crash that double-faults in a trap handler (the classic
  Solaris "Watchdog Reset"): the core hangs silently. Also a candidate for why
  SMP "needs" the debug monitor (SMP-4).
- **Fix:** route `halterror` out of the IU to a per-CPU reset request; set
  SFSR bit 17 (SS20) and the SS5 status bit; send HARDINT 15. Keep the
  debugger stop as an option.
- **Test:** not in the in-PROM suite (it halts the suite); a GHDL test that
  traps with ET=0 and checks re-entry at 0 with the status bits.

### IU-2 Interrupt overrides a synchronous trap (S3, S)

`iu_pipe5.vhd:907-916`: when an interrupt is pending, `trap_exe_v` is replaced
by `interrupt_level_n` even if the instruction already carries an ALU or LSU
trap (division by zero, tag overflow, `ta`, misaligned). V8 Table 7-1 gives
interrupts the lowest priority (17-31). The instruction is re-executed after
the handler, so no OS notices; only the order of two handlers differs.
Test: `t_irq_prio` (needs the timer).

### IU-3 LDC/STC family executed as FP alternate-space accesses, unprivileged (S2, S)

- **Real:** V8 op3 0x30-0x37 are the coprocessor loads/stores (LDC, LDCSR,
  LDDC, STC, STCSR, STDCQ, STDC); with no coprocessor they trap
  `cp_disabled` (tt 0x24). The alternate-space forms that exist are all
  privileged.
- **Core:** `FPU_LDASTA = true` (`cpu_conf_pack.vhd:172`) turns them into
  V9-style LDFA/STFA/LDDFA/STDFA/STDFQA (`iu_pack.vhd:1403-1446` decode,
  `:2232-2275` execute), and the decode never sets `cat_o.priv`, so a user
  program can `stfa %f0,[x] 0x20` and write any physical address.
- **Who:** security (any user process can corrupt memory); V8 conformance.
  `tools/debugarm` uses STFA/LDFA to read FPU state (its `lib.c`), so keep the
  instructions but mark them privileged (or add a debug-only enable).
- **Test:** `t_cp_ldst` (below).

### IU-5, IU-6 Small V8 deviations (S3, S)

- `WRPSR` with CWP ≥ NWINDOWS: V8 requires `illegal_instruction`; the core
  wraps with `cwpfix` (`iu_pack.vhd:502`, `:1464-1479`).
- `RDASR`/`WRASR` ignore rs1/rd and access Y (`iu_pack.vhd:1770-1772`,
  `:1793-1796`). V8 B.28/B.29 leave reserved ASRs to the implementation,
  and the microSPARC-I/II manuals say every ASR read acts as RDY and every
  ASR write as a NOP. **Reads must not trap**: OpenSSL's libcrypto tells
  V8 from V9 with `wr %g0, %y; rd %asr2` (2026-10-01: a core that trapped
  it killed NetBSD's `syslogd` and `login` with SIGILL). So reads stay RDY;
  the only gap is that a write to ASR 1-31 changes Y instead of nothing.
  (This entry first said reserved ASRs were illegal_instruction: wrong.)
- `CASA` (op3 0x3c, V9/LEON) is enabled in every configuration
  (`cpu_conf_pack.vhd:71,99,127`; `iu_pack.vhd:1327-1333`, `:2291-2305`), so an
  op3 that is `illegal_instruction` on both modules executes.
- `intack` is never driven (`iu_pipe5.vhd:1412`, "<AFAIRE>"); nothing uses it.

Checked and right: trap entry/return, PSR.impl/ver 0x04 (SS5) and 0x40 (SS20),
NWINDOWS 8 (both modules), FSR.ver 4 and 0, `privileged_instruction` over
`illegal_instruction` and `fp_disabled` over `mem_address_not_aligned`
(`iu_pipe5.vhd:892-905`). The generic ISA is covered by `tests/cpu` (not yet
run on the core).

## 2. Floating-point unit

### FPU-1 Trap priority inverted (S1-diag, S) — verified

- **Real:** V8 Table 7-1: `mem_address_not_aligned` priority 10,
  `fp_exception` 11 (the LEON2 manual's copy of the table in `scratch`;
  microSPARC-II §3.11.1 "Trap priorities are as defined in SPARC Rev 8"). A
  misaligned FP store with a deferred exception pending must take tt 7, and the
  exception stays pending until the next FP instruction.
- **Core:** `iu_pipe5.vhd:880-901`. `trap_exe_v` is first set to the LSU trap
  (misaligned), then the FPU block overwrites it with `TT_FP_EXCEPTION`
  whenever `fpu_fexc='1'`. The fp_exception is taken, the FPU is acknowledged
  (`fxack`, `:1282-1284`), and the misaligned trap never happens.
- **Who:** SS5 POST tests 30/36 ("FPU SP/DP Trap Priority <"), SS20 POST SP/DP
  Trap Priority < (`0xaf24`, `0xba44`): diagnostic mode only. OSes: the store
  is retried after the FP handler and then traps misaligned, so they cope.
- **Fix:** apply `fp_exception` only when no higher-priority trap is set:
  `ELSIF fpu_fexc='1' AND trap_exe_v.t='0'` (the LSU trap only ever carries
  priority ≤ 10 there).
- **Test:** `t_fpu_trap_prio`.

### FPU-2 FPU exception mode, FQ semantics (S3, S)

- After the trap is acknowledged the FPU returns to normal mode at once
  (`fpu_simple.vhd:470-472`). V8: the FPU is in *exception mode* until the FQ
  is empty; an FPop or FP load/store there, or `STDFQ` with an empty queue,
  is `fp_exception` with `ftt = sequence_error` (4). None of that exists
  (header "<AFAIRE>", `fpu_simple.vhd:15-29`).
- `STDFQ` is privileged in V8; the decode does not set `priv`
  (`iu_pack.vhd:1389-1393`, `:2213-2219` "<AFAIRE>").
- FSR.NS is stored but ignored (`DENORM_FTZ` is a constant).
- The FQ itself (8 entries of PC and instruction, FSR.qne) is implemented,
  which is what the POST's `trap_fp_exception` and OS handlers need.
- Unverified: LDDF/STDF with an odd rd (SS5 POST test 22 expects rd[0]
  ignored). Test it.

## 3. MMU

### MMU-1 ASI 4 decoded on VA[11:8] only (S1, S)

- **Real:** microSPARC-II decodes VA[12:8] (User's Manual Table 19: "the use
  of a second access mode for the Synchronous Fault registers is provided as a
  diagnostic function (VA[12:08] = 0x13, 0x14)"): `0x000` PCR, `0x100` CTPR,
  `0x200` CTX, `0x300` SFSR, `0x400` SFAR, `0x500`/`0x600` AFSR/AFAR (the
  OBP's `afsr@`/`afar@` words), `0x1000` TLB replacement control (TRCR: VP,
  TC, TRC, WP, IL, PL, MEMSP, SBSP; §5.6), `0x1300`/`0x1400` writable
  SFSR/SFAR. QEMU models TRCR (`mmu_trcr_mask 0x00ffffff`).
- **Core:** `mcu_simple.vhd:970-985` (write select) and `:1242-1284` (read
  mux) compare `a(11 DOWNTO 8)` only; unknown indices fall to the `ELSE` arm,
  which returns the PCR (`:1279-1283`). Same code in `mcu_multi.vhd:1045-1060`,
  `:1323-1383`. So `0x1000` is the PCR (read and write), `0x1300` is the
  clear-on-read SFSR, `0x1400` the read-only SFAR, `0x500`/`0x600` read as the
  PCR. The private registers `0xB00` (SFSR, no clear), `0xC00` (scratch),
  `0xD00` (SYSCONF: RAM size and CPU count, read by OpenBIOS) sit in
  microSPARC-II's reserved space.
- **Who:** SS5 OBP normal boot (step 2 above); SS5 POST tests 3-5 (the POST
  crashes at test 3); `tests/cpu` `t_mmu_swift_regs` detects the alias today.
- **Fix:** decode VA[12:8]; add TRCR as a plain register (mask `0x0011ffff`
  plus bit 6; the POST sets TC so the counter need not run), writable
  `0x1300`/`0x1400` aliases, AFSR/AFAR (0 unless MMU-4 is done). Move the
  private `0xB00-0xD00` registers out of the architectural space (or keep
  them; nothing real uses VA[12:8] = 0x0b-0x0d).

### MMU-2 TLB diagnostics, TLB size (S1-diag, L)

- ASIs 5, 6, 7 are acknowledged and ignored ("Diagnostic, on s'en fout",
  `mcu_simple.vhd:678-684`, `mcu_multi.vhd:692-698`).
- The TLBs are 4 instruction + 4 data entries, LRU (`mcu_pack.vhd:24-28`);
  microSPARC-II has 64 entries shared with the IOMMU (IOPTE lock at 48-63,
  §5.6), SuperSPARC 64. The optional L2TLB (256 entries, CFG-1) and the PTD
  caches in `mcu_tw.vhd` hide the cost.
- **Who:** SS5 POST 6-8 and 12-13, SS20 TLB tests, both PROMs' watchdog paths
  (they load or dump TLB entries through ASI 6). No OS uses ASI 6 in the normal
  path (checked: Linux, NetBSD).
- **Fix:** passing the RAM/CAM march tests needs 64 addressable entries with
  the PROM's layout (PTE `0x000+4n`, lower tag `0x100+4n`, upper tag
  `0x300+4n` on the SS5; `entry<<12 | SEL<<8` on the SS20). That is a TLB
  redesign; a diagnostic-only shadow array would pass the marches but not the
  flush tests. Decide after the normal-path items.

### MMU-3 SS20 context register: 8 bits (S1, M)

- **Real:** SuperSPARC context register is 16 bits (QEMU
  `mmu_cxr_mask 0x0000ffff`); OBP 2.25 publishes `mmu-nctx` 0x10000 and sizes
  the context table (256 KB) for it; POST checks 12 bits.
- **Core:** `NB_CONTEXT => 8` in `CONF_SuperSparc` (`cpu_conf_pack.vhd:132`);
  `mcu_multi.vhd:2163` keeps `d(7:0)`; the table walk indexes the context
  table with those 8 bits (`mcu_tw.vhd:359-360`); CTPR alignment masks PA 9:6
  (`mcu_multi.vhd:2158`).
- **Who:** every OS under the real OBP (see "Blocks the real OBP" 6); the
  POST (diag). OpenBIOS publishes 0x100, so today's OSes are safe.
- **Fix:** `NB_CONTEXT => 16` for the SS20. Watch the tag layouts that embed
  the context: `vtag_encode` puts it in bits `NB_CONTEXT+3..4`, which then
  overlaps the VA field of the L2TLB tag (`mcu_tw.vhd:266-273`; constraint noted
  at `cpu_conf_pack.vhd:57-58`). The L2TLB tag needs its own format (or a
  wider word). TLB entries grow by 8 bits × 8.
- **Test:** `t_mmu_ctx_bits` (walking one over 16 bits, CTPR mask
  `0xffffffc0`).

### MMU-4 Bus errors never become traps (S1, M + chipset)

- **Real:** a load that the bus answers with an error or a time-out traps
  `data_access_error` (tt 0x29) with SFSR FT = 5 and the EBE bits (SS5: BE
  bit 10, TO bit 11, as the OBP's `.sfsr` decodes them); stores posted in a
  write buffer are reported asynchronously (AFSR/AFAR, level 15).
- **Core:** the external read state forces `PB_OK`
  (`mcu_simple.vhd:1038-1045`, `mcu_multi.vhd:1114-1119`); `MMU_FSR_EBE` is a
  constant `x"00"` (`mcu_simple.vhd:112`); `plomb_trap_data` maps `PB_ERROR`
  to `TT_DATA_ACCESS_ERROR` (`iu_pack.vhd:750-760`), but nothing in the CPU or
  chipset ever produces `PB_ERROR`. The chipset acknowledges unmapped
  addresses with `0xBADACCE5` (HARDWARE_GAPS §2.1).
- **Who:** both OBPs' SBus probe (normal boot), the SS5 POST time-out tests
  (14-15), OS probing of empty SBus slots and `peek`-style drivers.
- **Fix:** chipset returns `PB_ERROR` on time-out/unmapped; the MCUs pass the
  code through for single reads, set SFSR FT=5, EBE/BE/TO and SFAR, and put
  write errors into AFSR/AFAR plus an interrupt.
- **Test:** `t_bus_error` (bypass load from an unmapped PA → tt 0x29,
  SFSR/SFAR checked).

### MMU-5 Probe returns the raw word on error (S3, S)

microSPARC-II §5.5.2: a probe "returns a zero if there is an invalid address
or translation error". `mcu_tw.vhd:422` latches the table word before the
check, and the error branch (`:435-446`) returns it, so an invalid entry
(often non-zero: swap entries) comes back as data. NetBSD's `VA2PA`
(`pmap.c:785-803`) and Linux check the entry type, so nothing breaks today.

### MMU-6 `BSD_MODE` probes flush (S3, S)

With `BSD_MODE = true` (`cpu_conf_pack.vhd:181`), an ASI 3 load also
invalidates the matching D- and I-TLB entries (`mcu_simple.vhd:650-652`,
`:1516-1530`; `mcu_multi.vhd:662-664`, `:1610-1625`), and every TLB flush
bumps the L2TLB generation and clears the PTD caches (`mcu_tw.vhd:590-614`).
The probe then walks the tables, so it never returns a stale TLB entry (the
reason given for NetBSD). Functionally safe; costs performance on every
`VA2PA`. The option's second effect, a stall after every `WRPSR`
(`iu_pipe5.vhd:685`), is also safe. Its comment says Linux wants it off; no
Linux dependency was found. Suggest dropping the option and keeping the safe
behaviour.

### MMU-7, MMU-8 Flush and SFSR details (S3, S)

- Context flush: microSPARC-II §5.5.1 also removes "all PTEs that have the S
  (Supervisor) bit set"; `tlb_test` (`mcu_pack.vhd`, `PT_CONTEXT`) flushes
  only ACC ≤ 5. Linux flushes the whole TLB on Swift anyway.
- Faults detected on a TLB hit report SFSR.L = 0 ("Level ???",
  `mcu_simple.vhd:2118,2131`, `mcu_multi.vhd:2209,2222`); SRMMU wants the
  level of the PTE (the TLB entry's `st`).
- **OW must stay clear for one instruction fault** (2026-10-01, on the
  board). The fetch unit runs ahead: after a jump into an unmapped page
  the next fetch, on the same page, faults as well. Upstream recorded an
  instruction-side invalid walk fault only while FAV was clear and always
  cleared OW on walk faults; `5568d30` (MMU-8, table 28) records the second
  one and sets OW. Solaris 8's sun4m `get_fault_type` tests OW
  (`andcc %l1, 1` at `unix` `0xf005bef8`), takes the status as overwritten,
  re-probes, never calls `pagefault` and the process loops on the fault
  (SFSR `0x347`: user instruction, invalid, level 3, FAV, OW). Patching that
  test out in memory let Solaris reach its rc scripts. OW is for a second
  fault the software never saw, not for the fetch unit's speculation.
  `t_mmu_ifault`.

### MMU-9 SS5 physical address model (S1, S + chipset)

microSPARC-II has a 31-bit physical address (Table 40): boot fetch
PA[30:28]=7; pass-through and bypass PA[30:0] = VA[30:0]; translation
PA[30:12] = PTE[26:8]. The SS5 MCU uses the SS20 model: boot fetch
`x"FF" & VA(27:0)` (`mcu_simple.vhd:1393`), pass-through `x"0" & VA`
(`:532`), bypass `asi(3:0) & VA` (`:520`), PPN = PTE[31:8]. The first item
blocks the SS5 OBP's first instruction; the others matter only to software
that sets VA[31] in bypass accesses or PTE[31:27]. Fix: make the three
translations CPU-type dependent (`CPUTYPE_MS2`).

### MMU-10, MMU-11 Control register fields (S3, S)

- **SS5 PCR** (`mcu_simple.vhd:1244-1247`, write `:2055-2061`): IMPL/VER
  0x04 (right; QEMU and NetBSD's "MB86904"), EN, NF, DE, IE, BM. Not stored:
  AC (bit 15; the PROM's `trap_data_access_error` clears it), RC, PE, PC,
  PMC, AP, BF, WP, ST (read 0; the OBP's `.mcr` shows zeros, and it sets BF
  and PMC through read-modify-write). Bit 6 is a private L2TLB enable (the
  real bit is read-only 0: OBP `mcr-ro-bits` = `0xff00007c`).
- **SS20 MCNTL** (`mcu_multi.vhd:1323-1338`, write `:2138-2153`): IMPL/VER
  0x01 and MB=1 give `0x01000800`, exactly QEMU's "TI SuperSparc 60"
  (no MXCC), NetBSD's "SuperSPARC v3" and OBP type 0x40: right. SB reads 0,
  PE/TC/PSO/AC are not stored (Linux sets SB, clears TC and AC; harmless).
  Bit 15 returns `xxx_dexmax`, a debug flag that a data access waited 250
  cycles in `sWAIT_SHARE` (`:1205-1210`); it should read AC. Bits 3:2 return
  the CPU number (`CPUID` generic), which only OpenBIOS uses (`entry.S`
  "MMU Register 0xx : Control Register [3:2]"); Viking has them reserved.

### MMU-12 ASI truncated to 6 bits (S3, S)

`data2_w.asi(7 DOWNTO 6)<="00"` (`mcu_simple.vhd:1216`, `mcu_multi.vhd:1291`):
ASI 0x44 reaches the MMU registers, 0x48-0x4b normal memory, and 0x4c (Viking
ACTION register: OBP 2.25 `obp_cache_init` writes 0, Linux `poke_viking` does
read-modify-write on secondaries) writes the I-cache tag at index 0 of every
way. Today that happens while the tags are clear, so it is harmless
(*inference*). Fix: decode all 8 bits; ACTION becomes a register (not a
write-ignored ASI: Solaris 8's SuperSPARC setup writes 0x1000, MIX, and
loops until it reads it back; seen on the board 2026-10-01, the kernel
spinning at `sta %o0,[%g0] 0x4c; lda [%g0] 0x4c,%o3; cmp; bne`). QEMU keeps
13 bits (`val & 0x1fff`) at any address.

### MMU-13 ASI 0x38 (part of SMP-1)

ASI 0x38-0x3b are the core's table-walk ASIs, but only on the internal bus
(`asi_pack.vhd:73-76`, `mcu_tw.vhd:107-120`). A CPU access with ASI 0x38 never
reaches that bus: it falls into `WHEN OTHERS` (`mcu_multi.vhd:1029-1032`),
which drops stores and returns the D-cache data RAM output for loads. So
there is no conflict on the bus; the register simply does not exist.

## 4. Caches and coherency

### C-1 Cache diagnostic ASIs (S1-diag, M)

- Data ASIs 0x0d/0x0f: acknowledged, ignored (`mcu_simple.vhd:832-836`,
  `:863-867`; `mcu_multi.vhd:904-908`, `:937-941`).
- Tag ASIs 0x0c/0x0e: a read returns way 0 only ("<AFAIRE> Sélection voie",
  `mcu_simple.vhd:842`, `mcu_multi.vhd:914`); a write stores the same value
  into **every** way (`mcu_simple.vhd:1105-1111`, `mcu_multi.vhd:1182`). The
  VA bits that select way, physical/set tag (SS20: bits 31/30, way at 26+) are
  ignored and the tag format is the core's own.
- Clearing tags (`sta %g0`) works, which is all the SS5 OBP and OpenBIOS need.
  Linux `viking_flush_page` compares physical tags read through ASI 0x0e and
  so never matches; it does not need to, because the core's caches are
  physically tagged and snoop DMA.

### C-2 Flash clear missing, tags survive reset (S2, S)

- ASI 0x36/0x37 (SuperSPARC flash clear) fall into `WHEN OTHERS`. Users: OBP
  2.25 `obp_cache_init` (every boot), NetBSD `viking_cache_enable`
  (`cache.c:180-189`, before it turns the caches on).
- Tag RAMs are block RAMs without reset. `ss_core` implements a software
  reset as a full reset plus a DRAM clear (`ss_core.vhd:942-967`,
  `:1019-1023`), which bypasses the caches. After a warm reset, valid lines
  can name PAs whose memory changed. On a real sun4m a software reset keeps
  memory and caches (Sun-4M §12) and the PROM flash-clears.
- Also (*inference*): OBP 2.25 clears I-cache tags at a 64-byte stride
  (Viking lines), which reaches only the even sets of the core's 32-byte-line
  I-cache.
- **Fix:** implement 0x36/0x37 as a 128-cycle tag sweep per cache (SS20) and
  clear the tags on `reset_n` (both builds; costs 128 cycles).

### C-3 SS20 line flush without a TLB hit check (S2, S)

`mcu_multi.vhd:944-976` sends a `FLUSH` bus operation with `pa_v` from the TLB
OR-mux. On a DTLB miss that mux is `TLB_ZERO` (level 0), so
`pa = ppn(35:32) & va` = VA (`:518-557`): the flush hits the line at PA = VA,
not the intended one. With the 4-entry DTLB, misses are common. Affected: the
`FLUSH` instruction (`ASI_IFLUSH` = 0x15, `iu_pack.vhd:154`, `:2286`) in
write-back mode (dirty D line not written back, I line not invalidated);
OpenBIOS `cache_flush_all` (0x15 over VA 0-16 KB), which on the SS20 flushes
only PA 0-16 KB. In write-through mode own stores invalidate own I-lines
through the snoop, so the default configuration is mostly safe. Fix: walk the
tables on a miss as loads do, or flush by index.

### C-4 Snoop enable gates every hit (S2, S)

`mcu_multi_ext.vhd:385` (`dhit_v := ... AND mmu_cr_dsnoop`), `:409` (I),
`:572` (`cwb` write-back request). With MCNTL.SE = 0 the cache neither
invalidates on remote or DMA writes nor writes back its own dirty victims
(write-back mode). SE is not in the reset list (`mcu_multi.vhd:2233-2245`), so
it keeps its value across a core reset. Real hardware comes out of reset with
snooping off ("'Dual' bit off", Sun-4M §12) and the real OBP sets SE on every
CPU, so this is correct behaviour that the firmware must honour (SMP-3).

### C-5 `smpmux` 128-cycle watchdog (S2, S to instrument)

`smpmux.vhd:494-505`: when the arbiter has not been idle for 128 cycles,
`etat` is forced to `sIDLE`, whatever the transaction is doing (snoop,
write-back burst, a request not yet acknowledged). `mcu_multi` has a similar
250-cycle counter on `sWAIT_SHARE` (MMU-11). *Inference:* these are hang
breakers left from bring-up. Phase 3 merged the two DDR3 ports with video
first (`ddram_arb.sv`), which lengthens memory latency and makes the 128-cycle
limit easier to hit. Count the events on hardware before trusting SMP.

### C-6 Cache geometry (S3)

SS5: I and D are 4 KB/way × 4, 32-byte lines, VIVT with context tags
(`CONF_MicroSparcII_multi`, `cpu_conf_pack.vhd:67-93`); microSPARC-II has a
16 KB direct-mapped I-cache and an 8 KB direct-mapped D-cache with 16-byte
lines (User's Manual §6.1). SS20: 4 × 4 KB, 32-byte lines for both;
SuperSPARC's I-cache is 20 KB, 5-way, 64-byte lines. The PROMs publish the
real geometry. OS flush loops (Linux `swift_flush_cache_*`, NetBSD
`swift_cache_enable`, OBP tag clears) still reach every set, because a
tag-ASI write or line flush hits all ways at an index and the core's way size
(4 KB = page size) is not larger than the published cache. Keep it that way
if geometry changes.

## 5. SMP

### SMP-1 MID (S1, S + chipset)

- **Real:** each module has an MBus ID (8-11). The MSI MID register (pa
  `0xF_E000_2000`, Sun-4M §5.1) returns the requester's MID; a SuperSPARC
  without MXCC has no MID register, so OBP 2.25 copies it into ASI 0x38 va 0
  at reset and reads it from there; with an MXCC, the MXCC port register
  (`ldda [0x01c00f00] 2`, used by upstream OpenBIOS and NetBSD
  `viking_getmid`).
- **Core:** MSI MID reads 0 (`ts_iommu.vhd` decodes only control, base,
  flushes and `0x3018`); ASI 0x38 not stored (MMU-13); no MXCC (MB = 1). The
  only per-CPU identity is the private MCNTL[3:2] = `CPUID`
  (`mcu_multi.vhd:1330`, `ts_core.vhd:686-890`), used by OpenBIOS.
- **Who:** the SS20 OBP (normal path, step 1). Under OpenBIOS the OSes take
  MIDs from the `mid` property (Linux `sun4m_smp.c`, NetBSD
  `cpu_mainbus_attach`); Solaris is unknown.
- **Fix:** four 64-bit ASI 0x38 registers per CPU (va 0/0x100/0x200/0x300) in
  `mcu_multi`; answer the MSI MID register with `8 + CPUID`, either inside the
  MCU (it knows its `CPUID`) or with a requester-ID sideband from `smpmux`
  (`not_c`) to `ts_iommu`.

### SMP-2 Starting and stopping CPUs (S1, M + chipset)

All IUs and MCUs get the same `reset => preset` (`ts_core.vhd:663-890`); no CPU
can be held except by the debugger (`iu_debug_mp.vhd:221-225`). The real OBP
parks and dispatches CPUs through the MSI arbiter enable register (a module
whose bit is 0 stalls on its next MBus access; README §5.1). Fix: decode
`0xF_E000_1008` and mask `smpN_w.req` in `smpmux` for disabled masters (the
stall is then natural). The exact semantics for a stopped CPU are an open
PROM question (README §8).

### SMP-3 OpenBIOS start path and snooping (S2, BIOS fix)

The hardware path OpenBIOS uses is complete: secondaries spin in `entry.S`
(wait for `0xdadad0d0` at pa 0, then poll their soft-interrupt pending bits),
`obp_cpustart` → `start_cpu` (`obio.c:539-554`) posts ctx/ctxtbl/entry at
RAM top − 0x100 and sets soft interrupt 14 on the target. But the secondary
turns the MMU on with **MCNTL = 0x001** (`entry.S`, "configure mmu") and
jumps to the kernel, while CPU0 has run `srmmu_set_mmureg(... | 0x4140)`
(SE, DE, L2TLB; `openbios.c:1932-1937`) and keeps SE through `go`
(`boot.c:237` clears only IE/DE). Linux sets SE itself (`poke_viking`,
`srmmu.c:1411`); NetBSD never does (it only defines `VIKING_PCR_SE`,
`ctlreg.h:270`; `viking_cache_enable` sets IE/DE). Under OpenBIOS, NetBSD's
secondaries therefore run without snooping (C-4): stale data after other
CPUs' writes, and lost dirty lines with WB on (*inference*; the README says
NetBSD "seems to work" with 3 CPUs, so confirm by reading MCNTL on CPU1 with
the monitor). Fix in `ss_openbios`: enter the kernel with `0x4001`.

### SMP-4 Why the debug monitor is "needed" (open)

Nothing in the RTL gives `tools/debugarm` an SMP role. `iu_debug_mp` only
stops, runs and single-steps a selected CPU and injects opcodes; its
`debug_t.opt` bits are not used by the IU; every CPU runs from reset. The
monitor has no SMP command (`main.c:218-226` only reads the CPU count). The
README's recollection is therefore not explained by the hardware.
Candidates: the monitor can execute `sta` on a chosen CPU (so someone could
have set MCNTL.SE by hand: SMP-3), restart a CPU stuck in error mode (IU-1),
or unstick a bus hang (C-5). None is verified.

## 6. Reset and configuration

### CFG-1 L2TLB stale entries (S2; S1 with the option on; S)

`mcu_tw.vhd` caches level-3 PTEs in a 256-entry block RAM (`:229-235`, no
reset). Instead of clearing it on a TLB flush it bumps an 8-bit generation
that is part of the tag (`:266-273`, `:608-614`) and sweeps two entries per
flush in the background (`:331-339`, `:616-628`). On `reset_n` the generation
and sweep counters return to 0 (`:631-648`) but the RAM keeps the previous
session's entries: those of generation 0 match at once, and older ones match
when the new generation reaches theirs before the sweep reaches them. After
switching OS with the OSD reset (or an OS reboot, which is a full reset,
CFG-2) a kernel VA in context 0 can translate through the previous OS's PTE.
While the option is off the sweep stops (`l2tlb_idec <= mmu_cr_l2tlb`) but the
generation keeps counting, and `l2tlb_ipend/dpend` (range 0-15) can overflow,
so switching the option on at run time after 256 flushes can revive stale
entries. The OSD default is OFF (`SunSparcStation.sv` "OH,L2TLB,OFF,ON").
*Inference:* a likely part of the README's "reboot MiSTer when trying
different OSes". Fix: sweep all 256 entries after reset and whenever the
enable rises (256 cycles), and saturate the pending counters. The
NeXTSTEP incompatibility is not explained by this (open question 2).

### CFG-2 Reset values (S2, M in glue)

The IU and MCU see two resets, but `preset` is `reset_n` delayed 5 cycles
(`ss_core.vhd:1026-1036`), so every CPU reset is a full reset. The OS's
software reset (`sysreset`) restarts the loader state machine, which clears
DRAM (`ss_core.vhd:1019-1023`, `:942-967`); Sun-4M §12 says a reset leaves
registers, caches, TLBs and memory alone. (The PROMs' POST-to-OBP hand-off in
`%g1-%g7` survives, because the register file is an unreset RAM.) What
`reset_n` does to the CPU state:

| State | Reset | Real module | Note |
|---|---|---|---|
| PSR.ET/S, CWP 0, TBR 0, PC 0 | yes | ET=0, S=1, PC 0 | V8 |
| PCR/MCNTL EN, NF, DE, IE, BM | yes (`mcu_simple.vhd:2140-2150`, `mcu_multi.vhd:2233-2245`) | same | |
| MCNTL SE (dsnoop/isnoop) | **no** | off | C-4 |
| L2TLB enable bit | yes | – | private |
| CTPR, CTX, SFAR, SFSR.L/AT, scratch `0xC00` | no | undefined | fine |
| TLB valid bits, PTD caches | yes | unaffected on sun4m | fine |
| L2TLB RAM | **no** (counters yes) | – | CFG-1 |
| Cache tags | **no** | unaffected | relies on firmware (C-2) |
| FPU exception, queue pointers | yes | – | FSR not reset (V8: undefined) |
| `smpmux`, `iu_debug_mp` state | yes | – | |

### CFG-3 "IOMMU rev" (mask rev) (S3)

Path: OSD `status[21:20]` → `reset_mask_rev` (0x26, 0x11, 0x23, 0x30;
`SunSparcStation.sv:216-218`) → `ts_io` → `ts_dmaux`, which passes it straight
through (`ts_dmaux.vhd:356`) to `ts_iommu` register `0x3018`
(`ts_iommu.vhd:224-227`, pa `0x1000_3018` on the SS5) and keeps a copy
latched at reset in its private CONF3 register (`:286-288`, `:338`). It never
reaches the CPU: PCR/MCNTL IMPL/VER are constants. Consumers:
- SS5 OBP: `swift_rev` = `vmask@` (`0x10003018`) → the CPU node's
  `mask_rev`, branch folding on if the minor revision is non-zero, a warning
  for 0x10 (`forth-dictionary.txt:10873-10904`, `:14760`).
- OpenBIOS `mb86904_init` → `mask_rev` property (read once: hence "core
  reset after changing it").
- Linux `init_swift` (`srmmu.c:1130-1177`): 0x11, 0x20, 0x23, 0x30 →
  `Swift_lots_o_bugs`, 0x25, 0x31 → `Swift_bad_c`, else `Swift_ok`. In
  current Linux that only sets `srmmu_modtype`/`hwbug_bitmask`, which nothing
  else in `srmmu.c` reads.
- NetBSD does not read it. Solaris and NeXTSTEP: unknown (the README says
  NeXTSTEP needs 0x11).
The option is also shown on the SS20, where no CPU consumer exists.

### CFG-6 Write-back and AOW options (S3, S)

`mcu_multi.vhd:2152-2153`: `mmu_cr_wb <= wback` overrides MCNTL bit 4 every
cycle; `mmu_cr_aw <= '0'; --aow` makes the AOW OSD entry dead (also
"<AFAIRE> mmu_cr_aw", `mcu_tw.vhd:16`). Write-back applies only below the RAM
size (`WBSIZE`, `mcu_tw.vhd:654-657`) and depends on SE (C-4). The `Cachena`
gate is applied only when the PCR is written (`mcu_simple.vhd:2059-2060`), so
changing it at run time does nothing until the OS rewrites the PCR.

### CFG-7 Build options

`MMU_DIS = false`, `BOOTMODE = true`, `ASICACHE = ASIINST = true` for every
instance (`ts_core.vhd:576-584`, `:686-695`). `NCPUS = 3`, `FPU_MULTI = 0`
(one FPU per CPU) on the SS20 (`SunSparcStation.sv:298-309`); the SS5 build
forces one CPU (`ts_core.vhd:179`). `BSD_MODE` (MMU-6) and `FPU_LDASTA`
(IU-3) are package constants, not generics.

## 7. Tests to add to `tests/cpu`

| Test | Target | Checks | Finds |
|---|---|---|---|
| `t_mmu_asi4_decode` | SS5 | `0x1000` holds a pattern and the PCR does not change; `0x1300`/`0x1400` write-read; `0x500`/`0x600` do not read the PCR | MMU-1 |
| `t_mmu_ctx_bits` | SS20 | walking one over CTX bits 15:0; CTPR mask `0xffffffc0` | MMU-3 |
| `t_bus_error` | both | bypass load from an unmapped PA → tt 0x29, SFSR FT=5 + EBE, SFAR = address (needs the chipset part) | MMU-4 |
| `t_mmu_probe` | both | probe types 0-4 on valid, invalid and PTD entries: result, 0 on error | MMU-5 |
| `t_mmu_fault_regs` | both | SFSR L/AT/FT/FAV/OW for invalid, protection, privilege faults; read-to-clear; OW on a second fault; NF bit | MMU-8 |
| `t_mmu_ifault` | both | a jump mid-page into an invalid page: tt 1, SFSR 0x366 (no OW), read clears | MMU-8 |
| `t_fpu_trap_prio` | both | `fdivs` by 0 with TEM.DZ, then misaligned `st %f` → tt 7 and memory untouched, then aligned `st %f` → tt 8, cexc DZ | FPU-1 |
| `t_fpu_fq` | both | FQ contents after a trap (PC, instruction), FSR.qne, `STDFQ` with empty FQ → ftt 4, `STDFQ` in user mode → tt 3 | FPU-2 |
| `t_cp_ldst` | both | op3 0x30-0x37 → tt 0x24; in user mode no memory access | IU-3 |
| `t_wrpsr_cwp`, `t_rdasr` | both | `wr %psr` with CWP = 8 → tt 2; `rd %asr1`/`%asr2`/`%asr15, %l2` read Y, `wr %asr1` leaves Y, CASA → tt 2 | IU-5, IU-6 |
| `t_asi_width` | SS20 | a store to ASI 0x4c does not change the ASI 0x0c tag at 0 and reads back; ASI 0x38 va 0 holds a 64-bit value | MMU-12, SMP-1 |
| `t_cache_flush_miss` | SS20 | WB on: store to a line, touch 5 other pages, `flush` it, read back through ASI 0x20 | C-3 |
| `t_flash_clear` | SS20 | line cached, DE off, store, flash clear, DE on, load sees the new value | C-2 |
| `t_selfmod` | both | write an instruction, `flush`, execute it | C-3 |

A GHDL test bench (installable, see Decisions) should cover what the in-PROM
suite cannot: error mode and watchdog (IU-1), L2TLB after reset (CFG-1), the
`smpmux` watchdog (C-5) and two-CPU coherency with SE on and off (C-4).

## 8. Open questions

1. Under OpenBIOS, does NetBSD really run its secondaries with SE = 0 (read
   MCNTL on CPU 1 and 2 through the monitor)? If yes, how does it survive?
2. Why is NeXTSTEP incompatible with the L2TLB? The L2TLB is invalidated on
   every flush, so a correct OS cannot tell it from a larger TLB; candidates:
   NeXTSTEP changes PTEs without flushing, relying on the 64-entry TLB being
   replaced, or it invalidates TLB entries through ASI 6 (ignored, MMU-2).
3. How does Solaris 2.x on sun4m find its own MID on a module without MXCC
   (ASI 0x38, `%tbr`, a PROM mailbox)? That decides what SMP-1 must provide
   for Solaris MP.
4. Does the `smpmux` 128-cycle limit fire on hardware, and what does it do to
   a write-back burst in progress?
5. Which OBP 2.15 words bind to the ASI 4 `afsr@`/`afar@` (`0x500`/`0x600`)
   rather than the later SBus ones (`0x10001000`)?
6. The arbiter-enable semantics for a stopped CPU (ss20 README §8), and which
   reset (per-CPU watchdog vs system) the core should generate for IU-1.
7. OBP 2.25 I-cache tag clear loop count and stride (C-2): does it cover the
   core's 128 sets?
