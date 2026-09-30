# CPU test suite

A bare-metal SPARC V8 test suite that runs **as the boot PROM**. It starts
at the reset vector with the MMU off, sets up traps, windows and a stack,
prints on ttya (ESCC channel A, 9600 8N1), and runs its tests one after
another. The same source runs in three places:

| target | runs on | PROM link address |
|---|---|---|
| `ss5-qemu` | `qemu-system-sparc -M SS-5` | `0x70000000` (a real SPARCstation 5's) |
| `ss5-core` | this core's SS5 build, loaded through the OSD's **BIOS** entry (`F,ROM`) in place of `boot.rom` | `0xF0000000` (`rtl/sun4m/ts_decode.vhd`, `sel.rom`) |
| `ss20` | `qemu-system-sparc -M SS-20`, and the core's SS20 build | `0` (boot mode); pa `0xF_F0000000` |

The SS20 PROM is not readable at its link address with the MMU off, so
`runtime.S` first copies the image to RAM at pa 0. From then on, constants
and strings are read at their link addresses, while instructions keep
coming from the PROM in boot mode (`platform.h`).

This is phase 1f of [docs/REWORK.md](../../docs/REWORK.md). The generic V8
ISA tests are here now. The microSPARC-II and SuperSPARC hardware tests
(MMU, TLB, caches, MXCC, timers, interrupt controller) come next, lifted
from the POST catalogues in `docs/rom-disassembly/*/post-tests.md`.

## Build and run

```sh
python3 tests/cpu/build.py                 # all targets -> tests/cpu/out/<target>/cputest.rom
python3 tests/cpu/build.py ss5-qemu -DDETAIL_LIMIT=4000   # print every failing check
tests/cpu/run-qemu.sh ss5                  # run under QEMU, compare with expected/ss5-qemu.log
tests/cpu/run-qemu.sh ss20
```

Toolchain: LLVM 18's `clang --target=sparc-unknown-elf -mcpu=v8` (its
integrated assembler handles V8, the privileged instructions and ASIs
included), and [`tools/sparc_link.py`](../../tools/sparc_link.py), because
LLVM has no 32-bit SPARC linker. Everything is one translation unit
(`src/main.S`). [`tools/romdis/sparcv8.py`](../../tools/romdis/sparcv8.py)
disassembles an image:

```sh
python3 tools/romdis/sparcv8.py tests/cpu/out/ss5-qemu/cputest.rom 0x70000000 0 0x100
```

On the core: copy `out/ss5-core/cputest.rom` (or `out/ss20/cputest.rom`)
to the SD card, load it with the OSD **BIOS** entry, and read ttya from
the MiSTer UART at 9600 baud. **Not yet tried on hardware.**

## Output

```
CPUTEST ss5-qemu psr=04400fc0 nwindows=8 fpu=1
PASS alu: sethi / set / %hi %lo
FAIL alu: every integer ALU instruction, table of vectors
    check 0010a570 exp=ffffffff obs=00000000
...
CPUTEST DONE pass=29 fail=3 skip=0
```

Each `check` line names the check code, the expected value and the
observed one. At most 16 are printed per test (`DETAIL_LIMIT`). ALU vector
codes are `0x100000 + row*16 + {0 result, 1 icc, 2 Y, 3 trap}`; look the
row up in `out/alu_vectors.txt`.

## What is tested

