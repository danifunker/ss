# Keyboard, mouse, serial and debug port: implementation gaps

Phase 4 audit, the part split out of
[video-audio-glue.md](video-audio-glue.md) §6. Nothing in the RTL was
changed. **[V]** means verified in code (RTL, drivers, the PROM
disassembly). **[I]** means inferred, not run on hardware. Severity: **S1**
breaks an OS or feature, **S2** is wrong but tolerated, **S3** is cosmetic.
Paths are post-phase-3 (`rtl/sun4m/…`, `rtl/mister/…`).

## A. The real OBP (SS5 2.15 / SS20 2.25), in the order the PROM hits it

1. **S1: the soft-reset status bit is missing, so the PROM loops through resets forever.** [V]
   - **What the PROM expects.** `reset_entry` reads the system
     control/status register and takes the no-POST path when bit 1
     (SW_RST) is set, or bit 3 on the SS20
     ([ss5-obp/README.md](../rom-disassembly/ss5-obp/README.md) §3.1
     `0x7000bda0`; [ss20 README.md](../rom-disassembly/ss20-obp-2.25/README.md)).
   - **What the core does.** The register has no read path, so a read
     returns `0xBADACCE5` with bit 1 = 0 (`ts_io.vhd:758-760`,
     `ts_decode.vhd:97,160`). Every reset therefore looks like power-on.
     Since ef5ef21, the PROM's `sta 1,[0x71f00000]` is a full core reset:
     `sysreset` (`ts_io.vhd:232`) → `ss_core.vhd:1019-1023` → sWAIT → RAM
     clear. The ROM's fall-through into `obp_start_after_sw_reset` never
     runs.
   - **Result.** POST (or the skip-POST path) → soft reset → power-on
     again, with a 1-3 s RAM clear each time. The PROM never reaches `ok`.
   - **Fix (S-M).**
     - Add a status register whose bit 1 is set by `sysreset` and
       survives the reset (held in `ss_core` outside `reset_n`); power-on
       and OSD reset clear it.
     - Skip or shorten the RAM clear on a software reset.
     - The POST hand-off in `%g1-%g7` must also survive. The register file
       has no reset (`iu_regs_2r1w.vhd`) [I].
   - **Test.** The real SS5 OBP with `diag-switch?` false should reach
     `ok` after exactly one soft reset.
