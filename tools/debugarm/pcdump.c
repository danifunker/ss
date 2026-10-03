/* pcdump: a non-interactive use of the debug link, for scripts.

   Runs on the MiSTer (make pcdump). Switches the core's ttya UART to the
   debug link, and for each CPU present: stops it, prints PC, nPC, PSR,
   TBR, WIM and the 32 visible registers, and lets it run again (unless
   -s). Then it switches the UART back to the console.

     pcdump [-s] [-w] [-n count] [-d ms] [-c cpu] [-m va,words] [-p pa,words]
       -s        leave the CPUs stopped
       -w        also dump the locals and ins of all 8 windows (the PSR's
                 CWP is moved and put back)
       -n count  take count samples (default 1), -d ms apart (default 500)
       -c cpu    only this CPU
       -m va,n   also dump n words of virtual memory (supervisor data,
                 the CPU's current context) after the registers
       -p pa,n   the same for physical memory (36-bit pa, MMU bypass)
       -j pc     resume the CPU (give -c) at pc, npc = pc + 4, after the
                 first sample: steps over a loop the core cannot leave
       -A asi,a  also read the word at address a in ASI asi (both hex), e.g.
                 -A 4,200 for the MMU context register; up to 8 of them
       -S asi,a,v  store the word v at a in ASI asi (give -c), e.g. -S 36,0,0
                 flash-clears a SuperSPARC I-cache after patching code
       -W va,v   write the word v at va (give -c), through its physical
                 address (an MMU probe in the CPU's context), so read-only
                 kernel text can be patched; the old word is printed

   Each CPU's line is followed by its debug status words: error mode
   (halterror) and the trap that caused it (hetrap tt), the interrupt
   level asserted (irl), the trap in progress, TBR.tt.

   Nothing else may read /dev/ttyS1 meanwhile (scripts/console.sh, agetty).
   Uses lib.c and serie.c unchanged.
*/

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include "lib.h"

/* main.c's globals and helpers that lib.c and serie.c expect */
int done;
int saved[4];
int stepbrk[4];
struct break_t dbrk[4], ibrk[4];

int uprintf(const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
    return n;
}

int dbg_running()
{
    return !(dbg_read_status() & 1);
}

static void link_mode(int debug)
{
    char code = debug ? '3' : '4';      /* '3' = debug link, '4' = console */
    int i;
    for (i = 0; i < 8; i++) {
        sp_break();
        sp_puc(code);
        sp_drain();
    }
}

static const char *rname[32] = {
    "g0", "g1", "g2", "g3", "g4", "g5", "g6", "g7",
    "o0", "o1", "o2", "o3", "o4", "o5", "sp", "o7",
    "l0", "l1", "l2", "l3", "l4", "l5", "l6", "l7",
    "i0", "i1", "i2", "i3", "i4", "i5", "fp", "i7"
};

/* Write v at va through its physical address: the MMU probe (ASI 3,
   type entire) gives the PTE; the page size is not known from it, so the
   4 KB, 256 KB and 16 MB readings are tried until the word read through
   the physical address equals the one read at va. */
static void poke_word(uint32_t va, uint32_t v)
{
    static const uint32_t off[3] = { 0xfff, 0x3ffff, 0xffffff };
    uint32_t pte = dbg_read_asimem32(3, (va & ~0xfffu) | 0x400);
    uint32_t old = dbg_read_vmem32(va);
    unsigned long long base, pa;
    int i;
    if ((pte & 3) != 2) {
        printf("va %08x: no PTE (probe %08x)\n", va, pte);
        return;
    }
    base = (unsigned long long)(pte >> 8) << 12;
    for (i = 0; i < 3; i++) {
        pa = (base & ~(unsigned long long)off[i]) | (va & off[i]);
        if (dbg_read_pmem32(pa) == old) {
            dbg_write_pmem32(pa, v);
            printf("va %08x pa %09llx: %08x -> %08x (reads %08x)\n", va, pa,
                   old, v, dbg_read_pmem32(pa));
            return;
        }
    }
    printf("va %08x: PTE %08x, no page size gives the word %08x\n", va, pte,
           old);
}

