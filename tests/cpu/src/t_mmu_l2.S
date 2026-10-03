/* The second-level TLB (mcu_tw.vhd, MCNTL bit 6 with the OSD option; the
 * simulation's --l2tlb) must be invisible: a correct OS cannot tell it
 * from a larger TLB. Three ways it could show (audit CFG-1, open
 * question 2), each a test here; without the option the tests pass
 * trivially, and QEMU, which has no bit 6, passes them as a reference.
 *   - a write through the TLB diagnostic ASI 6 (NeXTSTEP's suspected
 *     way of invalidating entries) drops the TLBs and the L2 TLB: a PTE
 *     changed in memory is seen without an ASI 3 flush;
 *   - the L2 TLB enabled at run time serves no entry left from before:
 *     its block RAM keeps entries across resets and off periods, and its
 *     8-bit generation wraps (every CTPR write bumps it) so a stale entry
 *     could match again: the core sweeps the whole RAM when the L2 TLB
 *     comes on;
 *   - an ASI 3 probe returns the PTE in memory, not a cached one.
 * The page tables are mmu_setup.S's; the remappable page MT_P_REMAP as in
 * t_mmu_tlb_flush. */
#include "macros.h"

#define L2_MARK(i)      (0x4c200000 + (i))
#define L2_SET_PTE(val, pa)  set val, %o4 ; set pa, %o5 ; st %o4, [%o5] ; \
        sta %g0, [%l0] 0x10
#define L2_BIT6(on)                                              \
        lda [%g0] 0x04, %o0 ;                                    \
        .if on ; or %o0, 0x40, %o0 ; .else ; andn %o0, 0x40, %o0 ; .endif ; \
        sta %o0, [%g0] 0x04 ; nop ; nop ; nop

BEGIN(t_mmu_l2_asi6, "mmu: an ASI 6 write drops the TLBs (and the L2 TLB): a changed PTE is seen with no ASI 3 flush")
        call mmu_tables_init
        nop
        STPAV(L2_MARK(22), MT_PAGE(22))
        STPAV(L2_MARK(23), MT_PAGE(23))
        STPAV(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_on
        nop
        L2_BIT6(1)
        set MT_PAGE(MT_P_REMAP), %l0
        ld [%l0], %l1                   /* 22: the TLBs hold the PTE */
        L2_SET_PTE(PTE_C3(MT_PAGE(23)), MT_L3 + MT_P_REMAP * 4)
        ld [%l0], %l2                   /* still 22 */
        sta %g0, [%l0] 0x10
        mov 0x200, %o5                  /* ASI 6 entry 0 SEL2 := 0 */
        sta %g0, [%o5] 6
        ld [%l0], %l3                   /* 23: through the tables again */
        L2_SET_PTE(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_off
        nop
        L2_BIT6(0)
        EXPECT(%l1, L2_MARK(22), 1)
        EXPECT(%l2, L2_MARK(22), 2)
        EXPECT(%l3, L2_MARK(23), 3)
END

/* The entry goes into the L2 TLB at generation g (bit 6 on), is evicted
 * from the 4-entry D-TLB by other pages (no flush, no bump), the PTE
 * changes in memory, 256 CTPR writes with bit 6 off bring the generation
 * back to g, and bit 6 comes on again: the next walk must not hit it. */
BEGIN(t_mmu_l2_enable, "mmu: the L2 TLB enabled at run time serves no entry of an earlier generation")
        call mmu_tables_init
        nop
        STPAV(L2_MARK(22), MT_PAGE(22))
        STPAV(L2_MARK(24), MT_PAGE(24))
        STPAV(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_on
        nop
        L2_BIT6(1)
        set MT_PAGE(MT_P_REMAP), %l0
        ld [%l0], %l1                   /* 22: in the L2 TLB, generation g */
        L2_BIT6(0)
        L2_SET_PTE(PTE_C3(MT_PAGE(24)), MT_L3 + MT_P_REMAP * 4)
        sta %g0, [%l0] 0x10
        set MT_PAGE(0), %l2             /* 8 other pages: the D-TLB forgets it */
        sethi %hi(0x1000), %l4
        mov 8, %l3
1:      ld [%l2], %g0
        subcc %l3, 1, %l3
        bne 1b
        add %l2, %l4, %l2
        mov 0x100, %l2
        lda [%l2] 4, %l3                /* CTPR, written back 256 times */
        mov 256, %l4
2:      sta %l3, [%l2] 4
        subcc %l4, 1, %l4
        bne 2b
        nop
        L2_BIT6(1)
        ld [%l0], %l5                   /* 24, from the tables */
        L2_SET_PTE(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_off
        nop
        L2_BIT6(0)
        EXPECT(%l1, L2_MARK(22), 1)
        EXPECT(%l5, L2_MARK(24), 2)
END

BEGIN(t_mmu_l2_probe, "mmu: an ASI 3 probe returns the PTE in memory after a change with no flush (L2 TLB on)")
        call mmu_tables_init
        nop
        STPAV(L2_MARK(22), MT_PAGE(22))
        STPAV(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_on
        nop
        L2_BIT6(1)
        set MT_PAGE(MT_P_REMAP), %l0
        ld [%l0], %l1                   /* 22: the TLBs hold the PTE */
        L2_SET_PTE(PTE_C3(MT_PAGE(25)), MT_L3 + MT_P_REMAP * 4)
        set MT_PAGE(MT_P_REMAP) | 0x400, %o5
        lda [%o5] 3, %l2                /* probe entire */
        L2_SET_PTE(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_off
        nop
        L2_BIT6(0)
        EXPECT(%l1, L2_MARK(22), 1)
        EXPECT(%l2, PTE_C3(MT_PAGE(25)), 2)
END
