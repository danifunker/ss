# Appendix: the Mac Quadra 800 core's NCR 53C96 model

Companion to [scsi-hps.md](scsi-hps.md), where option (b) (replace
`ts_esp` with the Mac's `ncr53c96`) is weighed and rejected. This appendix
records what that model actually implements, read from
`/home/dani/repos/MacQuadra800_MiSTer` at `6c8bfe9` (2026-09-28), so the
reasoning can be checked and the parts worth borrowing are easy to find.

Citation legend (paths under `MacQuadra800_MiSTer/`): **N** =
`rtl/ncr53c96.sv`, **I** = `rtl/iosb.sv`, **Q** = `rtl/quadra800.sv`,
**T** = `MacQuadra800.sv`, **C** = `rtl/scsi_cache.sv`, **A** =
`rtl/cd_audio.sv`, **R** = `docs/scsi/rom-driver-scsi-access-patterns.md`,
**D** = `docs/cdrom.md`.

## Headline

The model does not simulate a SCSI bus, and it has no DMA engine. The three
targets are built into the chip model itself ("The bus itself is not
modeled.", N:7). Data moves only by CPU pseudo-DMA (PDMA) through an IOSB
window. A sun4m ESP, by contrast, sits behind DMA2, which does its own DVMA
through the IOMMU. The model's parts that do carry over are the ones behind
the chip: `scsi_cache.sv` and the HPS/OSD conventions.

## Hierarchy

`emu` (T:27) contains `hps_io` (T:192; `WIDE=1`, `VDNUM=6`, `BLKSZ=2`) and
`quadra800 machine` (T:524). The machine contains `scsi_cache` (Q:245;
left out with `SCSI_CACHE_OFF`) and `iosb` (Q:376). `iosb` contains
`ncr53c96` (I:536). The chip contains its 256x16 sector buffer
`ncr_sbuf` (N:602, N:1834-1925), and, with `CDROM != 0`, `cd_audio`
(N:1796-1819).

## Ports (N:64-126)

- **CPU register bus:** `sel`, `write`, `rs[3:0]`, `wdata[7:0]`, `rdata[7:0]`
  (combinational). IOSB drives `rs = addr[7:4]`, a 16-byte stride.
- **PDMA byte handshake:** `dma_rd`/`dma_wr` held until `dma_valid`;
  `dma_wdata`/`dma_rdata`; `drq` is a level.
- **Interrupt:** `irq`, a level.
- **Target side:** `img_mounted[2:0]`, `img_size`, `io_lba`, `io_rd[2:0]`,
  `io_wr[2:0]`, `io_blk_cnt`, `io_ack[2:0]`, `sd_buff_*`. One bit per
  target: [0] = ID 0 disk, [1] = ID 1 disk, [2] = ID 3 CD. All share one
  512-byte buffer, one nexus at a time.
- **No bus pins:** there is no REQ/ACK/BSY/SEL/ATN or phase.

## Registers (reads N:350-363, writes N:1196-1225)

| Reg | Read | Write |
|---|---|---|
| r0/r1 | live 16-bit TC | TC latch (clears TC0) |
| r2 | FIFO pop (0 if empty) | push; dropped when full, no gross error |
| r3 | last command | execute |
| r4 | STATUS `{irq,0,0,tc_zero,0,phase}`, where the phase is live, not latched | dest ID |
| r5 | ISTATUS (the read clears it, irq and seq) | timeout (unused) |
| r6 | `{5'b0, seq}` | sync period (unused) |
| r7 | `{seq, fifo_cnt[4:0]}` | sync offset (unused) |
| r8 CFG1 | as written | only DISR is effective |
| r9–rC | as written | no effect |

- **Not implemented:** no CFG4, no TCHI and no chip ID. The FE/NOP|DMA → TCHI
  chip-ID idiom reads 0.
- **CFG2/CFG3:** read back exactly what was written, so a driver's revision
  probe sees fully writable config registers.
- **Interrupts and selection:** `I_SEL`, `I_SELATN` and `I_RESEL` are never
  raised. There is no selection timer: whether a selection succeeds is
  decided in the same cycle as the command write.

## Commands (N:1245-1465)

- **Commands and their behaviour:**
  - NOP, FLUSH, chip reset (config registers kept), bus reset (a notice to the
    HPS, and an ejected CD comes back).
  - Select without ATN, with ATN, with ATN3: completes **silently**. The
    target collects the CDB and raises BS|FC only when the CDB is complete.
    The IDENTIFY/tag bytes are dropped.
  - SELATNS: stops in MSG OUT.
  - TI by phase; ICCS (status and message into the FIFO even with the DMA
    bit set); MSGACC; a simplified PAD.
  - SET/RESET ATN: no-ops.
- **Missing protocol:** disconnect/reselect, ABORT and BUS DEVICE RESET
  (any message-out byte other than $01 leads to COMMAND phase), sync
  negotiation (an EXTENDED message gets MESSAGE REJECT), tagged queuing, and
  LUN decoding (every LUN answers as LUN 0).

## Data path (N:341-348, N:875-1026; I:1173-1281)

- **DRQ is 16-bit minded:** in data-in it asks for `fifo >= 2`, and during
  data-in the TC counts at FIFO fill. A byte-wide DMA2 model would leave an
  odd last byte stranded.
- **Flow control:** an idle PDMA read returns `$FF`. Blind transfers rely on
  the IOSB hold-off plus a 2^18-clock timeout that the machine turns into a
  CPU bus error.

## Targets (N:1471-1663; D:35-176)

- **Disks at IDs 0 and 1** (answer only while mounted): TUR, REQUEST SENSE,
  INQUIRY (not clamped), MODE SENSE(6) (4-byte header plus Apple page $30),
  MODE SELECT (ignored), READ CAPACITY, READ/WRITE (6, 10), VERIFY,
  SYNCHRONIZE CACHE (GOOD even while the write-behind cache is dirty),
  FORMAT, REASSIGN, SEND DIAGNOSTIC, START STOP, PREVENT. Anything else gets
  CHECK 05/20. There is no LBA range check, and `img_readonly` is not wired,
  so there is no write protect.
- **CD at ID 3:** it answers once the Main fork's identity probe succeeds.
  - Blocks are 2048 bytes only.
  - INQUIRY, mode pages, READ TOC (formats 0/1/2, MSF bit not forwarded),
    READ SUB-CHANNEL and the Apple vendor opcodes are all served from
    response windows that Main fills.
  - Audio/seek commands are forwarded to Main.
  - Eject and PREVENT are honoured.
  - No READ CD, and no UNIT ATTENTION on a media change.

## HPS side and block cache (T:145-437; C)

- **Slots:** `VDNUM=6`: 0/1 disks, 4 CD, and 3/5 used by the Toolbox and
  the changer. CONF_STR uses `SC0`/`SC1`/`SC4` (the `C` flag remembers the
  mount), and mounts are replayed after every machine reset.
- **`scsi_cache`:**
  - One dual-port M10K array (disk0 64, disk1 48, CD 16 sectors).
  - One LBA window per slot, with valid/dirty bitmaps.
  - A miss fetches an 8-sector aligned group (`sd_blk_cnt=7`), plus
    prefetch.
  - Writes are write-back, flushed per group or after 4096 idle clocks.
  - CD LBAs `>= 0x40000000` pass through.
  - Only a remount with a different size invalidates it; it survives machine
    reset.
  - This is the part [scsi-hps.md](scsi-hps.md) recommends reusing almost
    unchanged.

## What does not carry over to a sun4m ESP behind DMA2

- **Mac-specific chip behaviour:** the silent select; the 16-bit DRQ rules;
  bus-error flow control and "idle PDMA returns $FF"; exact-allocation
  serving for blind transfers.
- **Apple and A/UX specifics:** the Apple vendor pages and opcodes, and the
  A/UX-specific FIFO rules.
- **Missing features a sun4m driver is likely to use:** reselection,
  ABORT/BDR, ATN, a real selection timeout, TCHI/chip ID, LUN decoding, UNIT
  ATTENTION, write protect, a draining SYNCHRONIZE CACHE, MODE SENSE pages
  3/4/8 and MODE SENSE(10), a byte-wide DMA handshake.
