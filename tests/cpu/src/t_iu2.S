/* Generic V8 checks from docs/impl-gaps/cpu.md section 7: FPU trap
 * priority (FPU-1, V8 table 7-1: mem_address_not_aligned 10 before
 * fp_exception 11), the FP queue (FPU-2, V8 4.4 and B.?: STDFQ is
 * privileged; with an empty queue it is fp_exception, ftt 4
 * sequence_error), the coprocessor load/store family (IU-3: cp_disabled,
 * tt 0x24, with no coprocessor), WRPSR with CWP >= NWINDOWS (IU-5:
 * illegal_instruction), reserved ASRs (read %y, write nothing) and CASA
 * (IU-6), and on the SS20 the ASI width (MMU-12) and the ASI 0x38
 * registers (SMP-1). */
#include "macros.h"

#define FTMP2   (SCRATCH + 0x40)
#define LDF2(val, freg) set val, %o0 ; st %o0, [%g7 + V_SIZE] ; ld [%g7 + V_SIZE], freg
#define FPU_OR_SKIP2                                            \
        ld [%g7 + V_FPU], %o0 ; tst %o0 ; bne 1f ; nop ;        \
        SKIP_TEST ; 1:                                          \
        ld [%g7 + V_SKIP], %fsr
#define RD_FSR(reg)     st %fsr, [%g7 + V_SIZE] ; ld [%g7 + V_SIZE], reg

/* 1.0 / 0.0 with TEM.DZ set. A precise FPU (QEMU) traps on the fdivs; a
 * deferred one (the core, real modules) at the next FP instruction. In
 * both cases the misaligned FP store must take tt 7 and leave memory
 * alone, and exactly one fp_exception is taken; the FQ is emptied with
 * STDFQ after each fp_exception (V8: the FPU stays in exception mode
 * until then). */
BEGIN(t_fpu_trap_prio, "fpu: misaligned st %f with a pending fp_exception takes tt 7 first")
        FPU_OR_SKIP2
        LDF2(0x3f800000, %f0)
        LDF2(0x00000000, %f1)
        set 0x01000000, %o0             /* TEM.DZ */
        st %o0, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %fsr
        set FTMP2, %l0
        set 0x11223344, %l1
        st %l1, [%l0]
        st %l1, [%l0 + 4]
        EXPECT_TRAP(TT_FP_EXC)
        fdivs %f0, %f1, %f2
        nop ; nop
        ld [%g7 + V_TRAP_SEEN], %l5     /* TT_FP_EXC: precise; -1: deferred */
        mov -1, %o0
        st %o0, [%g7 + V_TRAP_EXPECT]
        cmp %l5, -1
        be 1f
        nop
        std %fq, [%g7 + V_SIZE]         /* leave exception mode */
        RD_FSR(%l6)
1:      EXPECT_TRAP(TT_ALIGN)
        st %f2, [%l0 + 2]
        CHECK_TRAPPED(TT_ALIGN, 1)
        ld [%l0], %l2
        EXPECT(%l2, 0x11223344, 2)
        ld [%l0 + 4], %l2
        EXPECT(%l2, 0x11223344, 3)
        cmp %l5, -1
        bne 2f
        nop
        EXPECT_TRAP(TT_FP_EXC)          /* deferred: now, on an FP store */
        st %f2, [%l0]
        CHECK_TRAPPED(TT_FP_EXC, 4)
        std %fq, [%g7 + V_SIZE]
        RD_FSR(%l6)
        ba 3f
        nop
2:      EXPECT_TRAP(TT_FP_EXC)          /* precise: nothing pending */
        st %f2, [%l0]
        CHECK_NOT_TRAPPED(4)
3:      srl %l6, 14, %l7
        and %l7, 7, %l7
        EXPECT(%l7, 1, 5)               /* ftt: IEEE_754_exception */
        and %l6, 0x1f, %l7
        EXPECT(%l7, 0x02, 6)            /* cexc: DZ */
        ld [%g7 + V_SKIP], %fsr
END

BEGIN(t_fpu_fq, "fpu: FQ holds the trapping FPop; STDFQ empties it, is privileged, traps when empty")
        FPU_OR_SKIP2
        LDF2(0x3f800000, %f0)
        LDF2(0x00000000, %f1)
        set 0x01000000, %o0             /* TEM.DZ */
        st %o0, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %fsr
        EXPECT_TRAP(TT_FP_EXC)
9:      fdivs %f0, %f1, %f2
        nop
        ld [%g7 + V_TRAP_SEEN], %l5
        cmp %l5, -1
        bne 1f                          /* precise FPU: taken already */
        nop
        fmovs %f2, %f3                  /* deferred FPU: taken here */
        nop
