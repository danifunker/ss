/* SRMMU tests on the shared page tables of mmu_setup.S: the SS20's 16-bit
 * context register and contexts above 255 (audit MMU-3), TLB flush
 * scopes, ASI 3 probes (MMU-5) and the synchronous fault registers
 * (MMU-8). References: SPARC V8 appendix H (probe table H-4, SFSR
 * fields), microSPARC-II User's Manual 5.5.2 (probe returns 0 on an
 * invalid or reserved entry) and 5.6.4 (OW rules), Sun-4M System
 * Architecture 4.4, the SS20 POST "MMU Context Table Reg" / "MMU Context
 * Register" tests (post-tests.md section 4) and QEMU target/sparc. */
#include "macros.h"

#if defined(TARGET_SS20)
/* Walking one over the context register (SuperSPARC: 16 bits, QEMU
 * mmu_cxr_mask 0xffff; the POST checks 12) and over CTPR bits 31:6 (POST
 * mask 0xfffffc00, QEMU 0xffffffc0; bits 5:0 are not checked). MMU off. */
BEGIN(t_mmu_ctx_bits, "mmu: SS20 context register has 16 bits, CTPR bits 31:6 stick")
        mov 0x200, %l0
        lda [%l0] 4, %l6                /* save CXR */
        mov 0x100, %l1
        lda [%l1] 4, %l7                /* save CTPR */
        mov 1, %l2
        clr %l3
1:      sta %l2, [%l0] 4
        lda [%l0] 4, %o1
        set 0xffff, %o2
        and %l2, %o2, %o2
        call check_eq
        add %l3, 0x100, %o0             /* codes 0x100 + bit */
        add %l3, 1, %l3
        cmp %l3, 32
        bl 1b
        sll %l2, 1, %l2
        set 0x5a5a5a5a, %l2
        sta %l2, [%l0] 4
        lda [%l0] 4, %l4
        EXPECT(%l4, 0x5a5a, 0x140)
        set 0xa5a5a5a5, %l2
        sta %l2, [%l0] 4
        lda [%l0] 4, %l4
        EXPECT(%l4, 0xa5a5, 0x141)
        mov 0x40, %l2
        mov 6, %l3
2:      sta %l2, [%l1] 4
        lda [%l1] 4, %o1
        set 0xffffffc0, %o2
        and %o1, %o2, %o1
        mov %l2, %o2
        call check_eq
        add %l3, 0x200, %o0             /* codes 0x200 + bit */
        add %l3, 1, %l3
        cmp %l3, 32
        bl 2b
        sll %l2, 1, %l2
        sta %l6, [%l0] 4
        sta %l7, [%l1] 4
END

/* mt_ctx_switch(ctx %o0): context register, TLB flush; leaf */
mt_ctx_switch:
        mov 0x200, %o1
        sta %o0, [%o1] 4
        mov 0x400, %o1
        retl
        sta %g0, [%o1] 3

/* Contexts 1, 0x101 and 0x8001 map MT_CTXVA to three pages; with an 8-bit
 * register 0x101 and 0x8001 alias context 1 (MMU-3). */
BEGIN(t_mmu_ctx_hi, "mmu: SS20 contexts 1, 0x101, 0x8001 translate the same VA differently")
        call mmu_tables_init
        nop
        STPAV(0xa0000001, MT_PAGE(MT_P_CTX0 + 0))
        STPAV(0xb0000101, MT_PAGE(MT_P_CTX0 + 1))
        STPAV(0xc0008001, MT_PAGE(MT_P_CTX0 + 2))
        call mmu_on
        nop
        set MT_CTXVA, %l0
        call mt_ctx_switch
        mov 1, %o0
        ld [%l0], %l1
        set 0x101, %o0
        call mt_ctx_switch
        nop
        ld [%l0], %l2
        set 0x8001, %o0
        call mt_ctx_switch
        nop
        ld [%l0], %l3
        call mt_ctx_switch
        mov 1, %o0
        ld [%l0], %l4
        call mmu_off                    /* back to context 0, MMU off */
        nop
        EXPECT(%l1, 0xa0000001, 1)
        EXPECT(%l2, 0xb0000101, 2)
        EXPECT(%l3, 0xc0008001, 3)
        EXPECT(%l4, 0xa0000001, 4)
END
#endif