int main(int argc, char *argv[])
{
    int keep = 0, count = 1, delay = 500, only = -1, c, s, n, mask;
    int windows = 0;
    unsigned long long maddr = 0;
    int mwords = 0, mphys = 0, jump = 0, poke = 0;
    uint32_t jpc = 0, wva = 0, wval = 0, aaddr[8];
    int nasi = 0, aasi[8], store = 0, sasi = 0;
    uint32_t saddr = 0, sval = 0;
    char *comma;

    while ((c = getopt(argc, argv, "swn:d:c:m:p:j:W:A:S:")) != -1) {
        switch (c) {
        case 's': keep = 1; break;
        case 'w': windows = 1; break;
        case 'n': count = atoi(optarg); break;
        case 'd': delay = atoi(optarg); break;
        case 'c': only = atoi(optarg); break;
        case 'm':
        case 'p':
            maddr = strtoull(optarg, &comma, 16);
            mwords = *comma == ',' ? atoi(comma + 1) : 16;
            mphys = c == 'p';
            break;
        case 'S':
            store = 1;
            sasi = strtoul(optarg, &comma, 16);
            if (*comma == ',')
                saddr = strtoul(comma + 1, &comma, 16);
            if (*comma == ',')
                sval = strtoul(comma + 1, NULL, 16);
            break;
        case 'A':
            if (nasi < 8) {
                aasi[nasi] = strtoul(optarg, &comma, 16);
                aaddr[nasi++] = *comma == ',' ? strtoul(comma + 1, NULL, 16) : 0;
            }
            break;
        case 'j': jump = 1; jpc = strtoul(optarg, NULL, 16); break;
        case 'W':
            poke = 1;
            wva = strtoul(optarg, &comma, 16);
            wval = *comma == ',' ? strtoul(comma + 1, NULL, 16) : 0;
            break;
        default:
            fprintf(stderr, "usage: %s [-s] [-w] [-n count] [-d ms] [-c cpu] "
                    "[-m va,words] [-p pa,words] [-A asi,a] [-S asi,a,v] [-j pc] [-W va,v]\n",
                    argv[0]);
            return 2;
        }
    }
    if ((jump || poke || store) && only < 0) {
        fprintf(stderr, "-j, -S and -W need -c cpu\n");
        return 2;
    }
    if (sp_init())
        return 1;
    link_mode(1);
    sp_purge();
    dbg_resync();
    dbg_init();
    mask = dbg_cpus();
    printf("cpus 0x%x\n", mask);
    for (s = 0; s < count; s++) {
        if (s)
            usleep(delay * 1000);
        for (n = 0; n < 4; n++) {
            uint32_t r[32];
            int i;
            if (!(mask & (1 << n)) || (only >= 0 && n != only))
                continue;
            dbg_selcpu(n);
            dbg_stop();
            for (i = 0; i < 32; i++)
                r[i] = i ? dbg_read_reg(i) : 0;
            printf("cpu%d pc %08x npc %08x psr %08x tbr %08x wim %08x\n", n,
                   dbg_read_cop_pc(), dbg_read_cop_npc(), dbg_read_psr(),
                   dbg_read_tbr(), dbg_read_wim());
            {
                uint32_t st = dbg_read_status(), st2 = dbg_read_status2();
                printf("    status %08x %08x: halterror %d hetrap.tt %02x "
                       "irl %d trap %d tt %02x tbr.tt %02x\n", st, st2,
                       (st >> 2) & 1, (st2 >> 8) & 0xff, (st >> 16) & 15,
                       (st >> 23) & 1, st >> 24, st2 & 0xff);
            }
            for (i = 0; i < 32; i++)
                printf("%s %s=%08x%s", i % 8 ? "" : "   ", rname[i], r[i],
                       i % 8 == 7 ? "\n" : "");
            if (windows) {
                uint32_t psr = dbg_read_psr();
                int w;
                for (w = 0; w < 8; w++) {
                    dbg_write_psr((psr & ~0x1fu) | w);
                    printf("    w%d%s", w, w == (int)(psr & 0x1f) ? "*" : " ");
                    for (i = 16; i < 32; i++)
                        printf(" %08x%s", dbg_read_reg(i), i == 23 ? " |" : "");
                    printf("\n");
                }
                dbg_write_psr(psr);
            }
            for (i = 0; i < mwords; i++) {
                unsigned long long a = maddr + 4 * i;
                if (i % 4 == 0)
                    printf("    %s %09llx:", mphys ? "pa" : "va", a);
                printf(" %08x", mphys ? dbg_read_pmem32(a)
                                      : dbg_read_vmem32((uint32_t)a));
                if (i % 4 == 3 || i == mwords - 1)
                    printf("\n");
            }
            for (i = 0; i < nasi; i++)
                printf("    asi %02x [%08x] = %08x\n", aasi[i], aaddr[i],
                       dbg_read_asimem32(aasi[i], aaddr[i]));
            if (poke && s == 0)
                poke_word(wva, wval);
            if (store && s == 0) {
                dbg_write_asimem32(sasi, saddr, sval);
                printf("    asi %02x [%08x] <- %08x\n", sasi, saddr, sval);
            }
            if (jump && s == 0) {
                dbg_write_cop_pc(jpc);
                dbg_write_cop_npc(jpc + 4);
                printf("cpu%d resumes at %08x\n", n, jpc);
            }
            if (!keep)
                dbg_run();
        }
    }
    link_mode(0);
    sp_close();
    return 0;
}
