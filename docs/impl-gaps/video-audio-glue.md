# Implementation gaps: video, audio and the MiSTer integration

Phase 4 of [`REWORK.md`](../REWORK.md), one of three parallel audits
(the others: [`cpu.md`](cpu.md), [`chipset.md`](chipset.md)). The question
is not which devices are missing (that is phase 2,
[`HARDWARE_GAPS.md`](../HARDWARE_GAPS.md)) but what the core implements
**incompletely or incorrectly**.

- Written 2026-09-28 against branch `danifunker` at `6913401` (the phase 3
  tree: `SunSparcStation.sv` and `rtl/mister/ddram_arb.sv` not yet
  synthesised).
- Target firmware: the **real Sun OBP** (SS5 OBP 2.15, SS20 OBP 2.25), per
  the 2026-09-28 decision in REWORK.md. Anything that stops the real PROM
  from reaching `ok` with a working console counts as S1. OpenBIOS stays
  the reference for what works today.
- Severity: **S1** breaks an OS, the real OBP or an advertised feature;
  **S2** wrong but tolerated, or a performance or robustness loss;
  **S3** cosmetic or latent. Effort: XS < 1 h, S < 1 day, M a few days,
  L a week or more.
- "Verified" means the driver or reference code and the RTL were both
  read. "Inferred" means reasoned from code without a run. Nothing here was
  simulated in VHDL (no GHDL/nvc on this box). The one simulation is an
  iverilog bench of `ddram_arb.sv` (§0.1).

References used: QEMU 11.1.50 source (`hw/display/tcx.c`, `cg3.c`,
`hw/audio/cs4231.c`, `hw/sparc/sun4m.c`); Linux from `Linux-Kernel_MiSTer`
(`drivers/video/fbdev/tcx.c`, `cg3.c`, `sound/sparc/cs4231.c`); NetBSD
trunk (`sys/dev/sbus/tcx.c`, `tcxreg.h`, `sys/dev/sun/cgthree.c`,
`btreg.h`, `sys/dev/sbus/cs4231_sbus.c`, `sys/dev/ic/ad1848.c`);
xf86-video-suntcx (freedesktop master); illumos `audiocs`, current and the
pre-2009 sada version; Grabulosaure's OpenBIOS fork `ss_openbios` at
`6f3c0b7` (`drivers/tcx.fs`, `cgthree.fs`, `sbus.c`); Template_MiSTer
`sys/` as vendored here; Main_MiSTer `915ca33`; the PROM analyses under
[`docs/rom-disassembly/`](../rom-disassembly/).

## Contents

