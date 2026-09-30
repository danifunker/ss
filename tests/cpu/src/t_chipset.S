/* Chipset registers after a power-on reset, and the address decode of the
 * PROM, the NVRAM IDPROM and the frame buffer's FCode. Not CPU tests: they
 * check the core's chipset fixes (docs/impl-gaps/chipset.md, AUX-1, DMA-2,
 * INT-1, TOD-5; design/sun-obp-boot.md M1, M5) with the suite's plumbing.
 * Physical addresses through the MMU bypass ASIs: 0x20 for pa[35:32] = 0,
 * 0x2e/0x2f for 0xe/0xf. */
#include "macros.h"

#if defined(TARGET_SS20)
#  define SYSCON_PA     0xf1f00000      /* ASI 0x2f: pa 0xf_f1f0_0000 */
#  define SYSCON_ASI    0x2f
#  define NVRAM_PA      0xf1200000      /* ASI 0x2f: pa 0xf_f120_0000 */
#  define NVRAM_ASI     0x2f
#  define TCX_PA        0x20000000      /* ASI 0x2e: pa 0xe_2000_0000 */
#  define TCX_ASI       0x2e
#  define EBASE_PA      0xf040001c      /* ASI 0x2e: DMA2 E_BASE_ADDR */
#  define EBASE_ASI     0x2e
#  define MACHINE_TYPE  0x72
#else
#  define SYSCON_PA     0x71f00000
#  define SYSCON_ASI    0x20
#  define NVRAM_PA      0x71200000
#  define NVRAM_ASI     0x20
#  define TCX_PA        0x50000000      /* SBus slot 3 */
#  define TCX_ASI       0x20
#  define EBASE_PA      0x7840001c
#  define EBASE_ASI     0x20
#  define MACHINE_TYPE  0x80
#endif

BEGIN(t_syscon, "chipset: system control reads 0 after power-on (RS, WD clear)")
        set SYSCON_PA, %l0
        lda [%l0] SYSCON_ASI, %l1
        and %l1, 0x13, %l1              /* SR (reads 0), RS, WD */
        EXPECT(%l1, 0, 1)
END

BEGIN(t_idprom, "chipset: NVRAM IDPROM format 1, machine type, checksum")
        set NVRAM_PA + 0x1fd8, %l0
        lduba [%l0] NVRAM_ASI, %l1
        EXPECT(%l1, 1, 1)               /* format */
        add %l0, 1, %l2
        lduba [%l2] NVRAM_ASI, %l1
        EXPECT(%l1, MACHINE_TYPE, 2)
        clr %l3                         /* XOR of all 16 bytes is 0 */
        clr %l4
1:      lduba [%l0 + %l4] NVRAM_ASI, %l1
        xor %l3, %l1, %l3
        add %l4, 1, %l4
        cmp %l4, 16
        bl 1b
        nop
        EXPECT(%l3, 0, 3)
END

BEGIN(t_fcode, "chipset: frame buffer slot starts with FCode (0xf1 header)")
        set TCX_PA, %l0
        lduba [%l0] TCX_ASI, %l1
        EXPECT(%l1, 0xf1, 1)            /* FCode start byte */
        add %l0, 4, %l0
        lda [%l0] TCX_ASI, %l1          /* image length */
        cmp %l1, 16
        bl 2f
        mov 0, %l2
        set 0x10000, %l3
        cmp %l1, %l3
        bg 2f
        nop
        mov 1, %l2
2:      EXPECT(%l2, 1, 2)               /* 16 <= length <= 64 KiB */
END

BEGIN(t_ebase, "chipset: DMA2 E_BASE_ADDR resets to 0xff")
        set EBASE_PA, %l0
        lda [%l0] EBASE_ASI, %l1
        srl %l1, 24, %l1
        EXPECT(%l1, 0xff, 1)
END

#if defined(TARGET_SS5_QEMU) || defined(TARGET_SS5_CORE)
BEGIN(t_prom70, "chipset: the PROM answers at pa 0x7000_0000")
        set 0x70000000, %l0             /* pa of the SS5 boot PROM */
        lda [%l0] 0x20, %l1
        set trap_table, %l2             /* the running image's first word */
        ld [%l2], %l3
        EXPECT_R(%l1, %l3, 1)
END
#endif
