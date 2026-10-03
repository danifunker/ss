/* kbdtest: the Sun keyboard as the machine sees it (PLAN.md B2), built
 * apart from the suite (python3 tests/cpu/build.py ss20 --main=kbdtest) and
 * driven from the MiSTer by scripts/hwtest.sh's kbd test, which types on a
 * virtual keyboard (scripts/board/uinput_keys.py): the keys reach the core
 * as PS/2 through Main, go through ts_ps2sun and ts_sunkb, and arrive on
 * the keyboard ESCC's channel A, which this ROM polls.
 *
 * It prints "KBD?", then every byte received, in hex, until 2 s pass with
 * nothing (the first within 20 s); then "RST?" and the same for the keys
 * the host now holds down; then it sends the keyboard its reset command
 * (0x01) and prints the reply: FF 04, the held keys the PROM looks for
 * (Stop, A, N, D, F), 7F. The output is compared with a recorded board log; there is nothing
 * to check in simulation (no PS/2 keyboard there). */
#include "runtime.S"

        .text

#if defined(TARGET_SS20)
#  define KBD_CTRL      0xf1000004      /* ASI 0x2f: pa 0xf_f100_0004 */
#else
#  define KBD_CTRL      0x71000004
#endif
#define KBD_DATA        (KBD_CTRL + 2)
#define POLLS_1S        1500000         /* about a second of polling */

/* write keyboard channel register %o0 with %o1 */
kwr:    set KBD_CTRL, %o2
        stba %o0, [%o2] IO_ASI
        retl
        stba %o1, [%o2] IO_ASI

/* %o0 = the next byte from the keyboard, or -1 after %o0 polls */
kget:   set KBD_CTRL, %o2
1:      lduba [%o2] IO_ASI, %o1         /* RR0 */
        andcc %o1, 1, %g0
        bne 2f
        subcc %o0, 1, %o0
        bne 1b
        nop
        retl
        mov -1, %o0
2:      set KBD_DATA, %o2
        retl
        lduba [%o2] IO_ASI, %o0

/* print the bytes received until %i0 polls pass with none, at most %i1
 * bytes */
kdump:  save %sp, -96, %sp
        clr %l0                         /* bytes printed */
1:      call kget
        mov %i0, %o0
        tst %o0
        bl 2f
        nop
        call puthex8
        nop
        set s_sp, %o0
        call puts
        nop
        add %l0, 1, %l0
        and %l0, 15, %o0
        tst %o0
        bne 3f
        nop
        set s_nl, %o0
        call puts
        nop
3:      cmp %l0, %i1
        bl 1b
        nop
2:      set s_nl, %o0
        call puts
        nop
        ret
        restore

/* print %o0's low byte as two hex digits */
puthex8: save %sp, -96, %sp
        srl %i0, 4, %o0
        and %o0, 0xf, %o0
        cmp %o0, 10
        bl 1f
        add %o0, '0', %l0
        add %o0, 'a' - 10, %l0
1:      call putc
        mov %l0, %o0
        and %i0, 0xf, %o0
        cmp %o0, 10
        bl 2f
        add %o0, '0', %l0
        add %o0, 'a' - 10, %l0
2:      call putc
        mov %l0, %o0
        ret
        restore

/* print what arrives: the first byte within 20 s, then until 2 s pass
 * with nothing, at most 200 bytes */
kcollect:
        save %sp, -96, %sp
        set 20 * POLLS_1S, %o0
        call kget
        nop
        tst %o0
        bl 1f
        nop
        call puthex8
        nop
        set s_sp, %o0
        call puts
        nop
        set 2 * POLLS_1S, %o0
        call kdump
        mov 200, %o1
        ret
        restore
1:      set s_nl, %o0
        call puts
        nop
        ret
        restore

BEGIN(t_kbd_dump, "kbd: the keys typed, as Sun codes, then the reset reply")
        mov 0xc1, %o1                   /* WR3: 8 bits, receiver on */
        call kwr
        mov 3, %o0
        mov 0x68, %o1                   /* WR5: 8 bits, transmitter on */
        call kwr
        mov 5, %o0
        clr %o1                         /* WR1: no interrupts */
        call kwr
        mov 1, %o0
1:      call kget                       /* drop anything already there */
        mov 100, %o0
        tst %o0
        bge 1b
        nop
        set s_ask, %o0
        call puts
        nop
        call kcollect                   /* the keys typed */
        nop
        set s_rst, %o0
        call puts
        nop
        call kcollect                   /* the keys held */
        nop
        set KBD_CTRL, %o2               /* the reset command, when TX is empty */
3:      lduba [%o2] IO_ASI, %o1
        andcc %o1, 4, %g0
        be 3b
        nop
        set KBD_DATA, %o2
        mov 1, %o1
        stba %o1, [%o2] IO_ASI
        set POLLS_1S, %o0
        call kdump
        mov 16, %o1
END

        .section .rodata
s_ask:  .asciz "KBD?\n"
s_rst:  .asciz "RST?\n"
s_sp:   .asciz " "


        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