| file | tests |
|---|---|
| `t_alu.S` + `gen_alu.py` | 3748 one-instruction vectors over every integer ALU op, register and immediate forms: add/sub with carry, logic, shifts, umul/smul (Y), udiv/sdiv with overflow and divide-by-zero, mulscc, tagged add/sub and their trapping forms. Checks the result, icc and Y, and whether it trapped. Expectations come from a Python model of the V8 manual. Also sethi/simm13 and the Y register. |
| `t_ldst.S` | load widths and sign extension, byte order, partial stores, ldd/std, ldstub/swap, lda/sta, alignment traps (nothing written, trap PC) |
| `t_branch.S` | all 16 Bicc and all 16 Ticc conditions against all 16 icc values (`gen/cond_tab.S`), annul bit and delay-slot cases, call/jmpl links, misaligned jmpl |
| `t_traps.S` | software trap numbers, illegal instructions, rett with ET=1 (illegal_instruction in supervisor mode, privileged_instruction from user mode: the test drops to S=0 and comes back with `ta SVC_SUPER`), divide by zero, tag overflow, fp_disabled, cp_disabled |
| `t_window.S` | save/restore overlap, CWP arithmetic, 40-deep recursion through the spill/fill handlers, NWINDOWS |
| `t_psr.S` | read-only impl/ver, PIL, icc, TBR.tt and TBA |
| `t_fpu.S` | single and double arithmetic, conversions, fcmp/fcc/FBfcc, FSR cexc/aexc |
| `t_chipset.S` | not CPU tests: chipset state after a power-on reset and address decode, with the suite's plumbing. The system control register reads RS = WD = 0; the NVRAM IDPROM has format 1, the machine type (0x80 SS5, 0x72 SS20) and a zero XOR checksum; the frame buffer's slot starts with FCode (`0xf1`, sane length); DMA2 E_BASE_ADDR resets to 0xff; on the SS5 the PROM answers at pa `0x7000_0000` |
| `t_mmu_swift.S` | SS5 only: the POST's microSPARC-II MMU register walking-pattern tests (CTPR, context, TLB replacement control `0x1000`, SFSR/SFAR diagnostic aliases `0x1300`/`0x1400`), with the POST's masks; AFSR/AFAR (`0x500`/`0x600`) read 0. It probes first whether `0x1000` aliases the PCR, as it did on the core before ASI 4 was decoded from VA[12:8] (audit MMU-1), and reports that instead of walking. |

## Known QEMU 8.2.2 deviations

The QEMU reference logs (`expected/*-qemu.log`) are not all-PASS. Each of
the three failures in them is QEMU disagreeing with the SPARC V8 manual,
checked against QEMU's source at tag `v8.2.2`:

1. **`sdiv`/`sdivcc` with a negative divisor.** `helper_sdiv` does
   `a64 /= b;` with the unsigned 32-bit `b` instead of the signed `b32`
   it has just computed (`target/sparc/helper.c`). For example, 1 / -1
   gives 0. 69 ALU checks fail, all sdiv/sdivcc with a divisor ≥ 2^31.
2. **nPC of a trap on a `rett` in a `jmp`'s delay slot.** QEMU reports
   nPC = the rett's own target (`jmp` target + 4) instead of the `jmp`
   target, so the handler resumes one instruction late.
3. **`wr %tbr` overwrites TBR.tt.** `do_wrtba` moves the whole value into
   `%tbr`; V8 says WRTBR writes TBA only and tt keeps the last trap type.

4. **DMA2 E_BASE_ADDR resets to 0.** The DMA2 manual gives 0xff (the
   Ethernet DMA's high address byte); QEMU leaves the register at 0. Solaris
   never writes it and assumes 0xff (OpenBIOS `ob_le_init`). New in the
   11.1.1 references with `t_chipset.S`.

The core has to follow the manual, not QEMU. On the core, these tests are
expected to pass.

## Writing a test

```asm
#include "macros.h"
BEGIN(t_name, "area: what it checks")     /* registers the test, does a save */
        ...
        EXPECT(%l0, 0x1234, 1)            /* obs register, expected constant, code */
        EXPECT_TRAP(TT_ALIGN)             /* arm the trap catcher */
        ld [%l1 + 2], %l2
        CHECK_TRAPPED(TT_ALIGN, 2)
END
```

Add the file to `src/main.S`. Register conventions are at the top of
`src/macros.h`: `%g7` belongs to the runtime; `EXPECT` clobbers the outs
and the icc.
