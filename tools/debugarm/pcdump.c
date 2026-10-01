/* pcdump: a non-interactive use of the debug link, for scripts.

   Runs on the MiSTer (make pcdump). Switches the core's ttya UART to the
   debug link, and for each CPU present: stops it, prints PC, nPC, PSR,
   TBR, WIM and the 32 visible registers, and lets it run again (unless
   -s). Then it switches the UART back to the console.

     pcdump [-s] [-n count] [-d ms] [-c cpu] [-m va,words] [-p pa,words]
       -s        leave the CPUs stopped
       -n count  take count samples (default 1), -d ms apart (default 500)
       -c cpu    only this CPU
       -m va,n   also dump n words of virtual memory (supervisor data,
                 the CPU's current context) after the registers
       -p pa,n   the same for physical memory (36-bit pa, MMU bypass)

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

int main(int argc, char *argv[])
{
    int keep = 0, count = 1, delay = 500, only = -1, c, s, n, mask;
    unsigned long long maddr = 0;
    int mwords = 0, mphys = 0;
    char *comma;

    while ((c = getopt(argc, argv, "sn:d:c:m:p:")) != -1) {
        switch (c) {
        case 's': keep = 1; break;
        case 'n': count = atoi(optarg); break;
        case 'd': delay = atoi(optarg); break;
        case 'c': only = atoi(optarg); break;
        case 'm':
        case 'p':
            maddr = strtoull(optarg, &comma, 16);
            mwords = *comma == ',' ? atoi(comma + 1) : 16;
            mphys = c == 'p';
            break;
        default:
            fprintf(stderr, "usage: %s [-s] [-n count] [-d ms] [-c cpu] "
                    "[-m va,words] [-p pa,words]\n", argv[0]);
            return 2;
        }
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
            for (i = 0; i < 32; i++)
                printf("%s %s=%08x%s", i % 8 ? "" : "   ", rname[i], r[i],
                       i % 8 == 7 ? "\n" : "");
            for (i = 0; i < mwords; i++) {
                unsigned long long a = maddr + 4 * i;
                if (i % 4 == 0)
                    printf("    %s %09llx:", mphys ? "pa" : "va", a);
                printf(" %08x", mphys ? dbg_read_pmem32(a)
                                      : dbg_read_vmem32((uint32_t)a));
                if (i % 4 == 3 || i == mwords - 1)
                    printf("\n");
            }
            if (!keep)
                dbg_run();
        }
    }
    link_mode(0);
    sp_close();
    return 0;
}