2. **S2: ttya always runs at 115200 8N1, whatever the OS programs.** [V]
   - **What the OS expects.** OBP programs 9600 8N1 (WR12=0x0e, WR4=0x44;
     Forth `default-mode`/`set-mode`).
   - **What the core does.** It stores WR12/13 but never uses them
     (`ts_sport.vhd:338-346`); the wire always runs at SERIALRATE 115200
     (`ts_core.vhd:1090-1111`, `ss_core.vhd:304`). Parity, data bits and
     stop bits are ignored too (always 8N1).
   - **What users must do today.** Set `/dev/ttyS1` to 115200 8N1.
   - **Why a 9600 terminal is worse than garbled.** A 9600 start bit (104
     µs) is longer than a whole 115200 frame, so `acia.vhd:186-194` sees a
     framing error with the stop bit low, that is, a BREAK. That feeds
     item 9 and item 10.
   - **Fix (S).** Take the ACIA rate from hps_io `uart_speed` and declare
     `UART115200` in CONF_STR (HARDWARE_GAPS #3).
3. **Keyboard detection works.** [V]
   - **POST.** `kbd_detect` wants 0x01 → 0xFF (within 0x100×0x100 polls),
     then ID 4, then 0x0F → 0xFE + layout.
   - **Forth.** `init-keyboard` sends 0x01, waits up to 1 s, reads 0xFF +
     ID, then collects make codes until 0x7F or a 100 ms gap.
     `keyboard-layout` keeps the last byte before 100 ms of silence.
   - **Core.** `ts_sunkb.vhd:119-198` answers FF 04 7F, then FE `<layout>`,
     after 1000 clocks (about 15 µs; the source comment says 20 ms). A
     command arriving mid-reply waits in the ESCC buffer, so nothing
     deadlocks.
   - **Layouts.** `find-table` maps 0x21/0x23/0x25/0x2A to US5, France5,
     Germany5 and Spain5, which match Oracle's layout table.
   - **Dependencies on other areas.** `kbd_getc_timeout` needs the proc0
     user timer, and the Forth timeouts need `get-msecs`. If those do not
     count, these loops hang (see [chipset.md](chipset.md)).
4. **S2: the reset reply never includes held keys, so Stop / Stop-D / Stop-N / Stop-F at power-on are impossible.** [V]
   - The PROM reads held make codes between the ID and 0x7F (`abort?` for
     Stop+F; Stop-N 0x69; Stop-D 0x4f; POST `reset_power_on` checks
     0x01/0x4f). The core always sends FF 04 7F.
   - **Fix (S).** An OSD entry "next reset: Stop / Stop-A / Stop-N / Stop-D"
     that inserts those codes.
5. **S2: headless use is impossible.** [V] The translator always answers
   the keyboard reset, so `install-console` never falls back to ttya with
   "Keyboard not present. Using tty…".
   - **Fix (S).** An OSD entry "Sun keyboard: attached / absent".
6. **S2: every POST LED command (0x0E v) and every OS LED update eats PS/2 bytes for about 40 ms.** [V]
   - **Why.** `ts_ps2sun` sends ED + value to the PS/2 port
     (`ts_ps2sun.vhd:734-753`). hps_io ignores the host lines with PS2WE=0
     (`sys/hps_io.sv`) but keeps sending keystrokes. `ps2.vhd:148-168`
     counts those clocks as its own transmit clocks and gives up after 20
     ms per byte, so the next incoming byte is lost.
   - **Effect.** A lost F0 leaves a key stuck down, and the OS auto-repeats
     it.
   - **Fix (S).**
     - Delete the ED path.
     - Drive `ps2_kbd_led_use <= "111"` and `ps2_kbd_led_status` from the
       Sun LED byte (`ss_core.vhd:819-820`). Main reads these whatever
       PS2WE is, so the physical keyboard LEDs work.
     - Clear the LEDs on 0x01.
7. **S3: the end of the POST output is lost before the soft reset.** [V] RR1
   "All Sent" is `do_rdy AND NOT emibuf.full` (`ts_sport.vhd:585`). That
   is true while up to 60 bytes still sit in the ACIA TX FIFO
   (`ts_core.vhd:1117`), and the reset then flushes the FIFO.
   - **Fix.** Make All Sent mean "ACIA FIFO empty and shifter idle".
8. **S1: Stop-A cannot be typed at runtime.** [V]
   - **What the PROM expects.** `poll-input` (an alarm every 10 ms) aborts
     when 0x01 is followed by 0x4D.
   - **What the core does.** No PS/2 key produces Sun codes
     0x01/0x03/0x19/0x1A/0x31/0x33/0x48/0x49/0x5F/0x61/0x76 (confirms
     HARDWARE_GAPS #4).
   - **Main.** Main maps KEY_STOP…KEY_HELP, MUTE/VOL/POWER and F13-F16 to
     NONE (`input.cpp` `ev2ps2`), so no PC or Sun-USB key can reach the
     core.
   - **Proposal (S, 1-2 days with a testbench).**
     - Pause (Main sends `E1 14 77 E1 F0 14 F0 77` on release) becomes a
       sticky Stop: send 0x01, then 0x81 after the next non-modifier key's
       break or after 1 s. Pause then A gives Stop-A.
     - PrtScr (`E0 7C`) → 0x16.
     - Holding Scroll Lock turns F1..F10 into L1..L10 and F11 into Help;
       Scroll Lock alone → 0x17.
     - An OSD entry "Send Stop-A".
9. **S1: a BREAK on ttya is never delivered.** [V]
   - **Who needs it.** OBP `poll-tty` → `ubreak?` (writes WR0=0x10, tests
     RR0 bit 7, `clear-break` waits, drops the NUL, writes 0x30). Also
     Solaris `zsa_xsint`, NetBSD zstty (console magic = BREAK) and Linux
     `sunzilog_status_handle`.
   - **What the core does.** `rx_break` is a constant "00"
     (`ts_sport.vhd:120,389`); there are no ext/status interrupts (vecode
     001/101 is never produced); `obreak` is unconnected
     (`ts_core.vhd:453,1136`); `ts_aciamux` swallows the byte after any
     BREAK (`ts_aciamux.vhd:103-114,137-141`).
   - **Fix (S-M).** The ACIA exports a break level. `ts_sport` then:
     - sets RR0 bit 7;
     - raises ext/status when WR15 bit 7 and WR1 bit 0 are set;
     - updates RR3 bits 3/0;
     - pushes a NUL when the break ends.
10. **S1 when triggered: the debug mux can take ttya over.** [V]
    - **Trigger.** A BREAK (any framing error with the stop bit low)
      followed by '3' switches the UART to the debug unit
      (`ts_aciamux.vhd:99-122`). That happens when a user sends BREAK then
      '3', or on baud-mismatch noise (item 2).
    - **Effect.** `tx0_rdy` goes to 0, so Tx-empty and All Sent stay 0 and
      OBP's `uemit`/`uwait` (no timeout) hang.
    - **What the debug unit does.** In debug mode, incoming bytes are debug
      commands. CONTROL bit 0 stops the CPU, bit 2 resets, bit 3 freezes
      the peripherals, bit 8 switches the UART to 921600, and WR_OPCODE
      injects instructions (`idu.vhd:79-88`, `iu_debug_mp.vhd:153-229`).
    - **Recovery.** BREAK then '4', or any core reset.
    - **Fix (S).** Off by default in release builds (a generic, or an OSD
      entry), or require several BREAK+'3' within 50 ms (debugarm already
      sends 8).

## B. Keyboard translator (`ts_ps2sun`, `ts_sunkb`)

- **S2: Pause sends Ctrl + Num Lock.** [V]
  - E1 is ignored, but the bytes after it are translated: 14 → 0x4C
    (Ctrl), 77 → 0x62 (Num Lock), then their breaks
    (`ts_ps2sun.vhd:87,186,292,704-724`).
  - The Sun keypad toggles Num Lock as a result.
  - HARDWARE_GAPS' "Pause is ignored" is only half right.
  - Fix together with A.8.
- **Also unmapped** [V]:
  - Sun 0x15 Pause and 0x16 PrSc, although the PS/2 keys exist (E0 7C
    decodes to nothing, line 448).
  - 0x02/0x04/0x2D/0x30 (Vol-/Vol+/Mute/Power), which Main never sends.
- **Keyboard translation is otherwise correct** [V]:
  - The scan table is positional and matches Linux `sunkbd_keycode` for
    every key checked.
  - It is the same for every layout, which is right: the OS applies the
    keymap.
  - AltGr → 0x0D, Win → 0x78/0x7A, Menu → 0x43, ISO <> → 0x7C.
- **S3 issues:**
  - Both Ctrl keys map to 0x4C, so releasing one while holding the other
    releases Ctrl.
  - No 0x7F (all up) after the last release; NetBSD resyncs on it.
  - Bell (0x02/0x03) and click (0x0A/0x0B) are accepted and ignored, so
    OBP `ring-bell` and ^G are silent.
  - More layouts (UK 0x2E, IT 0x26, SE 0x2B …) need only CONF_STR and the
    `kbm_layout` mux (HARDWARE_GAPS #19).
- **S3: commands are dropped while a key is in transit.** [V]
  - `so_rdy` defaults to '1', and only sOISIF looks at `so_req`, which
    loses to `kb_req` (`ts_sunkb.vhd:82,87-116`).
  - A lost 0x0E makes the next LED byte look like a command.
- **S3: a duplicated byte when a push and a pop hit the same clock** (about 1 in 3×10⁴ bytes). [V]
  - The push branch wins and the pop is lost
    (`ts_ps2sun.vhd:768-783,886-901`).
- **Typematic repeat** [V]:
  - Main drops repeats, so the OS does all auto-repeat, which is correct.
  - One wrinkle: Main re-sends the Pause burst on repeat.

## C. Mouse (HARDWARE_GAPS called it fine: refuted)

- **S2: fast moves go the wrong way.** [V]
  - The 9-bit PS/2 delta is cut to its low byte; the sign bits
    `dmou(20)/(21)` and overflow bits `(22)/(23)` are ignored
    (`ts_ps2sun.vhd:864,866`).
  - Main accumulates 15 ms of motion and sends up to ±255, so a flick past
    127 counts reverses direction.
- **S2: phantom clicks on NetBSD.** [V] NetBSD `ms.c:249` resyncs on any byte
  with `(c&0xb0)==0x80`. That includes dx/dy values -128..-113 and -64..-49,
  so ordinary negative deltas look like button bytes.
- **Fix for both (S).**
  - Build signed 9-bit deltas and saturate them.
  - Split each delta over the two Mouse Systems halves (dx1/dx2); Linux
    sermouse and NetBSD both sum them.
  - Clamp each byte to ±48 and carry the rest into the next packet.
- **S2, latent: the mouse FIFO is effectively one byte deep.** [V]
  - Variable `di_r` in MOUConv is never reset (declared at line 823, set
    only at line 841). After the first byte the FIFO pops every clock.
  - Bytes arriving while a 5-byte packet waits for the OS are lost.
  - Resync is only "bit 3 set" (line 843).
  - Fix: `di_r := '0'` at the top of the process, and resync on a gap of
    more than about 2 ms.
- **Correct** [V]:
  - Packet format: buttons `10000 ~L ~M ~R`; dy not inverted (right,
    because PS/2 up = + and sermouse reports REL_Y = -data).
  - Input is 3-byte PS/2 packets (the wheel goes on the side, so no
    IntelliMouse 4-byte form).
  - Bytes are not paced at 1200 baud, which is harmless.

## D. The ESCC model (`ts_sport.vhd`)

- **S1 for NetBSD serial ttys, S2 for Linux: TX interrupts get lost.** [V code trace; not run]
  - WR0 "Reset Highest IUS" (0x38) clears `tx_ip(1)`, or else `tx_ip(2)`,
    whichever channel was written (lines 214-221). A real Sun SCC gets no
    INTACK, so on real hardware this command does nothing.
  - WR0 "Reset Tx Int Pending" (0x28) with `tx_ip=0` sets `tx_mip`, which
    masks the next TX-empty edge (lines 655-660).
  - NetBSD issues CLR_INTR, then RESET_TXINT, then writes the next byte
    (`z8530sc.c:337`, `z8530tty.c:1433-1450`):
    - the second character's interrupt is masked, TS_BUSY never clears,
      and output deadlocks after 2 characters per burst;
    - NetBSD's keyboard TX also dies after its second command (`kbdsun.c`
      K_TXBUSY), which hides the LED and bell commands.
  - Linux sunzilog (RES_H_IUS, RES_Tx_P) stalls each burst until the next
    write.
  - Solaris zs (no CLR_INTR) and OBP (polled, MIE=0) are unaffected.
  - Fix (under an hour): make 0x38 a no-op, and make 0x28 clear `tx_ip`
    without arming the mask. OBP `disable-channel` also sends 0x28 and
    leaves `tx_mip` armed.
- **S2: DCD and CTS always read 0.** [V]
  - RR0 = `rx_break & "1000" & tx_empty & '0' & rx_avail` (line 389), and
    there are no status interrupts.
  - NetBSD opens non-console ttys without CLOCAL and blocks waiting for
    carrier; CRTSCTS stalls TX.
  - Fix (S): report DCD=CTS=1 (or wire them to UART_DSR/UART_CTS), and
    drive UART_DTR/RTS from WR5. They are tied to 0 at
    `SunSparcStation.sv:28`.
- **S3:**
  - MIE (WR9 bit 3) is ignored; `int` is simply the OR of all pending
    bits (line 693).
  - `rx_ip` survives a channel reset or `rx_en=0` (lines 667-674), and a
    read through RR8 does not clear it.
  - WR1 "Rx int on first char" is treated like "all chars".
  - WR5 "send break" is ignored.
  - RR15 reads 0 instead of echoing WR15. That is harmless: Linux only
    tests bit 0 to detect an ESCC, and 0 correctly reports a plain 85C30.
- **S3: port B RX is held low.** [V] `rxd4` is never driven
  (`ss_core.vhd:170`); Quartus will probably default it to '0' [I], a
  permanent break. Tie it to '1' before adding break detection.
- **Correct** [V]:
  - The register pointer resets after each control access. It is shared
    by channels A and B, as the Zilog datasheet says ("only one set
    exists").
  - RR0 bits 0 and 2; RR1 All Sent and residue; RR2 (channel B vector
    modified, "011" when idle); RR3 on channel A only; RR12/13 and their
    images.
  - WR9 channel and hardware resets.
  - Keyboard on channel A, mouse on B, at `0x71000000` / `0xFF1000000`.

## E. Debug port and debugarm

- **How it works** [V]:
  - `ACIABREAK => true` only selects BREAK (rather than CTS) as the escape
    for the console/debug mux. It is not Stop-A.
  - The `stopa` signals are the debugger's "freeze peripherals while the
    CPU is stopped" (`iu_debug_mp.vhd:253`).
  - debugarm uses `/dev/ttyS1` at 115200, raw 8N1. Terminal mode passes
    through to the Sun console. ESC ESC enters the monitor, which sends
    8 × (1 ms TIOCSBRK + '3').
  - Frames: an op byte (bits 7:4 unit, bit 3 write), then 4 little-endian
    data bytes; reads answer 4 bytes; 0x00 and 0xFF resync. Units: CPU
    0x0, SCSI trace 0x8.
- **S3 debugarm bugs:**
  - `dbg_init` sends 4 CONTROL writes before the first `dbg_mode`, so
    they land on the Sun console as junk (`main.c:138-139`,
    `lib.c:242-253`).
  - The "fast" and "slow" commands are swapped (`command.c:2774-2775` vs
    `dbg_uspeed`).
  - The fast mode (921600) also applies to the Sun console, because both
    share the ACIA.
- **SMP** (for phase 4.2) [V/I]:
  - debugarm has no CPU-start command. Entering the monitor only reads
    STATUS/CPUEN, and `dbg_init`'s zero CONTROL writes cannot produce a
    run pulse (run is a falling edge of bit 0, `iu_debug_mp.vhd:221-225`).
  - So nothing debugarm sends explains "needed for SMP". A guess: a CPU
    that enters `halterror`/dstop (a trap with ET=0,
    `iu_pipe5.vhd:1287-1289`) can only be restarted by the debugger.

## F. Upstream ef5ef21, "Keep the disks mounted when the OS initiates a restart"

- **What it changes** [V]:
  - It removes `IF reset_n='0' THEN img*_mounted<='0'`, so mounts now
    survive any core reset: OSD reset and OS reboot. Probably also a mount
    that lands during the long clear at start-up [I].
  - It adds `sysreset <= io_w.req AND io_w.wr AND sel.syscon AND
    io_w.dw(0)`, that is, any write with bit 0 set anywhere in
    `0x71Fx_xxxx` / `0xFF1Fx_xxxx`.
  - In `ss_core`, `sysreset` → sWAIT with `reboot_pending` → sCLR.
- **Phase 3 kept all of it** [V]: `ss_core.vhd:228,247-248,937-939,1019-1023`;
  `ts_io.vhd:43,232`; `ts_core.vhd:169,358,1347`.
- **What sCLR clears** [V] (`ss_core.vhd:931-967`):
  - Core addresses 0 to 0x1FFF_FFFF: the whole 512 MiB window, even on
    the SS5 with 256 MiB of RAM.
  - It skips only `[0x1D00_0000, 0x1D00_0000 + ioctl_addr[19:0] + 8)`, so
    the ROM image survives, but only up to 1 MiB (a 20-bit field).
  - TCX VRAM (0x1D40_0000) and the rest of the 4 MiB OBRAM window are
    zeroed.
  - So are the scaler's live buffers (core 0x1F80_0000+ is DDR3
    0x2000_0000+), so the screen flashes black [I].
- **Cost** [V]: at least 10 clocks per 64 bytes (a setup cycle, 8
  single-beat writes, one sGAP). That is 83.9 M clocks, **1.29 s at 65
  MHz**, before the arbiter (see video-audio-glue.md G2) and DDR3
  contention. `burstcount 8` is commented out (line 926).
- **Other side effects**:
  - The ACIA FIFO is lost on reboot (A.7).
  - With the real OBP, this path is what causes A.1.
  - OpenBIOS lives in writable RAM, so a corrupted image persists until the
    core is reloaded [I].
  - `imgN_mounted` can never clear, so an unmount leaves size 0 with
    mounted=1 (HARDWARE_GAPS #6).

## G. Verified correct

- **Keyboard protocol.** The Sun keyboard command set and replies: FF 04 7F,
  FE + layout, 0x0E + LED byte latched with the right bit mapping, bell and
  click accepted. ID 4 and the four layout codes; OBP detects the keyboard.
- **Scan codes.** PS/2 set 2 with E0/F0 handling; the PrtScr fake shifts
  are ignored.
- **Mouse.** Mouse Systems button bits and the dy sign; 3-byte PS/2 input.
- **ESCC.** The basics listed in D. The debug escape starts in Sun mode after
  every reset.
- **ef5ef21.** Preserved by phase 3, and it keeps the ROM image.