/* The PTE of page MT_P_REMAP is changed in memory (normal stores, as an
 * OS does; the core's SS5 walker reads the tables through its D-cache, so
 * a bypass store would stay invisible) while the TLB holds its
 * translation: the old page is read until the flush that covers the
 * entry (page, then segment, region, context, entire). Pages 22-27 carry
 * markers; the D-cache line of the VA is flushed with each change (SS5:
 * virtually tagged cache). (A page flush of another page is not checked: QEMU, which maps
 * the segment-level entries as large pages, flushes its whole TLB on any
 * page flush inside their range.) */
/* The SS5's D-cache is virtually tagged (as the microSPARC-II's): a load
 * of the remapped VA would hit the old page's data without consulting the
 * TLB, so the line is flushed by VA after every change, as an OS does. */
#define SET_PTE(val, pa)  set val, %o4 ; set pa, %o5 ; st %o4, [%o5] ; \
        sta %g0, [%l0] 0x10
BEGIN(t_mmu_tlb_flush, "mmu: a changed PTE is seen after the matching ASI 3 flush, not before")
        call mmu_tables_init
        nop
        STPAV(0x7a000016, MT_PAGE(22))
        STPAV(0x7a000017, MT_PAGE(23))
        STPAV(0x7a000018, MT_PAGE(24))
        STPAV(0x7a000019, MT_PAGE(25))
        STPAV(0x7a00001a, MT_PAGE(26))
        STPAV(0x7a00001b, MT_PAGE(27))
        call mmu_on
        nop
        set MT_PAGE(MT_P_REMAP), %l0
        ld [%l0], %l1                   /* 22: the TLB now holds it */
        SET_PTE(PTE_C3(MT_PAGE(23)), MT_L3 + MT_P_REMAP * 4)
        ld [%l0], %l2                   /* still 22 */
        sta %g0, [%l0] 3                /* page flush (type 0) */
        ld [%l0], %l4                   /* 23 */
        SET_PTE(PTE_C3(MT_PAGE(24)), MT_L3 + MT_P_REMAP * 4)
        set MT_SEG | 0x100, %o0         /* segment */
        sta %g0, [%o0] 3
        ld [%l0], %l5                   /* 24 */
        SET_PTE(PTE_C3(MT_PAGE(25)), MT_L3 + MT_P_REMAP * 4)
        set 0x200, %o0                  /* region 0 */
        sta %g0, [%o0] 3
        ld [%l0], %l6                   /* 25 */
        SET_PTE(PTE_C3(MT_PAGE(26)), MT_L3 + MT_P_REMAP * 4)
        set 0x300, %o0                  /* context */
        sta %g0, [%o0] 3
        ld [%l0], %l7                   /* 26 */
        SET_PTE(PTE_C3(MT_PAGE(27)), MT_L3 + MT_P_REMAP * 4)
        set 0x400, %o0                  /* entire */
        sta %g0, [%o0] 3
        ld [%l0], %i0                   /* 27 */
        SET_PTE(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_off
        nop
        EXPECT(%l1, 0x7a000016, 1)
        EXPECT(%l2, 0x7a000016, 2)
        EXPECT(%l4, 0x7a000017, 4)
        EXPECT(%l5, 0x7a000018, 5)
        EXPECT(%l6, 0x7a000019, 6)
        EXPECT(%l7, 0x7a00001a, 7)
        EXPECT(%i0, 0x7a00001b, 8)
END

/* ASI 3 probes walk the tables from CTPR/CTX, MMU off. R and M are set
 * beforehand in the entries probed, so the words are known constants.
 * A probe that finds an invalid or reserved entry, or a PTE above the
 * level asked for, returns 0 (manual 5.5.2; V8 H-4); the core returns the
 * raw word on the error paths (MMU-5). QEMU returns a PTE found above the
 * level asked for (check 10). */
#define PTE_RM(pa)  (PTE_C3(pa) | 0x60)
BEGIN(t_mmu_probe, "mmu: ASI 3 probes page/segment/region/context/entire; 0 on invalid, reserved")
        call mmu_tables_init
        nop
        STPAV(PTE_RM(MT_PAGE(0)), MT_L3)
        STPAV(PTE_RM(VARS & 0xfffc0000), MT_L2 + (VARS >> 18) * 4)
        call mmu_ctx_set
        nop
        set MT_PAGE(0), %l0
        lda [%l0] 3, %l1                /* page */
        EXPECT(%l1, PTE_RM(MT_PAGE(0)), 1)
        set MT_PAGE(0) | 0x100, %l0
        lda [%l0] 3, %l1                /* segment: the PTD to L3 */
        EXPECT(%l1, PTD(MT_L3), 2)
        set MT_SEG | 0x200, %l0
        lda [%l0] 3, %l1                /* region: the PTD to L2 */
        EXPECT(%l1, PTD(MT_L2), 3)
        set 0x300, %l0
        lda [%l0] 3, %l1                /* context: the PTD to L1 */
        EXPECT(%l1, PTD(MT_L1), 4)
        set MT_PAGE(0) | 0x400, %l0
        lda [%l0] 3, %l1                /* entire: the level-3 PTE */
        EXPECT(%l1, PTE_RM(MT_PAGE(0)), 5)
        set VARS | 0x400, %l0
        lda [%l0] 3, %l1                /* entire: a level-2 PTE */
        EXPECT(%l1, PTE_RM(VARS & 0xfffc0000), 6)
        set VARS | 0x100, %l0
        lda [%l0] 3, %l1                /* segment probe of the same */
        EXPECT(%l1, PTE_RM(VARS & 0xfffc0000), 7)
        set MT_PAGE(MT_P_INVALID), %l0
        lda [%l0] 3, %l1                /* invalid level-3 entry */
        EXPECT(%l1, 0, 8)
        set 0x80000000, %l0
        lda [%l0] 3, %l1                /* invalid level-1 entry */
        EXPECT(%l1, 0, 9)
        set MT_PAGE(MT_P_RESERVED), %l0
        lda [%l0] 3, %l1                /* reserved entry (ET 3) */
        EXPECT(%l1, 0, 10)
        set VARS, %l0
        lda [%l0] 3, %l1                /* page probe, PTE at level 2 */
        EXPECT(%l1, 0, 11)
END

/* SFSR = EBE[17:10] L[9:8] AT[7:5] FT[4:2] FAV[1] OW[0]; AT 1 = supervisor
 * data load, 5 = supervisor data store, 0 = user data load; FT 1 invalid,
 * 2 protection, 3 privilege, 4 translation. L is the level of the entry
 * that faulted, protection and privilege faults included (MMU-8). SFAR =
 * the fault VA (compared per page: QEMU records the page address). OW is
 * set when a data fault overwrites an unread data fault (manual table 28).
 * NF: a supervisor data fault is recorded but not trapped. */
BEGIN(t_mmu_fault_regs, "mmu: SFSR L/AT/FT/FAV/OW and SFAR on invalid, reserved, protection, privilege faults; NF")
        call mmu_tables_init
        nop
        call mmu_on
        nop
        mov 0x300, %l6
        mov 0x400, %l7
        lda [%l6] 4, %g0                /* clear */
        /* invalid level-3 entry */
        set MT_PAGE(MT_P_INVALID), %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 1)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x326, 2)
        lda [%l7] 4, %l1
        set 0xfffff000, %l2
        and %l1, %l2, %l1
        EXPECT(%l1, MT_PAGE(MT_P_INVALID), 3)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0, 4)               /* read clears */
        /* invalid level-1 entry */
        set 0x80000000, %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 5)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x126, 6)
        lda [%l7] 4, %l1
        and %l1, %l2, %l1
        EXPECT(%l1, 0x80000000, 7)
        /* reserved entry: translation error */
        set MT_PAGE(MT_P_RESERVED), %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 8)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x332, 9)
        /* protection: a store to a read-only page */
        set MT_PAGE(MT_P_RDONLY), %l0
        EXPECT_TRAP(TT_DACC)
        st %g0, [%l0]
        CHECK_TRAPPED(TT_DACC, 10)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x3aa, 11)
        /* privilege: a user load from a supervisor-only page; ta SVC_SUPER
         * brings the test back to supervisor mode */
        set MT_PAGE(MT_P_SUPER), %l0
        EXPECT_TRAP(TT_DACC)
        rd %psr, %l3
        andn %l3, PSR_S, %l4
        wr %l4, %psr
        nop ; nop ; nop
        ld [%l0], %l1
        ta SVC_SUPER
        CHECK_TRAPPED(TT_DACC, 12)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x30e, 13)
        /* two data faults without a read in between: OW */
        set MT_PAGE(MT_P_INVALID), %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 14)
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 15)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x327, 16)
        /* NF: recorded, not trapped */
        lda [%g0] 4, %l3
        or %l3, MCR_NF, %l4
        sta %l4, [%g0] 4
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_NOT_TRAPPED(17)
        lda [%l6] 4, %l1
        andn %l1, 1, %l1                /* OW: QEMU reports it twice */
        EXPECT(%l1, 0x326, 18)
        sta %l3, [%g0] 4
        call mmu_off
        nop
END