- [0. Phase 3 review: the new top and `ddram_arb.sv`](#0-phase-3-review-the-new-top-and-ddram_arbsv)
- [1. Blocks the real OBP](#1-blocks-the-real-obp)
- [2. Summary table](#2-summary-table)
- [3. Video](#3-video)
- [4. Audio](#4-audio)
- [5. MiSTer glue](#5-mister-glue)
- [6. Keyboard, mouse, serial, debug port](#6-keyboard-mouse-serial-debug-port)
- [7. Open questions](#7-open-questions)

---

## 0. Phase 3 review: the new top and `ddram_arb.sv`

**No functional bug was found in either file.** `ddram_arb.sv` delivers the
right data to the right master with the plomb bridges as they really behave,
but it does so for a reason other than the one its header gives, and that
reason costs memory throughput. The top carries over several upstream
mistakes; none of them was introduced by phase 3.

### 0.1 `ddram_arb.sv`

**The header's premise is wrong.** `ddram_arb.sv:6-8` says each master is a
`plomb_avalon64` "with at most one burst in flight". It is not. The bridge
issues a read, and once the Avalon side accepts it, it acknowledges the plomb
beats and returns to `sIDLE`. From there it presents the next command while
the read data is still outstanding (`plomb_avalon_mister.vhd:174-197`,
`226-237`). Its command FIFO holds up to 15 plomb beats before `full`
throttles it (`:295-299`).

**What keeps it correct** is that the arbiter holds `waitrequest` high for a
master in `IDLE` and `RDATA` (`ddram_arb.sv:75-76`). The bridge therefore
waits with its next command until the previous read has returned all its
beats. Read data is never misrouted. The bridge also holds `read`/`write`
until `waitrequest` drops:

- in `sIDLE`, `avl_read` depends only on `pw.req` and `full`;
- `full` can only fall while the bridge waits, because pops continue and no
  pushes happen;
- in `sWRITE`, the bridge drops `avl_write` between beats when the plomb
  master pauses, which Avalon allows and `WDATA` handles.

`burstcount` is registered and held for the whole burst (`avl_burstcount_i`).

**The existing bench does not exercise this.** Its masters wait for all read
data before issuing the next command (`rtl/mister/tb/tb_ddram_arb.sv:108-124`),
so the case the bridges actually produce was never run.

**A pipelined-master bench passes.** It lives in the scratchpad and is not
committed; worth adding to `rtl/mister/tb/`:

- a master presents its next command as soon as the previous one is accepted;
- 1 read in 8 is withdrawn before acceptance;
- the slave accepts overlapping reads and flags them;
- result: 3425 reads, 3541 writes and 1034 withdrawals with 0 errors, and
  the slave never saw a read issued while another was outstanding.

| # | Finding | Sev | Fix |
|---|---|---|---|
| G1 | **Every DDR transaction is serialised.** Each read costs the full DDR latency plus about 2 grant cycles. The CPU and the video scan-out now share one port, where before phase 3 they had two. Estimates are in §5.3 and depend on the DDR latency L. SS5: video takes about 38% of the port during active lines at L = 10 cycles, 62% at L = 20. SS20 (50 MHz system clock, 65 MHz pixels): 50% and 80%; beyond about L = 26 cycles the scan-out cannot keep up and **underruns**. CPU cache misses queue behind video bursts, and a write posted after a read now waits for the read's data. | S2 (S1 on the SS20 if L is large) | Pipeline the arbiter: a small FIFO of `{master, burstcount}` per accepted read, so new commands can be granted while reads are outstanding. The single Avalon port returns data in order. M. Better still, fix the scaler framebuffer mode (V1) and switch the core's own scan-out off in that mode, which removes video from this port entirely. |
| G2 | **The RAM clear at every reset takes about twice as long.** The loader writes single 64-bit beats (`ss_core.vhd:924-952`). Through the arbiter each one needs an IDLE and a CMD cycle, so 2 cycles per word. Clearing 512 MiB therefore takes at least 2.2 s at 65 MHz and 2.9 s at 50 MHz, up from 1.2 s and 1.5 s, plus any DDR busy time. This happens on every OSD reset and every OS reboot. | S2 | Clear with bursts: `ddram2b_burstcount` = 8 (already present, commented out at `ss_core.vhd:926`) or more, holding `write` for each beat. S. |
| G3 | **Reset domains differ.** The arbiter resets on `RESET` only (`SunSparcStation.sv:256`), while the bridges reset through the loader's `reset_n`. If `RESET` arrives in the middle of a burst (it only does at core load), the arbiter returns to IDLE while the DDR controller still expects the remaining write beats or read data. The next grant then inherits them. | S3 | Reset only in IDLE, or drain first. XS. |
| G4 | **Timing risk.** `DDRAM_RD/WE/ADDR` and every `waitrequest` now pass through the arbiter's muxes combinationally, so the CPU's plomb request reaches the HPS port through about 2 more LUT levels. The SS5 revision already needs placement and router effort ×4 and seed 3 (`SunSparcStation5.qsf:51,84-85`). | S2 (unverified until the fit) | If fmax suffers, register the slave side with a skid buffer. That adds 1 cycle of latency. |
| G5 | **The comment and the bench do not match the real masters** (above). | S3 | Fix the header and add the pipelined bench. XS. |

### 0.2 `SunSparcStation.sv`

| # | Finding | Sev | Fix |
|---|---|---|---|
| T1 | **"Scaler framebuffer" displays the wrong memory.** `FB_BASE = 0x3E40_0000` (`:54`) is core RAM at pa `0x01B0_0000`; the TCX VRAM is at DDR `0x22B0_0000`. The palette is also wrong (see V1). Upstream carried the same value since `cd06adc`. | S1 (feature) | V1. |
| T2 | **Aspect ratio is a 1-bit field with 4 choices.** `"O6,Aspect ratio,4:3,16:9,[ARC1],[ARC2]"` (`:83`), but `ar = status[7:6]` (`:186`), and no OSD entry owns bit 7. ARC1/ARC2 can never be selected. "16:9" actually yields `VIDEO_ARX = VIDEO_ARY = 0`, which is the template's "Full Screen". Upstream carried the same. | S3 | `"O[7:6],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];"`. XS. |
| T3 | **CONF_STR declares no `UART`** (`:76`). Main offers no serial modes (PPP, console, modem) and the core gets no `uart_speed`. See §6. | S2 | §6. |
| T4 | **`VGA_SCALER = 1`** (`:39`) forces analog VGA through the scaler and overrides the user's `vga_scaler` in `MiSTer.ini` (`sys/sys_top.v:309`). The native 1024×768@60 signal is a VESA DMT mode that any VGA monitor accepts. | S3 | Set it to 0 and let `MiSTer.ini` decide. XS. |
| T5 | **Hygiene.** Two OSD entries are both labelled "Video" (`:86-87`). The status-bit ruler at `:67-71` is stale. `status_in` is connected but `status_set` is not (`:151`). `sd_buff_addr` is declared `[7:0]` against hps_io's `[12:0]`; this is harmless with 512-byte blocks and `WIDE=1`, but Verilator warns. | S3 | XS. |
| T6 | **hps_io parameters are consistent.** `VDNUM=3` and `WIDE=1`. `BLKSZ` defaults to 2 (512 B), which matches the SCSI targets. `sd_blk_cnt = 0` means single-sector requests, so every 512 B costs a round trip through Main; the fix belongs to the SCSI redesign ([`design/scsi-hps.md`](../design/scsi-hps.md)). `PS2DIV = 1000` gives a 32.5 kHz PS/2 clock at 65 MHz and 25 kHz at 50 MHz: faster than the 10-16.7 kHz of a real PS/2 device, but only the core's own receiver sees it. `PS2WE = 0` means the core cannot send commands to the emulated PS/2 devices (§6). | — | — |

Checked and correct: the `emu_ports.vh` port list; `FB_FORMAT` narrowed from
6 to 5 bits; `DDRAM_CLK = clk_sys`, which is the clock both bridges and the
loader run on; the SCSI and CD-ROM status widths (the phase 3 fix);
`AUDIO_S = 1`, since the codec output is two's complement; the LED mapping
(`LED_USER` shows download or clear in progress, `LED_POWER` shows CPU
reset, `LED_DISK` shows SCSI busy).

---

## 1. Blocks the real OBP

This section covers what, in this audit's area, stops OBP 2.15 (SS5) and OBP
2.25 (SS20) from reaching `ok` with a working console. Items are listed in
the order the PROM meets them. CPU, MMU and chipset blockers (POST, ASI 4
aliasing, missing bus time-outs, the IDPROM, SIMM bank registers, MID/MSI)
are in `cpu.md` and `chipset.md` and appear here only where this area
touches them.

| Order | What the PROM does | Core today | Blocks? | Fix |
|---|---|---|---|---|
| 1 | **Main loads the image.** The user's PROM goes into `games/SunSparcStation/boot.rom`, or is loaded with OSD "BIOS". SS5 `ss5.bin` is 256 KiB, SS20 is 512 KiB. | The loader writes the file to OBRAM at pa `0x1D00_0000` (DDR `0x22F0_0000`). The address window is `ioctl_addr[19:0]`, 1 MiB (`ss_core.vhd:975-1008`); the remap window is 2 MiB (`ts_core.vhd:1285,1293`). Byte order is right: file byte *n* is pa byte *n*, big-endian. The machine only leaves reset once the image is at least 128 KiB (`ss_core.vhd:937`); both PROMs pass. The RAM clear skips the image (`:959-961`). | no | Document the 128 KiB minimum. Optionally write-protect OBRAM, since a real PROM cannot be written. |
| 2 | **Reset fetch and self-mapping.** SS5: the boot fetch forces pa `0x7000_0000` (MS2 UM Table 40), and the PROM maps itself there. SS20: pa `0xF_F000_0000`. | SS20 matches (`ts_core.vhd:1284-1286`). The SS5 decodes the PROM only at `0xF…`/`0xB…` (`ts_decode.vhd:79-81`, remap `ts_core.vhd:1292`). Nothing answers at `0x7000_0000`. | **SS5: yes (S1)** | Also remap `a[31:24] = 0x70` to OBRAM in `sel_decodage_nosmp` and `VideoShmuck`, keeping `0xF…` for OpenBIOS. S. Details in chipset/cpu. |
| 3 | **SS20 memory sizing.** `cold_master_size_memory` probes the SIMM slots from the top, starting at `0x1C00_0000`. It writes test patterns at the slot base, at +32 MB and at +16 MB, and sizes the slot by aliasing ([ss20 README §3.5](../rom-disassembly/ss20-obp-2.25/README.md)). It then puts its own tables at the top of RAM. | On the SS20 build, pa `0x1C00_0000-0x1FFF_FFFF` is plain DDR with no aliasing. `plomb_avalon64`'s "zone" check returns 0 only above `HIMEM` (`plomb_avalon_mister.vhd:126-133`), and writes are never blocked. pa `0x1D00_0000` is **OBRAM, the running PROM image**. `0x1D40_0000` is TCX VRAM. `0x1D80_0000-0x1DFF_FFFF` is the Linux fb, and `0x1E00_0000-0x1FFF_FFFF` holds the scaler buffers (§5.2). The PROM overwrites its own first words, finds 64 MB in slot 7, and allocates its MMU tables where the scaler writes every frame. | **SS20: yes (S1)** | Make slot 7 look like a 16 MB DSIMM: fold pa `0x1D00_0000-0x1FFF_FFFF` onto `0x1C00_0000-0x1CFF_FFFF` for CPU accesses (remaps excepted). 7×64 + 16 = 464 MB is exactly `RAMSIZE` (`ss_core.vhd:156`). The EMC registers the PROM also reads are for chipset.md. S. |
| 4 | **Keyboard detection** during POST and console setup. `init-keyboard` sends a command and waits up to 1 s for the reply; with no reply it prints "No Keyboard" (`qemu-console.txt:7` shows "No Keyboard Detected"). | Depends on `ts_ps2sun`'s reset and layout replies; not audited yet (§6). No Stop key, so no Stop-A (K1). | likely no for detection, unverified; **yes (S1) for Stop-A** | §6 |
| 5 | **ttya console.** OBP programs the ESCC for 9600 8N1. | See §6: the line rate the core actually runs on the MiSTer UART. | see §6 | §6 |
| 6 | **SBus probe of the empty slots** (SS5 `sbus-probe-list` "541230", `forth-dictionary.txt:10524`). `probe` maps 64 KiB, `cprobe`s the first byte, and needs `0xF0-0xF3` or `0xFD` (`:12898-12909`). | Unmapped addresses return `0xBADACCE5` without a fault (HARDWARE_GAPS §2.1). Empty slots 0-2 read first byte `0xBA`, so the PROM prints "Invalid FCode start byte" instead of "Nothing there". | no (noise) | The fault is a chipset item. |
| 7 | **Slot 5 (macio) and slot 4 (`SUNW,CS4231`, `power-management`)** come from FCode built into the PROM (`fcode-70011838-SUNW_CS4231.txt`, `fcode-70011f00-espdma.txt`). QEMU boots them without card PROMs (`qemu-console.txt:43-44`). | The codec registers are there (§4). Only the `test` command's loopback check would fail, because capture is missing (A4). | no | — |
| 8 | **Slot 3 (SS5) or slot 2 (SS20): the display.** The PROM reads the card's FCode at slot offset 0. | `ts_tcx` returns `0x00000000` for every unimplemented offset, offset 0 included (`ts_tcx.vhd:294`, `443-444`). The PROM finds no display node, so no `screen`. | **yes (S1) for a screen console** | V4: an FCode PROM at slot offset `0x0-0xFFFF`. |
| 9 | **`install-console`** (`forth-dictionary.txt:13605`). Output goes to `screen` if a display node exists, input to `keyboard` if one was detected; otherwise both fall back to ttya. | With items 4 and 8 unresolved, the console is ttya only. | partial | V4 and §6 |

---

## 2. Summary table

| ID | Area | Finding | Sev | Effort |
|---|---|---|---|---|
| V4 | video | No FCode PROM on the TCX/CG3 "card", so the real OBP finds no display | **S1** (real OBP) | S |
| — | glue | SS5 PROM not decoded at pa `0x7000_0000` (§1, row 2; details in chipset) | **S1** (real OBP) | S |
| G6 | glue | SS20: the reserved top 48 MB is CPU-writable RAM; the real OBP's memory probe overwrites OBRAM and its tables land on the scaler buffers | **S1** (real OBP, SS20) | S |
| V1 | video | "Scaler framebuffer": wrong `FB_BASE`, and the wrong palette | **S1** (feature) | S |
| V2 | video | CG3 DAC address register reads the index from D[31:24] only; Linux and NetBSD write it in D[7:0] | **S1** (Linux on CG3), S2 (NetBSD) | XS |
| A1 | audio | CS4231 I12 ID nibble missing, so the Linux driver's probe fails | **S1** (Linux) | XS |
| A2 | audio | Codec STATUS.INT and I24 PI/CI/TI never set, so the Linux IRQ handler returns `IRQ_NONE` | **S1** (Linux) | M |
| K1 | kbd | No PS/2 key gives Sun Stop, so Stop-A cannot be typed | **S1** (real OBP) | S |
| K3, K4 | serial | No `UART` in CONF_STR; wire fixed at 115200 while OBP ttya defaults to 9600 (to confirm) | S2 | XS-S |
| G1 | glue | DDR arbiter serialises every transaction; the CPU and video share one port | S2 (S1 on the SS20 if latency is high) | M |
| G2 | glue | RAM clear on every reset takes 2.2-2.9 s (twice as long as before) | S2 | S |
| V3 | video | CG3 control (interrupt enable) and TCX THC_MISC survive resets, so the next OS gets stray level-9 interrupts | S2 | XS |
| A3 | audio | 8-bit stereo (U8/µ-law/A-law) plays as mono at half speed | S2 | S |
| A4 | audio | Capture absent (and the OBP `test` loopback check fails) | S2 | M |
| G4 | glue | Extra combinational depth on the DDR paths (timing, unverified) | S2 | S |
| G7 | glue | Download: the DDR write is not latched and `ioctl_wait` is a 1-cycle pulse | S2 (latent) | S |
| T3 | glue | No `UART` in CONF_STR | S2 | XS |
| V5 | video | Fixed 1024×768@60; timing registers ignored; CG3 sense reports 1152×900; no 1152×900 mode | S3 | M for 1152×900 |
| V6 | video | No blanking (THC_MISC VIDEN, CG3 video enable ignored), no DAC control or cursor-colour registers; the THC cursor is absent but no 8-bit OS uses it | S3 | S |
| V7 | video | TCX DHC (`0x240000`) and ALT (`0x280000`) alias the DAC | S3 | XS |
| V8 | video | SS20: any SBus slot 0-7 address with a[23] = 1 is remapped to VRAM | S3 | XS |
| A5-A15 | audio | double-executed register accesses, FIFO reset race, CSR bit 7, mode-change timing, RO bits, timer, ADPCM, output controls, resets, DMA details, latent IRQ map (§4) | S3 | XS-M |
| G3, G5 | glue | Arbiter reset domain; comment and bench | S3 | XS |
| T2, T4, T5 | glue | Aspect ratio field; `VGA_SCALER` forced; OSD labels and hygiene | S3 | XS |
| G8 | glue | RTC seeded with local time; Sun OSes keep the TOD in UTC | S3 | XS |

---

## 3. Video

### 3.1 What the core implements

`ts_tcx.vhd` is one block that serves as either a TCX or a CG3, selected at
run time by OSD `OA` (`swconf(2)`, `ts_io.vhd:689`). It sits at SBus slot 3
(`0x5000_0000`, the whole 256 MB, `ts_decode.vhd:56-57`) on the SS5 and at
slot 2 (`0xE_2000_0000`, `ts_decode.vhd:120-121`) on the SS20.

| Offset | TCX (QEMU / OpenBIOS `tcx.fs` map) | Core |
|---|---|---|
| `0x000000` | FCode PROM, 64 KiB | not implemented; reads 0 |
| `0x200000` | DAC (Bt458-style): +0 address, +4 colour, +8 control, +0xC overlay colours | +0 and +4 only, one byte from D[31:24] per write, 3-cycle R/G/B auto-increment (`ts_tcx.vhd:303-364`) |
| `0x240000`, `0x280000` | DHC, ALT (QEMU: dummy) | alias the DAC (V7) |
| `0x300000` | THC: +0x818 MISC, +0x800-0x814 timing, +0x8FC/0x900/0x980 cursor | MISC read/write, and reads OR in bit 25 exactly as QEMU does (`ts_tcx.vhd:315-321`; `tcx.c:675-687`); nothing else |
| `0x700000` | TEC (QEMU: dummy) | reads 0 |
| `0x800000` | 8-bit dumb framebuffer | remapped to VRAM at pa `0x1D40_0000`, a 2 MiB window (`ts_core.vhd:1296-1297`) |
| `0x2000000`, `0xA000000` | 24-bit plane, control plane (absent on 8-bit TCX) | reads 0 |
| `0x4000000`, `0xC000000` | stipple and raw stipple | `TCX_ACCEL`: 32-pixel stipple fill (`ts_tcx.vhd:385-401`) |
| `0x6000000`, `0xE000000` | blit and raw blit | `TCX_ACCEL`: copy or fill of up to 32 pixels (`ts_tcx.vhd:408-424`, engine `463-758`) |

**The accelerator follows QEMU and NetBSD.**

- The high word of each 64-bit command carries the colour in D[7:0].
- The low word is either the stipple mask or `(len-1) << 24 | src`, and
  `src = 0xFFFFFF` means fill (`tcx.c:466-495`, `565-595`; NetBSD
  `tcx.c:1000-1100`).
- The pixel address comes from A[22:3].
- A blit reads all 32 bytes before it writes, which gives memmove semantics.
- The CPU is held off (`trans`) until the engine is idle.

NetBSD uses STIP/BLIT (`sc_rstip`/`sc_rblit`) for its console on 8-bit TCX.
Solaris uses them in its X server, which is why QEMU implements them.

CG3 (`0x400000`) has the DAC at +0/+4 (all four byte lanes, so packed
R0G0B0R1 writes work) and the FBC control and status word at +0x10
(`ts_tcx.vhd:368-378`). Its vertical-retrace interrupt is gated by control
bit 7. The framebuffer at `0x800000` shares the TCX VRAM.

Scan-out (`rtl/peri/vid.vhd`) is fixed at `MODELINE_1024_768_60Hz_65MHz`,
8 bpp (`ts_tcx.vhd:99,161`). The 65 MHz clock comes from `pll` outclk_0
(`ss_core.vhd:881-888`). The pipeline:

- 32-byte plomb bursts through its own DDR bridge;
- a 128-word FIFO;
- at most about 1-2 bursts in flight (`plomb_aec` throttle, `vid.vhd:242-255`);
- a clock-domain crossing by toggle synchronisers (`vid.vhd:311-332`).

The palette lives in `ts_tcx` (`:262-281`). The OS never programs a
resolution, and every OS takes it from the PROM properties. OpenBIOS
publishes 1024×768, `linebytes` 0x400 and `tcx-8-bit` (`tcx.fs`,
`qemu-tcx-driver-init`). Linux (`tcx.c:382`), NetBSD (`tcx.c:242`) and
xf86-video-suntcx (`tcx_driver.c:334`) all honour `tcx-8-bit`.

### 3.2 Findings

**V1 (S1, feature). "Scaler framebuffer" shows core RAM with a random palette.**

- **Expected:** `FB_BASE` is the DDR byte address of the VRAM. With 8 bpp, the
  palette comes from the core (`MISTER_FB_PALETTE`), or ascal loads palette 1
  from DDR at `LFB_BASE - 4 KiB` (`sys/sys_top.v:1025-1035`).
- **Core, the address:**
  - `SunSparcStation.sv:54` sets `FB_BASE = 0x3E40_0000`.
  - The transform `"001" & NOT a[25:17] & a[16:0]` (`ss_core.vhd:698-699`) is
    applied to the pa: DDR = `0x2000_0000 + ((~pa[28:20]) & 0x1FF) << 20 + pa[19:0]`.
  - That puts VRAM pa `0x1D40_0000` at DDR `0x22B0_0000`, while `0x3E40_0000`
    is core RAM pa `0x01B0_0000`. This confirms HARDWARE_GAPS #8 by
    arithmetic (table in §5.2).
- **Core, the palette:**
  - `MISTER_FB_PALETTE` is off (`SunSparcStation5.qsf:81`).
  - ascal therefore takes palette 1 from DDR at `LFB_BASE - 4 KiB`.
  - `LFB_BASE` is Main's Linux-fb base. It is 0 unless Main's framebuffer is
    active, so the colours come from an address the core never writes.
- **Who is affected:** anyone who picks OSD "Video: Scaler framebuffer".
- **Fix, S:**
  - `FB_BASE = 32'h22B0_0000`, with a comment deriving it from `TCX_ADRS`.
    The 1024×768 image (768 KiB) fits inside one 1 MiB block, so it is
    contiguous in DDR.
  - Enable `MISTER_FB_PALETTE`. The `FB_PAL_*` ports are already wired under
    the macro (`SunSparcStation.sv:230-238`).
  - The palette port mirrors every DAC write with the right index:
    `pal_a = palidx3` and `pal_d = palrgb_wr` in the same cycle as the
    internal write (`ts_tcx.vhd:273-287`).
  - Byte order is right for ascal. DDR byte *n* is pixel *n*, because the
    bridge byte-reverses 64-bit words (`ss_core.vhd:748-752`).
  - **Also stop the core's own scan-out DMA and `VGA_DE` while `FB_EN` is
    set, but keep HS/VS running** so that Main and `video_calc` still see a
    mode. `vga_run = vga_ctrl(0) OR vga_on` also gates the syncs, and
    `vga_on` is tied to 1 at `SunSparcStation.sv:197`, so this needs a
    dedicated input into `vid.vhd`.
  - ascal keeps capturing whatever the core sends, even in FB mode (its
    input-write path is not gated by `o_fb_ena`, `sys/ascal.vhd:1705-1757`).
    With the DMA and DE stopped, ascal reads VRAM on its own 128-bit port,
    the video load leaves the core's single DDR port (G1), and about
    140 MB/s of scaler input writes go away too. With G1 in mind, this mode
    should become the default.
- **Test:** toggle the OSD at the OpenBIOS banner. Run a colormap-cycling X
  client. Watch the CPU memory-bandwidth loop of `tests/cpu` with the mode
  on and off.

**V2 (S1 for Linux on CG3, S2 for NetBSD). The CG3 DAC address write uses the wrong byte.**

- **Expected:** the CG3 takes all four bytes of a 32-bit DAC write in
  sequence, and the last byte wins for the address register (NetBSD
  `btreg.h:43-67`, "the cg3 takes all the bits from all bytes written to
  it"). Drivers write the index as a word with the value in D[7:0]:
  - Linux: `sbus_writel(D4M4(regno), &bt->addr)` (`cg3.c:168`);
  - NetBSD: `bt->bt_addr = BT_D4M4(start)` (`cgthree.c:356`);
  - QEMU keeps the whole value (`cg3.c` `CG3_REG_BT458_ADDR`).
- **Core:** the index is `w.dw(31:24)` when `be(0)` is set
  (`ts_tcx.vhd:306-307`). That is right for OpenBIOS's and QEMU FCode's byte
  stores (`cgthree.fs` `dac!` = `c!`), but a word write of `0x0000_00NN` sets
  index 0.
- **Effect on Linux:** `cg3_setcolreg` is called per register by fbcon. Every
  call rewrites entries 0-3 with the group of `regno`, so after a 16-colour
  load, entries 0-3 hold colours 12-15 and entries 4-15 are never set. The
  console colours are wrong and text can be invisible.
- **Effect on NetBSD:** colormap updates that start at an index other than 0
  (X colour allocation) land at index 0.
- The TCX is unaffected: its drivers shift the index into D[31:24]
  (Linux `tcx.c:187`).
- **Fix, XS:** for CG3, take the index from the lowest-order enabled byte lane
  (D[7:0] when `be(3)`; for a byte store, the lane that was written).
- **Test:** the Linux fbcon colour test (`setterm` colours) on CG3; NetBSD X
  on cgthree with `xcolor`.

**V3 (S2). CG3 and TCX control registers survive a reset.**

- **Core:** the `Regs` reset branch clears only `palidx`, `palw` and
  `palcyc` (`ts_tcx.vhd:431-435`). `cg3_ctrl`, `tcx_misc` and `cg3_int` keep
  their values. The CG3 interrupt is `cg3_int AND cg3 AND cg3_ctrl(7)`
  (`:427-428`).
- **Effect:** an OS that enabled CG3 vertical-retrace interrupts leaves
  `ctrl(7) = 1` after `reboot` or an OSD reset. The next firmware or OS then
  receives a level-9 interrupt at every vsync (SBus 5, shared with the codec,
  `ts_inter.vhd:144`) before any driver has claimed it.
- **Who is affected:** whichever OS follows one that uses the interrupt.
  QEMU implements the interrupt, so some OS does; Solaris's `cgthree` is the
  likely one (unverified). This is a candidate for README's "reboot MiSTer
  between OSes".
- **Fix, XS:** reset `cg3_ctrl`, `cg3_int` and `tcx_misc`.
- **Test:** enable the interrupt, reset with OSD R0, and watch the level-9
  pending bit in `ts_inter` at the `ok` prompt.

**V4 (S1 for the real OBP). No FCode on the display "card".**

- **Expected:** OBP `probe` maps `/fcode-prom` (64 KiB) at slot offset 0,
  requires a first byte of `0xF0-0xF3` or `0xFD`, then `1 byte-load`s the
  image (`ss5-obp/forth-dictionary.txt:12891-12909`). SS5 slot 3 and SS20
  slot 2 carry no display FCode in the PROM itself.
  - The SS20 image has FCode only for DBRI, slot f and cgfourteen
    ([ss20 README](../rom-disassembly/ss20-obp-2.25/README.md) rows
    `0x299a0`, `0x29ae0`, `0x2e680`).
  - The SS5 image has it for CS4231 and espdma only.
- **Core:** offset 0 reads `0x00000000`, so the PROM reports "Invalid FCode
  start byte" and creates no display node. OpenBIOS is not affected: it
  byte-loads its own copy (`sbus.c:142-186`).
- **Fix, S:** a ROM at slot offset `0x0000-0xFFFF` in `ts_tcx`. The
  candidates are OpenBIOS's `tcx.fs` and `cgthree.fs`, tokenised as QEMU
  ships them:
  - `QEMU,tcx.bin` is 1402 B and `QEMU,cgthree.bin` is 850 B; they are built
    by OpenBIOS `drivers/build.xml:37-38` and are GPL-2 (copyright Mark
    Cave-Ayland).
  - Both fall back to 1024×768, 8 bpp and `line-bytes` 0x400 when the words
    `openbios-video-width` etc. are absent (`tcx.fs` `(is-openbios)`), which
    matches the core's fixed mode.
  - They use only standard FCode (`fb8-install`, `default-font`,
    `is-install`, `encode-phys`).
  - The real SS5 OBP 2.15 already accepts `QEMU,tcx.bin`: QEMU's console shows
    "Probing … at 3,0 SUNW,tcx" (`ss5-obp/qemu-console.txt:47`).
  - Size: about 3 M10K for both images, selected by `cg3`. Alternatively,
    load the image from a file the way `boot.rom` is loaded, which keeps GPL
    binaries out of the bitstream until the license question (phase 0) is
    settled.
  - The TCX DAC writes of `tcx.fs` (`dac!` replicates the byte into all four
    lanes and uses `l!`) and the CG3 `c!` writes both work with the current
    DAC decode.
- **Test:** QEMU with the real PROM and the same FCode (already works), then
  the core. Expect `Probing … at 3,0 SUNW,tcx`, the banner on screen and
  `output-device` `screen`.

**V5 (S3). One mode, and the mode registers are ignored.**

- **Core:**
  - The THC timing registers (`0x300800-0x300814`) and CG3 registers
    `0x14-0x1F` (h/v blank, sync, xfer holdoff) are not decoded; writes are
    dropped.
  - The CG3 status reads `0x61` (sense 6 = 1152×900@76, colour;
    `ts_tcx.vhd:376`), copied from QEMU (`cg3.c` "monitor ID 6") while the
    core displays 1024×768.
- **Effect:** harmless while the PROM properties exist. Linux uses the
  status only without a `width` property (`cg3.c:317-327`). NetBSD writes
  its sense-6 timing table when `FBC_TIMING` is clear (`cgthree.c:178-192`),
  and the core ignores it.
- **1152×900:** the Sun default mode is not available. It needs about a
  94.5 MHz pixel clock (a new PLL output), and about 69 MB/s of scan-out
  bandwidth, which the shared port cannot afford without G1 or V1.
- **Fix:** make CG3 sense 5 (1024×768) to match the FCode's `monitor-sense`
  (`cgthree.fs:189-194`), XS. A second mode is an M feature, not a fix.

**V6 (S3). No blanking; missing DAC and cursor registers.**

- **Blanking:** THC_MISC VIDEN/HSYNC_DIS/VSYNC_DIS (NetBSD `tcx.c:583-608`,
  Linux `tcx.c:212-238`) and the CG3 control video-enable bit (Linux
  `cg3.c:196-208`) are stored but ignored, so screen blanking and DPMS do
  nothing.
- **DAC:** DAC control (+8) and overlay colours (+0xC) are ignored. That is
  harmless: Linux writes the Bt control registers at probe (`tcx.c:446-452`)
  and nothing reads them back.
- **Cursor:** the THC hardware cursor is absent. No OS uses it on an 8-bit
  TCX:
  - NetBSD: "hw cursor is not implemented on tcx" in 8-bit mode
    (`tcx.c:1339-1353`);
  - xf86-video-suntcx enables it only when the node has `hw-cursor`
    (`tcx_driver.c:333,415-428`), which neither OpenBIOS nor the QEMU FCode
    sets;
  - a 24-bit S24 model would need it.
- **Fix, S:** gate `vga_de` and the RGB with VIDEN, or with CG3 control
  bit 6.

**V7 (S3). DHC and ALT alias the DAC.** The DAC decode tests only
`a[27:20] = 0x02` (`ts_tcx.vhd:304,341`), so `0x240000` (DHC) and `0x280000`
(ALT) act as a second and third DAC. No known driver writes them; QEMU maps
them as dummies (`tcx.c:802-809`). Fix, XS: also require `a[19:16] = 0`.

**V8 (S3). SS20 VRAM aliasing across slots.**

- The SS20 memory-select and remap condition is `ah = E, a[31] = 0,
  a[23] = 1` (`ts_core.vhd:499`, `1287`). That catches every SBus slot 0-7,
  not just slot 2.
- A probe of `0xE_0080_0000` in empty slot 0 returns VRAM.
- Fix, XS: also require `a[30:28] = 2`.

**Checked and correct:**

- the 1024×768@60 DMT timing (`vid_pack.vhd:47-48`); the sync outputs are
  positive pulses, deliberately, for MiSTer (`ss_core.vhd:40-41`);
- DE/RGB alignment through the palette RAM;
- the stable-data CDC of `vfifo_data` into the pixel domain. At SS20 the
  read pointer settles within 2 system clocks (40 ns), and the next sample
  comes 4 pixel clocks (61.5 ns) later. `sys_top.sdc`'s exclusive clock
  groups cut these paths;
- the stipple and blit formats against QEMU and NetBSD.

QEMU raises no TCX interrupt at all (`tcx.c` never calls `qemu_irq_raise`),
and Solaris runs on it, so the missing THC interrupt is not a gap.

---

## 4. Audio

Condensed from a register-by-register audit of `rtl/sun4m/ts_cs4231a.vhd`
(added upstream in `c19b331`). References:

- Linux `sound/sparc/cs4231.c`;
- NetBSD `cs4231_sbus.c`, `cs4231.c` and `ad1848.c`;
- illumos `audiocs`, current and the pre-2009 sada version, which is the one
  sun4m Solaris used;
- QEMU `hw/audio/cs4231.c`, which is a register stub with no DMA, playback
  or IRQ, so it is only a reference for read-only values;
- the SS5 PROM's built-in `SUNW,CS4231` FCode.

The two S1 claims were re-checked in the RTL and in Linux.

**Decode and path (verified).**

- SS5: `0x6C00_0000-0x6FFF_FFFF` (`ts_decode.vhd:59-60`). The 64-byte block
  repeats across the window and also swallows the AFX register at
  `0x6E00_0000`. The OBP FCode puts the codec at `my-address + 0xC000000`,
  size `0x40`, interrupt 5, as does QEMU `cs_base` (`sun4m.c:1123`).
- IRQ: CSR.IP → sysint bit 11, SBus level 5 → PIL 9, shared with the CG3
  interrupt (`ts_inter.vhd:115,144`).
- DMA: plomb mux port 2, through the IOMMU.
- Output: the samples reach `AUDIO_L/R` two's complement (`AUDIO_S=1`,
  `AUDIO_MIX=0`). The sample clock is a `SYSFREQ/rate` integer divider, so
  44.1 kHz comes out at 44 127 Hz. `sys/audio_out.sv` resamples to 48 kHz by
  zero-order hold.
- **SS20: no audio.** `Gen20` never drives `sel.audio`
  (`ts_decode.vhd:108-162`), although the codec is instantiated and sits on
  the DMA mux. In simulation the undriven select is `'U'` and poisons
  `sel.vide` (`:164`); synthesis ties it to 0 (inferred).

| ID | Finding (expected / core / affected) | Sev | Fix |
|---|---|---|---|
| A1 | **I12 ID nibble.** After writing MODE2, Linux requires `I12 & 0x0F = 0x0A`, else `-ENODEV` (`cs4231.c:1033-1043`); QEMU keeps `0x8A`. The core stores I12 as a plain register (`ts_cs4231a.vhd:545-546`, `607-608`), so it reads `0x40`. **The Linux driver never attaches.** Solaris and NetBSD do not check. | **S1** | Read `(I12 AND 0x40) OR 0x8A`. XS |
| A2 | **Codec INT never set.** Linux's SBus IRQ handler returns `IRQ_NONE` unless STATUS.GLOBALIRQ is set (`cs4231.c:1614-1615`). The core writes `status` only at reset and on write-1-to-clear (`ts_cs4231a.vhd:385`, `635`), and I24 PI/CI/TI are plain storage. **Even with A1 fixed**, Linux never acks the APC; level 9 then storms, and the kernel disables the line shared with the CG3 interrupt (inferred). NetBSD acks STATUS only; Solaris never reads it. | **S1** | Add a sample down-counter reloaded from I15:I14 while PEN is set, setting I24.PI and R2.INT on underflow, with the datasheet clears. M (the quick hack R2.INT = APC IP is S). |
| A3 | **8-bit stereo** (U8, µ-law, A-law) takes 1 byte per tick with R = L (`ts_cs4231a.vhd:817-837`), so it plays mono at half speed. Solaris and Linux offer 8-bit stereo; NetBSD offers only 16-bit. | S2 | 2 bytes per frame. S |
| A4 | **No capture.** Capture registers `0x20-0x2C` read 0 and ignore writes (`:565-571`, `691-712`); CI is never raised; CD/CX are forced to 1 (`:902-903`); loopback is ignored. Recording blocks on every OS. The real OBP's `test-l1a7192` loopback check prints "DVMA failure internal loopback" (it is only run by `test`, not at boot). | S2 | A capture engine writing silence, or the loopback copy, at the sample rate. M |
| A5 | **Every register access executes twice.** The ack is registered (`:516-518`) while `plomb_pvc` holds `req`. A repeated CSR write-1-to-clear can drop a PI/PMI that arrived in between. | S3 | Combinational ack, as in `ts_timer`. S |
| A6 | **FIFO reset race.** A sample-tick `rd_ptr+1` overrides `rd_ptr <= 0` (`:333-342`), so up to 63 stale samples play after an abort. | S3 | XS |
| A7 | **CSR bit 7** is treated as abort and discards PC/PNC (`:731-737`). NetBSD and Linux mean "pause after current" (`cs4231_sbus.c:333-345`), so NetBSD `halt_output` clips the last block. The real APC's behaviour is unknown. | S3 | — |
| A8 | **Mode-change timing.** I8 is accepted without MCE; ACAL is ignored; ACI is a fixed 6.2 ms. All drivers tolerate it. | S3 | — |
| A9 | **Read-only bits.** Only I25 is write-protected; I11, the I12 low nibble and I24 take writes. R2.SER does not mirror PUR/COR. | S3 | XS |
| A10 | **Codec timer** (I16 TE, I20/I21, I24 TI) missing, so the ALSA timer never ticks. | S3 | S |
| A11 | **ADPCM** (I8 = 101) plays as linear 8-bit noise; Linux advertises it (`cs4231.c:1089`). | S3 | refuse the format, XS |
| A12 | **Output controls.** Only I6/I7 attenuation is applied; the I10 line/headphone mutes and I26 are ignored. The last sample holds after stop (a DC offset). | S3 | S |
| A13 | **Resets.** `reset_n` clears everything except `sample_rate_div` (`:154`); every driver rewrites it. CSR bit 5 (codec power-down/reset, pulsed by the OBP FCode and Solaris `apc_power`) is not modelled. Audio is **not** the cause of "reboot between OSes". | S3 | XS |
| A14 | **DMA details.** A 200k-cycle watchdog abandons accepted requests, so a late response would shift the data by one word (`:768-776`). 16-bit stereo ignores A[1:0]. EI never fires. | S3 | S |
| A15 | **Latent IRQ map.** `c19b331` moved sysint bit 17 "Audio" from level 13 to 9 (`ts_inter.vhd:115`); Linux maps it at 13 (`sun4m_irq.c:177`). It is dormant because the bit is tied to 0. | S3 | XS |

**Implemented correctly (verified):**

- IAR index, MCE, TRD and INIT readback, as the Solaris `sel_index` retry
  loop and the OBP `test-cs4231` need;
- I25 = `0xA0` (read-only), so NetBSD says "CS4231A" and Solaris sets
  `cs_revA`;
- I8 formats: linear8, µ-law, A-law, 16 LE and 16 BE;
- the full 16-entry rate table, indexed by C2SL/CFS;
- I6/I7 attenuation;
- PEN gating;
- the I11 PUR latch;
- the APC CSR: bit layout, ID `0x7E`, self-clearing RESET, write-1-to-clear,
  IP;
- PVA/PC/PNVA/PNC with next-buffer promotion, PI per buffer, PMI on drain,
  and PM after abort, as Solaris `apc_p_stop` and NetBSD `halt_output` wait
  for.

Solaris and NetBSD playback should therefore work today. Linux needs A1 and
A2.

**SS20 substitute: a CS4231 in an SBus slot.** The real SS20 has DBRI and
SpeakerBox, and no sun4m OS has a CS4231-on-SS20 path by machine type.
Linux (`cs4231.c:2058-2090`), NetBSD (`cs4231_sbus_match`, by name) and,
inferred, Solaris all bind by node name. So what is needed:

- **Decode, XS:** `sel.audio` in `Gen20`, e.g. slot 3 at `0xE_3C00_0000`
  (64 B). This also removes the `'U'`.
- **Node, S:** either an OpenBIOS `sbus_probe_slot_ss10` entry
  (`SUNW,CS4231`, reg `<slot 0x0C000000 0x40>`, intr `<5 0>`,
  device_type "serial"), or, for the real OBP 2.25, the SS5 PROM's 1732-byte
  `SUNW,CS4231` FCode served as that slot's FCode PROM. That FCode also
  creates `power-management` at `+0xA000000` (inferred).
- **Already in place:** the APC registers, the level-5 → PIL 9 path, and the
  IOMMU DMA port.
- **Risk:** DVMA coherency with the SS20 write-back cache option (OSD `OI`),
  unverified.

---

## 5. MiSTer glue

### 5.1 Clocks and reset

- **PLL.** Input `CLK_50M`; outputs 65, 80 and 40 MHz (`rtl/pll/pll_0002.v:28-34`).
  - SS5: the system clock is 65 MHz (outclk_0), the same as the pixel clock.
  - SS20: the system clock is **`CLK_50M` itself** (`ss_core.vhd:894-896`),
    with the 65 MHz pixel clock from the PLL.
  - The PLL reset is tied low (`:884`), and `locked` feeds the core reset
    (`:912`).
  - The 80 and 40 MHz outputs are unused.
  - `sys_top.sdc` puts the emu PLL outputs and `FPGA_CLK2_50` in exclusive
    clock groups, which cuts the SS20's system-to-pixel paths. That suits
    `vid.vhd`'s synchronisers; any unsynchronised path between the two
    domains would go unchecked.
- **Reset.** `reset = RESET | status[0]` (`SunSparcStation.sv:293`).
  - `ss_core` acts on the **falling edge** of its synchronised reset
    (`ss_core.vhd:1019`). While `RESET` or OSD R0 is held, the machine keeps
    running; it restarts on release.
  - An OS reboot (a syscon write with bit 0 set, `ts_io.vhd:232` since
    `ef5ef21`) jumps straight to `sWAIT` with `reboot_pending`.
  - Both paths lead to a full RAM clear.

### 5.2 The DDR map, and what else lives in the core's window

**The transform.** `ddram_address = "001" & NOT a[25:17] & a[16:0]`
(`ss_core.vhd:691-692`, `698-699`), where `a = pa[31:3]`. The core owns DDR
`0x2000_0000-0x3FFF_FFFF`, 512 MiB, in 1 MiB blocks in reverse order.
`pa[31:29]` and, on the SS20, `ah[35:32]` are dropped by the bridge (`N=32`).

| pa (core) | DDR | Occupant |
|---|---|---|
| `0x0000_0000` … `0x0FFF_FFFF` | `0x3FF0_0000` down to `0x3000_0000` | SS5 RAM, 256 MiB |
| `0x0000_0000` … `0x1CFF_FFFF` | `0x3FF0_0000` down to `0x2300_0000` | SS20 RAM, 464 MiB (`RAMSIZE = 512-32-16`, `ss_core.vhd:156`) |
| `0x1D00_0000` (2 MiB window) | `0x22F0_0000`, `0x22E0_0000` | OBRAM: the PROM image (`OBRAM_ADRS`, `ss_core.vhd:153`) |
| `0x1D40_0000` (2 MiB window) | `0x22B0_0000`, `0x22A0_0000` | TCX/CG3 VRAM (`TCX_ADRS`, `:154`); 1024×768 uses 768 KiB of the first block |
| `0x1D80_0000` … `0x1DFF_FFFF` | `0x2270_0000` … `0x2200_0000` | **Linux framebuffer**, `MiSTer_fb` reg `<0x22000000 0x800000>` (`Linux-Kernel_MiSTer/arch/arm/boot/dts/socfpga_cyclone5_de10_nano.dts:87-89`). Main's fb terminal (Ctrl+Alt+F9) draws at `0x2200_1000` (`Main video.cpp:37,3491`) |
| `0x1E00_0000` … `0x1FFF_FFFF` | `0x21F0_0000` … `0x2000_0000` | **scaler buffers**: ascal `RAMBASE 0x2000_0000`, 8 MiB (`sys/sys_top.v:716-720`); Main's "32mb (Core's fb)" (`video.cpp:37`) |
| `FB_BASE` `0x3E40_0000` | = pa `0x01B0_0000` | core RAM (V1) |

**The layout is deliberate** (upstream's initial commit noted "ASCAL:
2000_0000, FB: 2200_0000"). Linux memory lies below DDR `0x2000_0000`; Main
treats `0x2000_0000-0x3FFF_FFFF` as FPGA memory (`Main shmem.h:12`,
`user_io.cpp:746,950`), so **the core cannot reach Linux RAM**. Main's
triple-buffered menu backgrounds (`FB_SIZE*4*3` from `0x2200_0000`,
`video.cpp:2414`) reach `0x237B_B000`, over VRAM, OBRAM and the SS20's top
8 MiB of RAM. Only the Menu core draws them (`video.cpp:3884-3955`), so this
is harmless while this core runs. In a non-menu core Main uses only buffer 0,
which stays below `0x227E_A000`.

| # | Finding | Sev | Fix |
|---|---|---|---|
| G6 | **The SS20's reserved 48 MB is ordinary CPU memory.** On the SS20, `sel_decodage_smp` sends every `ah < 8` to memory (`ts_core.vhd:499`). `plomb_avalon64` ignores `ah`. Its "zone" check returns 0 on reads only when `pa ≥ RAMSIZE` and `pa & 0x1FFF_FFFF < HIMEM`, and it never blocks writes (`plomb_avalon_mister.vhd:126-133`, `151-163`). So pa `0x1D00_0000-0x1FFF_FFFF` reads and writes OBRAM, VRAM, the Linux fb and the scaler buffers, and pa `0x2000_0000-0x7_FFFF_FFFF` writes alias RAM modulo 512 MiB. OSes stay inside `/memory` `available`, but the **real OBP's SIMM probe does not** (§1, row 3). | **S1** (real OBP, SS20); S3 otherwise | Alias `0x1D00_0000-0x1FFF_FFFF` onto slot 7's first 16 MB for CPU/DVMA accesses, and ignore writes in the zone. S |
| G2' | **The RAM clear covers the whole window except the PROM image**, not "up to RAMSIZE". `sCLR` writes zeros from pa 0 to `0x2000_0000` in 8-word groups (`ss_core.vhd:942-966`); `sGAP` jumps over `[OBRAM, OBRAM + ioctl_addr + 8)`. VRAM, the Linux fb and the live scaler buffers are therefore zeroed at every reset (a black flash; the Linux terminal is erased). The duration is G2. | S3 | Clear only `0 … RAMSIZE` and VRAM. XS |

### 5.3 Shared-port bandwidth (G1 in numbers)

**Cost of one video burst.** 32 bytes (4 beats of 64 bits) cost L + 6
system cycles: IDLE, CMD, latency L, then 3 more beats. L is the DDR read
latency in system cycles, counted from command acceptance to the first
beat. An iverilog bench with a fixed-latency slave and a master that always
wants the port measured 16.0, 26.0 and 36.1 cycles per burst for L = 10,
20 and 30.

**Scan-out demand during active lines:** 1024 of 1344 pixel clocks carry a
byte, at 65 MHz.

| Build | System clock | Demand | Share of the port, L = 10 | L = 20 | L = 30 |
|---|---|---|---|---|---|
| SS5 | 65 MHz | 1 burst / 42 cycles | 38% | 62% | 86% |
| SS20 | 50 MHz | 1 burst / 32.3 cycles | 50% | 80% | 111% (underrun) |

- **Before phase 3:** video had its own port and could keep 1-2 bursts in
  flight.
- **The CPU:** it keeps what is left and waits behind a video burst on a
  miss. This is also why G2 doubled.
- **Mitigations, in order:**
  - V1 with the core's scan-out switched off, which removes video entirely;
  - a pipelined arbiter;
  - long scan-out bursts. Plomb bursts stop at 8 words
    (`rtl/plomb/plomb_pack.vhd:60-64`), and `plomb_avalon64` only maps 4 and
    8 to Avalon bursts (`plomb_avalon_mister.vhd:140-144`). This therefore
    needs a small dedicated Avalon read master for `vid.vhd` (16-32 beats per
    command), not just a `BURSTLEN` change.
- **L on MiSTer is not measured here** (§7).

### 5.4 Loader and download

**How it works.**

- `sWAIT` holds the machine in reset until either a download starts, or
  `ioctl_addr ≥ 128 KiB` (left over from the last download), or a reboot is
  pending (`ss_core.vhd:931-940`).
- A missing `boot.rom` therefore leaves a black screen with the power LED
  lit, and no message.
- `sDOWNLOAD` places each 16-bit word at `OBRAM + ioctl_addr[19:0]`, with the
  byte lanes chosen by `a[2:1]`. The byte order is right for a big-endian
  PROM image.

| # | Finding | Sev | Fix |
|---|---|---|---|
| G7 | **The download write is not latched.** In `sDOWNLOAD`, `ddram2b_address/writedata/byteenable` are recomputed every cycle from the live `ioctl_addr/ioctl_dout` (`:979-998`), and `ioctl_wait` is a registered 1-cycle pulse (`:977`). If a DDR write is still waiting for `waitrequest` when hps_io presents the next word (`sys/hps_io.sv:685-695`; Main's `fpga_spi_fast_block_write` sends words without waiting for an ack, `fpga_io.cpp:732-745`), the pending write changes address and data under `write`. A word is lost, and the Avalon rules are violated. Phase 3 makes this slightly more likely: it adds 2 grant cycles. | S2 (latent) | Latch address and data on `ioctl_wr`, and hold `ioctl_wait` until the write is accepted. S |
| G9 | **No checksum or size report.** A truncated or wrong PROM image starts anyway. | S3 | Optional: show the image size in the OSD info line. |

**`ef5ef21` "Keep the disks mounted when the OS initiates a restart"**, as
ported:

- It removed the `IF reset_n='0'` clear of `img*_mounted`.
- The mounted flags now start at `'0'` and are only ever set
  (`ss_core.vhd:228`, `514-528`).
- It adds `sysreset` → `sWAIT` + `reboot_pending` → `sCLR` (`:937-939`,
  `1019-1024`).

The phase-3 port kept it unchanged. The side effect is that an OS `reboot`
now also clears RAM (G2). §6 covers what it means for the mount state.

### 5.5 RTC

| # | Finding | Sev | Fix |
|---|---|---|---|
| G8 | **The TOD is seeded in local time.** Main sends the RTC once at core start, from `localtime()` (`Main user_io.cpp:1085-1111,1705`). `ts_rtc` seeds whenever it has not been seeded yet and the date is non-zero (`ts_rtc.vhd:248-265`), so a seed that arrives during the long reset is not lost. The year is re-based to 1968 correctly (`ss_core.vhd:831-847`), matching Solaris, NetBSD `mk48txx` and Linux `m48t59` with `yy_offset` 68. Sun OSes keep the TOD in UTC, so a MiSTer set to a non-UTC zone gives a skewed clock. | S3 | Use `TIMESTAMP` (hps_io, UTC seconds) or document it. XS |

---

## 6. Keyboard, mouse, serial, debug port

> The full audit of this area is in [keyboard-mouse-serial.md](keyboard-mouse-serial.md)
> (it arrived after this document was written); what follows is the partial first pass.

**Status: incomplete.** A separate keyboard, mouse, ESCC and debug-port
audit was still running when this file was written, and its results are not
in here. This section holds only what this audit checked itself, plus the
real-OBP requirements read from the PROM dictionary. It needs a follow-up
pass.

**What the real OBP 2.15 keyboard driver does**
(`ss5-obp/forth-dictionary.txt:13395-13626`; verified by reading, not run):

- `initkbdmouse` programs both ESCC channels from `uart-init-table`, then
  `1200baud`, which is `0x7e setbaud`: WR12 = `0x7e` via the WR0 pointer
  (`:13614-13616`, `:13718-13748`).
- `init-keyboard` sends a command, most likely reset `0x01` (inferred from
  the Sun protocol). It then waits up to 1000 ms (`0x3e8`, `:13492`,
  `:13596-13600`) for the reply and records the down keys until the idle
  code.
- Without a reply, `(ffd3882c)` prints "No Keyboard" (`:13626-13630`). QEMU
  shows "No Keyboard Detected" (`qemu-console.txt:7`), and the console falls
  back to ttya.
- `keyboard-layout` sends the layout command and reads bytes until a 100 ms
  silence (`:13464-13467`). `find-table` maps the code
  (`0x50-0x61` → `-0x2f`; `0x21` → USA) and says "Can't find keyboard table"
  for unknown codes (`:13582-13595`).
- "Keyboard error detected" is printed for the error code (`:13407`).
- **Needed from `ts_ps2sun`:** the reset response, within 1 s, at the rate
  the model uses; the layout response; and a layout byte the PROM's tables
  know. The core sends US `0x21`, FR `0x23`, DE `0x25` and ES `0x2A`
  (`SunSparcStation.sv:207-209`). `0x21` is special-cased to USA; whether
  `0x23/0x25/0x2A` match the `france-5` / `germany-5` / `spain-5` table keys
  is **unverified**.

**Findings already established** (HARDWARE_GAPS §6 and gaps #3/#4,
re-checked in the top):

| ID | Finding | Sev | Fix |
|---|---|---|---|
| K1 | **No Stop key.** No PS/2 key produces Sun `0x01` (Stop), so **Stop-A (L1-A) cannot be typed**, and Pause (E1) is ignored (`ts_ps2sun.vhd`). With the real OBP this is the only way into `ok` from a running OS, short of a BREAK on ttya. | S1 (real OBP / OS debugging) | Map Pause to Stop and add the L-keys; an OSD "Send Stop-A". S |
| K2 | **Keyboard LEDs are not passed on.** `ps2_kbd_led_*` are tied to 0 (`ss_core.vhd:819-820`). With `PS2WE = 0` (`SunSparcStation.sv:134`) the core cannot send commands to the PS/2 devices at all. | S3 | Drive `ps2_kbd_led_status/use` from the Sun LED command. S |
| K3 | **No `UART` in CONF_STR** (T3). Main offers no serial modes and gives the core no `uart_speed`. Port A goes to `/dev/ttyS1` and is shared with `tools/debugarm` through `ts_aciamux` (`ss_core.vhd:805-806`). Port B is unconnected. | S2 | e.g. `"SunSparcStation;UART115200;"`. Then check that a Main UART mode cannot trip the debug multiplexer. XS-S |
| K4 | **The wire rate is fixed.** The ESCC line to the HPS runs at `SERIALRATE = 115200` (`ss_core.vhd:304`), whatever the OS programs. The real OBP's ttya defaults to 9600, so a MiSTer user must open `/dev/ttyS1` at 115200. Whether `ts_sport` ignores WR12/13 entirely is **unverified**. Note that `tests/cpu/README.md:44-46` says 9600. | S2 (to confirm) | Confirm; either honour the time constant, or document 115200. |

Still to audit: PS/2 set-2 prefixes and typematic repeat; the mouse format
(5-byte Mouse Systems, dy sign, buttons); ESCC register coverage (WR9 reset,
RR0/RR2/RR15, BREAK and external/status interrupts, `ACIABREAK`); the
debug-port trigger sequence; and `ef5ef21`'s effect on the mount state
(§5.4 covers the reset path).

---

## 7. Open questions

1. **DDR read latency on the f2sdram port**, in system cycles, at 65 and
   50 MHz, with the scaler running. It decides whether G1 is S2 or S1 on the
   SS20. Measure it with a counter around `DDRAM_RD` → `DDRAM_DOUT_READY` on
   the first build, plus a video-FIFO underrun flag (`vfifo_lev = 0` while
   popping).
2. **Blit ordering.** A CPU store to the dumb framebuffer travels the memory
   path, while a following blit command travels the I/O path and reads VRAM
   through the video bridge. Does the MCU drain its write buffer before an
   I/O store (cpu.md)? After phase 3 both reach DDR through one port in
   acceptance order, which is better than before.
3. **Which OS enables CG3 vertical-retrace interrupts** (V3), and whether
   Solaris's `tcx` or `cgthree` driver needs any of V5/V6.
4. **FCode delivery for V4:** in the bitstream (GPL-2 binary, pending the
   phase 0 license) or loaded from `games/SunSparcStation/`?
5. **Should "Scaler framebuffer" become the default** once V1 is fixed? It
   frees the core's DDR port, but the analog VGA output then always comes
   from the scaler.