1:      CHECK_TRAPPED(TT_FP_EXC, 1)
        RD_FSR(%l1)
        srl %l1, 13, %l2
        and %l2, 1, %l2
        EXPECT(%l2, 1, 2)               /* qne */
        set FTMP2, %l0
        std %fq, [%l0]
        ld [%l0], %l3
        set 9b, %l4
        EXPECT_R(%l3, %l4, 3)           /* the fdivs' address */
        ld [%l0 + 4], %l3
        ld [%l4], %l5
        EXPECT_R(%l3, %l5, 4)           /* and its opcode */
        RD_FSR(%l1)
        srl %l1, 13, %l2
        and %l2, 1, %l2
        EXPECT(%l2, 0, 5)               /* empty now */
        EXPECT_TRAP(TT_PRIV)            /* STDFQ from user mode */
        rd %psr, %l6
        andn %l6, PSR_S, %l7
        wr %l7, %psr
        nop ; nop ; nop
        std %fq, [%l0]
        ta SVC_SUPER
        CHECK_TRAPPED(TT_PRIV, 6)
        EXPECT_TRAP(TT_FP_EXC)
        std %fq, [%l0]                  /* empty: sequence_error */
        nop                             /* QEMU reports this trap one instruction late */
        ld [%g7 + V_TRAP_SEEN], %l5
        cmp %l5, -1
        bne 2f                          /* precise FPU: taken already */
        nop
        fmovs %f0, %f0                  /* deferred FPU: taken here */
        nop
2:      CHECK_TRAPPED(TT_FP_EXC, 7)
        RD_FSR(%l1)
        srl %l1, 14, %l2
        and %l2, 7, %l2
        EXPECT(%l2, 4, 8)               /* ftt: sequence_error */
        /* The FPU may stay in exception mode after a sequence_error
         * (QEMU does): no FP instruction follows in the suite. */
END

/* op3 0x30-0x37 with op = 3: LDC, LDCSR, LDDC, STC, STCSR, STDCQ, STDC
 * (V8 B.?): cp_disabled on a machine without a coprocessor, in user mode
 * too, and the store forms leave memory alone. rs1 = %l0, rd = %c0,
 * simm13 = 0. */
#define CPLS(op3)   .word (0xc0000000 | ((op3) << 19) | (16 << 14) | 0x2000)
BEGIN(t_cp_ldst, "trap: LDC/STC family -> cp_disabled (0x24), no memory access")
        set SCRATCH, %l0
        set 0x5c5c5c5c, %l1
        st %l1, [%l0]
        st %l1, [%l0 + 4]
        EXPECT_TRAP(TT_CP_DISABLED)
        CPLS(0x30)                      /* ldc */
        CHECK_TRAPPED(TT_CP_DISABLED, 1)
        EXPECT_TRAP(TT_CP_DISABLED)
        CPLS(0x31)                      /* ldcsr */
        CHECK_TRAPPED(TT_CP_DISABLED, 2)
        EXPECT_TRAP(TT_CP_DISABLED)
        CPLS(0x33)                      /* lddc */
        CHECK_TRAPPED(TT_CP_DISABLED, 3)
        EXPECT_TRAP(TT_CP_DISABLED)
        CPLS(0x34)                      /* stc */
        CHECK_TRAPPED(TT_CP_DISABLED, 4)
        EXPECT_TRAP(TT_CP_DISABLED)
        CPLS(0x35)                      /* stcsr */
        CHECK_TRAPPED(TT_CP_DISABLED, 5)
        EXPECT_TRAP(TT_CP_DISABLED)
        CPLS(0x36)                      /* stdcq */
        CHECK_TRAPPED(TT_CP_DISABLED, 6)
        EXPECT_TRAP(TT_CP_DISABLED)
        CPLS(0x37)                      /* stdc */
        CHECK_TRAPPED(TT_CP_DISABLED, 7)
        ld [%l0], %l2
        EXPECT(%l2, 0x5c5c5c5c, 8)
        ld [%l0 + 4], %l2
        EXPECT(%l2, 0x5c5c5c5c, 9)
        EXPECT_TRAP(TT_CP_DISABLED)     /* from user mode */
        rd %psr, %l6
        andn %l6, PSR_S, %l7
        wr %l7, %psr
        nop ; nop ; nop
        CPLS(0x34)                      /* stc */
        ta SVC_SUPER
        CHECK_TRAPPED(TT_CP_DISABLED, 10)
        ld [%l0], %l2
        EXPECT(%l2, 0x5c5c5c5c, 11)
END

BEGIN(t_wrpsr_cwp, "trap: wr %psr with CWP = NWINDOWS -> illegal_instruction")
        rd %psr, %g1
        ld [%g7 + V_NWINDOWS], %g2
        andn %g1, 0x1f, %g3
        or %g3, %g2, %g2
        EXPECT_TRAP(TT_ILLEGAL)
        wr %g2, %psr
        nop ; nop ; nop
        wr %g1, %psr                    /* back, if it wrapped instead */
        nop ; nop ; nop
        CHECK_TRAPPED(TT_ILLEGAL, 1)
        rd %psr, %l0
        and %l0, 0x1f, %l0
        and %g1, 0x1f, %l1
        EXPECT_R(%l0, %l1, 2)
END

/* Reserved ASRs: V8 B.28/B.29 leave them to the implementation. The
 * microSPARC-I and -II manuals say every ASR read acts as RDY and every
 * ASR write as a NOP (QEMU does the same), and OpenSSL's libcrypto relies
 * on it: it tells V8 from V9 with "wr %g0, %y; rd %asr2" (%y on V8, %ccr
 * on V9), so NetBSD's syslogd and login died of SIGILL when the core
 * trapped reserved ASRs. rd %asr15 with rd = 0 is STBAR. CASA (op3 0x3c,
 * V9/LEON) is illegal_instruction on both modules. */
BEGIN(t_rdasr, "iu: reserved ASRs read %y, writes do nothing; CASA -> illegal_instruction")
        set 0x5a5a1234, %o0
        wr %o0, %y
        nop ; nop ; nop
        clr %l0 ; clr %l1 ; clr %l2
        set 0x0bad0bad, %l4
        EXPECT_TRAP(TT_ILLEGAL)
        .word 0xa1404000                /* rd %asr1, %l0 */
        .word 0xa3408000                /* rd %asr2, %l1 */
        .word 0xa543c000                /* rd %asr15, %l2 */
        .word 0x83850000                /* wr %l4, %g0, %asr1 */
        nop ; nop ; nop                 /* (the WRY delay, were it one) */
        rd %y, %l3
        CHECK_NOT_TRAPPED(1)
        EXPECT(%l0, 0x5a5a1234, 2)
        EXPECT(%l1, 0x5a5a1234, 3)
        EXPECT(%l2, 0x5a5a1234, 4)
        EXPECT(%l3, 0x5a5a1234, 5)
        set SCRATCH, %l0
        set 0x3a3a3a3a, %l1
        st %l1, [%l0]
        set 0x11111111, %l1             /* != memory: CASA would not store */
        EXPECT_TRAP(TT_ILLEGAL)
        .word 0xe5e40171                /* casa [%l0] 0xb, %l1, %l2 */
        CHECK_TRAPPED(TT_ILLEGAL, 6)
        ld [%l0], %l2
        EXPECT(%l2, 0x3a3a3a3a, 7)
END

#if defined(TARGET_SS20)
/* ASI 0x4c (the SuperSPARC ACTION register, written 0 by OBP 2.25) must
 * not reach the ASI 0x0c I-cache tag at index 0 (the core kept 6 ASI
 * bits, MMU-12); the tag is compared before and after, since QEMU reads
 * the tag ASIs as 0. ACTION itself must read back (Solaris 8). ASI 0x38
 * va 0 and 0x100 (MMU breakpoint value and mask, 36 bits) must hold
 * 64-bit values: OBP 2.25 keeps the MID there (SMP-1). */
BEGIN(t_asi_width, "mmu: SS20 ASI 0x4c is a register, not ASI 0x0c; ASI 0x38 holds 64-bit values")
        set 0x100, %o0
        sta %o0, [%g0] 0x0c             /* an invalid, non-zero tag */
        lda [%g0] 0x0c, %l0
        sta %g0, [%g0] 0x4c             /* ACTION = 0 */
        lda [%g0] 0x0c, %l1
        EXPECT_R(%l1, %l0, 1)
        sta %g0, [%g0] 0x0c
        set 0x0000000a, %l2
        set 0x12345678, %l3
        stda %l2, [%g0] 0x38
        set 0x100, %l4
        set 0x00000005, %l6
        set 0x9abcdef0, %l7
        stda %l6, [%l4] 0x38
        ldda [%g0] 0x38, %l2
        EXPECT(%l2, 0x0000000a, 2)
        EXPECT(%l3, 0x12345678, 3)
        ldda [%l4] 0x38, %l6
        EXPECT(%l6, 0x00000005, 4)
        EXPECT(%l7, 0x9abcdef0, 5)
        clr %l2
        clr %l3
        stda %l2, [%g0] 0x38
        stda %l2, [%l4] 0x38
        /* ACTION (ASI 0x4c, 13 bits in QEMU) reads back what was written:
         * Solaris 8's SuperSPARC setup writes 0x1000 (MIX) and loops
         * until it reads it back */
        set 0x1000, %o0
        sta %o0, [%g0] 0x4c
        lda [%g0] 0x4c, %l5
        EXPECT(%l5, 0x1000, 6)
        set 0x0aaa, %o0
        sta %o0, [%g0] 0x4c
        lda [%g0] 0x4c, %l5
        EXPECT(%l5, 0x0aaa, 7)
        sta %g0, [%g0] 0x4c
        lda [%g0] 0x4c, %l5
        EXPECT(%l5, 0, 8)
END
#endif
