# SCSI storage through the HPS: design and porting plan

Status: design, 2026-09-28. Not implemented. Input to REWORK.md phase 5,
item 0 ("SCSI storage modelled on the Mac cores").

**Paths.** SunSparcStation files are cited at their **post-phase-3 paths**
(`src/ts/X` → `rtl/sun4m/X`, `src/cpu/X` → `rtl/cpu/X`,
`src/board/mister/ss_core.vhd` → `rtl/mister/ss_core.vhd`,
`src/board/mister/SS_MiSTer/ss.sv` → `SunSparcStation.sv`). Line numbers are
today's; phase 3 moves files without content edits, so they stay valid until
the first RTL change. Other repositories are cited at their real paths:
`MacQuadra800_MiSTer/…` means `/home/dani/repos/MacQuadra800_MiSTer/…`.

**Evidence labels.** A plain claim was read in the cited file. *(inference)*
marks a conclusion drawn from reading, not from a run. *(not verified in this
pass)* marks something this pass did not get to read; section 6 lists what is
still open.

**Scope of this pass.** Read: the SunSparcStation storage RTL, the Mac core's
SCSI RTL (`ncr53c96.sv`, `scsi_cache.sv`, `iosb.sv`, the top) and design
documents, Main_MiSTer, and the MacLC BlueSCSI contracts. **The local
`/home/dani/repos/Main_MiSTer` checkout is stale**: plain upstream `master`
at `915ca33` (2026-08-28), no fork branches, no fetch since it was cloned on
2026-09-05. Newer upstream and fork state was read read-only from GitHub, so
Main line numbers are for `915ca33` unless marked "upstream". The user's
NeXT-Color core is not on this machine (it exists on GitHub as
`danifunker/NeXT-Color_MiSTer`) and is ignored, except that its Main support
is the closest precedent (2.4).

---

## 1. Summary and recommendation

Keep the SPARCstation's ESP model (`ts_esp`) and its DMA2/IOMMU path, which
every sun4m OS already drives, and replace everything behind the ESP's
target-side record interface: the three microcoded targets (`scsi_mist`,
`scsi_mist_cdrom`), the Direct SD target (`scsi_sd`) and the two muxes in
`ss_core.vhd` give way to **one SystemVerilog target engine** that serves
disks and a CD-ROM at OSD-selectable SCSI IDs. It sits behind the Mac core's
**`scsi_cache.sv` block cache, reused nearly verbatim**, on the standard
`hps_io` block channel with multi-block transfers. Mount handling (media
present, unmount, media change, read-only) follows the Mac core's rules, and
the OSD follows its conventions (`SC` slots, per-slot mount memory). This is
option (a) in section 4. It needs **no Main_MiSTer change** for disk images
and flat ISO CD images: stock Main already serves multi-block requests, and
SGIIndy_MiSTer runs the same `scsi_cache.sv` against it. Only CUE/BIN/CHD
discs and CD audio need Main work: a `support/sparc/` family in the style of
upstream `support/mac/` and `support/next/`, gated on the core name. That is
an optional last phase.
Replacing `ts_esp` with the Mac's `ncr53c96` (option b) is not recommended:
that chip model is shaped around the Quadra's CPU-driven pseudo-DMA, the Apple
ROM and the Apple CD dialect, while the sun4m ESP is fed by a DMA2 bus master
through the IOMMU. The swap would re-open OS bring-up the core has already
done, for a register-fidelity gain that can be had by fixing `ts_esp` in
place (phase 4.5). The BlueSCSI HPS contract (option c) turned out not to be
an alternative: it keeps the target in the FPGA and only carries the Toolbox
vendor commands to the ARM. It can be added later on top of (a).

---

## 2. The Mac model (MacQuadra800_MiSTer) as built

### 2.1 Block diagram

```
 68040 ── iosb (PDMA decode, /DTACK hold-off on !DREQ) ── ncr53c96.sv
                                                           │  53C96 registers, FIFO, INT
                                                           │  + 3 targets folded in, one
                                                           │    nexus at a time (cur_tgt):
                                                           │    ID 0 disk, ID 1 disk,
                                                           │    ID 3 AppleCD (SONY CDU-8004)
                                                           │  + cd_audio.sv (frame fetch,
                                                           │    44.1 kHz cadence) -> cd_snd_l/r
                                             engine block port (hps_io-shaped)
                                                           │
                                           scsi_cache.sv  (per-slot LBA windows,
                                                           read-ahead + write-behind,
                                                           8-sector groups; CD windows
                                                           >= 0x40000000 pass through)
                                                           │  p_lba/p_blk_cnt/p_rd/p_wr/...
                         MacQuadra800.sv: mount memory + replay after every reset,
                                          per-slot sd_rd/sd_wr assigns
                                                           │
                          hps_io VDNUM=6, WIDE, BLKSZ=2 (512 B), 13-bit sd_buff_addr
         slot 0 SC0 disk 0 | 1 SC1 disk 1 | 3 Toolbox | 4 SC4 CD-ROM | 5 CD changer
                                                           │
                    Main_MiSTer: stock sd_image path for disks and flat ISO;
                    fork support/mac/ for CUE/BIN/CHD, TOC blob, CD-DA frames,
                    response/command windows (cores in is_mac_scsi_family())
```

Sources: `MacQuadra800_MiSTer/CLAUDE.md:21`, `docs/cdrom.md` ("Shape"),
`docs/scsi-block-cache.md`, `MacQuadra800.sv:145-234`.

### 2.2 Modules and responsibilities

| Module | Size | Responsibility |
|---|---:|---|
| `rtl/ncr53c96.sv` | 1,925 lines | 53C96 register/FIFO/interrupt model "exactly as the ROM and A/UX's `c94` driver validated it", with three targets built in behind one 512-byte sector buffer (`ncr_sbuf`, `ncr53c96.sv:1834-1925`), one nexus at a time (`docs/cdrom.md`, "Shape"). "The bus itself is not modeled" (`ncr53c96.sv:7`): there are no REQ/ACK/phase pins, only a CPU register port, a byte PDMA handshake (`dma_rd/dma_wr/dma_valid/drq`, `:85-91`) and the hps_io-shaped block port (`:94-111`). The CD command layer (INQUIRY, MODE SENSE/SELECT, sense, TOC via Main) lives here too |
| `rtl/iosb.sv` | 1,294 lines | register and PDMA decode, the PDMA beat FSM with /DTACK hold-off and a 2^18-clock watchdog that becomes a CPU bus error, DREQ as a live VIA2 IFR bit (`iosb.sv:457-473`, `1173-1281`) |
| `rtl/cd_audio.sv` | 512 lines | since phase 2 of `optimize-SCSI`: the blob-header parse, the status poke, the frame-fetch loop and the 44.1 kHz sample engine with interpolation; the playhead moved to the ARM (`docs/cdrom.md`, "Responses from Main") |
| `rtl/scsi_cache.sv` | 607 lines | per-target read-ahead/write-behind buffer between the engine and `hps_io` (`scsi_cache.sv:1-49`). Engine side and platform side are both hps_io-shaped (`scsi_cache.sv:64-85`), so the engine did not change when it went in |
| `MacQuadra800.sv` | top | CONF_STR, slot wiring, mount memory and replay (`MacQuadra800.sv:382-437`) |

Area as of 2026-09-16: `ncr53c96` 2,870 ALMs total, of which `cd_audio`
1,346 before phase 2; `scsi_cache` 877 ALMs and 40 M10K; `hps_io` 612 ALMs at
VDNUM 6 (`docs/scsi-hps-offload-plan.md`, section 1 table).

### 2.3 The HPS contract as the Mac uses it

- **Slots** (`MacQuadra800.sv:145-150`): 0 disk 0, 1 disk 1, 2 unused (PRAM
  in MacLC), 3 BlueSCSI Toolbox control, 4 CD-ROM, 5 CD changer. The numbers
  are the Main fork's "Mac SCSI family" layout, so Main's handlers apply
  unchanged once the core name is listed (`docs/cdrom.md`, "Shape").
- **One transaction at a time.** The three targets share `scsi_lba`,
  `scsi_buff_din` and one `scsi_blk_cnt`; each slot gets its own
  `sd_rd`/`sd_wr` bit, assigned one by one, not by concatenation, after a
  packed literal once put the CD strobe on slot 5 (`MacQuadra800.sv:165-190`;
  the hardware-only failure is in `docs/cdrom.md`, "What only hardware
  showed").
- **Multi-block.** `sd_blk_cnt` carries the cache's `p_blk_cnt` for slots 0,
  1 and 4 (`MacQuadra800.sv:224`). The cache works in aligned 8-sector groups:
  demand fetches, a prefetch of the next two absent groups, and 8-block
  flushes of fully dirty groups (`docs/scsi-block-cache.md`, "Multi-block
  transactions"). `sd_buff_addr` is the full 13 bits (`MacQuadra800.sv:154`).
- **Block cache.** One true-dual-port M10K array, 64 + 48 + 16 sectors, or
  32/32/16 under the `CACHE_SMALL` release recipe
  (`MacQuadra800_MiSTer/rtl/quadra800.sv:215-224`). Each slot owns one
  contiguous LBA window with valid and dirty bitmaps. A miss outside the
  window flushes and re-bases. Coherency rules and the two races the random
  bench found are in `docs/scsi-block-cache.md` ("Coherency rules"). Writes
  are acked from block RAM in ~25 µs and flushed behind; that also removed a
  deadlock class (a write flush outstanding across a target switch,
  `7662726`).
- **Mount, unmount, size, read-only.** `hps_io` pulses `img_mounted` once
  per mount. The target latches `mounted`/size only on that pulse, and its
  state is reset-gated, so the top keeps one mount memory per target outside
  the machine reset and **replays the pulses one target at a time after
  every reset release** (`MacQuadra800.sv:382-437`). `img_size == 0` is an
  eject and is replayed too (`MacQuadra800.sv:421`). The cache invalidates a
  slot only when the size changes, so a same-size replay keeps dirty data
  (`scsi_cache.sv:39-42`). `img_readonly` is not forwarded past the top.
  The CD rejects writes regardless, with DATA PROTECT/`27h`
  (`docs/cdrom.md`, "The CD-ROM target").
- **Media change (CD).** No disc: media commands CHECK with NOT READY and
  ASC `B0h` (the AppleCD answer; `3Ah` makes Mac OS nag to format). Eject is
  START STOP LoEj or Apple `C0h`, honouring PREVENT; an eject lasts until the
  next bus reset (`cd9deb8`). A mount pulse for the disc already present is
  a no-op (`2631967`). **There is no UNIT ATTENTION anywhere**: a media change
  only updates `tgt_mounted`/`tgt_blocks` (`ncr53c96.sv:778-787`). The Mac
  OS polls TEST UNIT READY and copes; Solaris and NetBSD expect 28h/29h
  *(inference)*, so here the Sun engine must go further than the Mac.
- **What the Mac targets leave out** (`ncr53c96.sv:1471-1663`): no LBA range
  check; no write protect (`img_readonly` is not wired past the top,
  `MacQuadra800.sv:160`, `233`); LUN not decoded, so every LUN answers as
  LUN 0; SYNCHRONIZE CACHE answers GOOD while the write-behind cache is still
  dirty; no MODE SENSE pages 3/4/8, no MODE SENSE(10); REQUEST SENSE and
  INQUIRY not clamped to the allocation length. None of this hurt the Mac
  OS. A sun4m OS that scans LUNs (SunOS, Solaris) would see ghost units
  *(inference)*.
- **Engine ↔ cache.** The chip always asks for one 512-byte sector
  (`io_blk_cnt = 0` unless the audio engine owns the channel,
  `ncr53c96.sv:256-261`) and has no double-buffering; the next sector is
  requested once the buffer is spent (`:841-851`). The cache's group fetches
  and prefetch hide that latency.
- **CD block size.** 2048 only. READ(6/10/12) scale LBA and count by four onto
  512-byte HPS blocks. A MODE SELECT asking for 512-byte blocks is refused
  with ILLEGAL REQUEST 05/26/00 (`4f859b3`), because honouring it made the
  Mac ROM register a retail disc's HFS volume twice (`docs/cdrom.md`, "Block
  size"). **The Sun core must do the opposite; see 4.4.**
- **CD TOC and audio.** A flat 2048-byte ISO works on stock Main. CUE/BIN/CHD
  need the fork's `mac_cdrom.cpp`, which serves a flat 2048-byte data window,
  an `MCDA` TOC blob at HPS block `0x7FFF0000` and raw 2352-byte CD-DA frames
  at `0x40000000 + lba`. Since `optimize-SCSI` (2026-09-16) the fork also
  serves a response window (`0x7E000000 + op<<16 + a<<8 + b`: INQUIRY, MODE
  SENSE, READ TOC and the Apple TOC/sub-channel forms), a command window
  (`0x7D000000 + op<<16`, write: MODE SELECT lists, transport CDBs, eject,
  reset notices) and a next-frame window (`0x7C000000`, 5 blocks, playhead on
  the ARM). A capability probe after every reset and mount arms `cd_hps_ok`;
  without it the CD target does not answer selection (`docs/cdrom.md`,
  "Responses from Main"; `docs/scsi-hps-offload-plan.md` section 4).

### 2.4 Main_MiSTer side

**Stock Main already does what the disks need.** The request word carries
`sd_blk_cnt` (template `sys/hps_io.sv:329`). Main decodes it as
`blks = ((c >> 9) & 0x3F) + 1`, clamped to the 16 KB `UIO_BUFFER_SIZE`
(`Main_MiSTer/user_io.cpp:3254-3269`, `user_io.h:167`). Each slot's 16 KB
buffer doubles as a read-ahead cache: a miss reads 16 KB and the next 16 KB is
prefetched (`user_io.cpp:3235`, `3417-3530`). Writes invalidate it and go to
O_SYNC files (`:3347-3396`). Main services at most 4 requests per
`user_io_poll` (`:3230`). SGIIndy_MiSTer relies on exactly this, with the
Quadra's `scsi_cache.sv` and `sd_blk_cnt = 7`
(`SGIIndy_MiSTer/rtl/scsi/README.md:85-131`): a second core already reuses
the cache.

**The Mac family's storage code is upstream now, not only in a fork.** All
commits are the user's (plus danielb0 for #1295):

| Main commit | Date | What | Released? |
|---|---|---|---|
| `035b86f` (PR #1255) | 2026-08-02 | `support/mac/`: BlueSCSI Toolbox, CD changer, CUE/BIN/CHD CD images | yes, release 20260823 |
| `9b193ea` (PR #1295) | 2026-08-28 | CD slot for MacPlus | release 20260912 |
| `f6a3caa` (PR #1321) | 2026-09-21 | "MacQuadra800 joins the SCSI family; its CD-ROM is served from Main" (response, command and frame windows) plus SONIC Ethernet | master only |
| `5fb9bd1` (PR #1327) | 2026-09-26 | NeXT: SCSI target responses **for disks too**, CD audio, MO ECC, in `support/next/` | master only |
| `f2d08a5` (fork `next-color`) | 2026-09-26 | `is_next()` also matches "NeXT-Color" | not merged |

- **Hooks.** `mac_mount_hook` (`user_io.cpp:2204`), `mac_cdrom_unmount`
  (`:2223`), `mac_poll()` (`:3172`), `mac_cdda_window` forcing
  `blksz = 2352` (`:3259`), and `mac_sd_service` ahead of the generic path
  (`:3330`). NeXT adds its own three hooks next to them (upstream). **There
  are no new UIO opcodes**: everything rides 0x16/0x17/0x18/0x1c/0x1d
  (`user_io.h:32-39`).
- **Gating by core name.** Upstream `mac.cpp:21-29`: `is_mac_scsi_family()`
  is maclc, macplus and macquadra800 (MacIIvi and LBMacTwo left the family
  with #1321), and `is_mac_scsi_optimized()` is macquadra800 only. NeXT uses
  `!strcasecmp(orig_name, "NeXT")`. Each family keeps its own copy of the
  code under `support/<family>/`; there is no shared SCSI module.
- **CD images** (`mac_cdrom.cpp`): CHD through libchdr, CUE with multiple
  FILEs and PREGAP/INDEX 00, raw 2352/2336 probed by PVD and sync pattern
  (`:309-368`). A flat 2048-byte image is PASSTHRU to the generic path,
  except for "optimized" cores. The `MCDA` blob sits at `0x7FFF0000`; CD-DA
  frames at `0x40000000 + lba`.
- **Limits.** `mac_sd_service` has a 4096-byte buffer, and a larger request
  falls to the generic path, which is wrong for CUE/CHD (`mac.cpp:112-113`).
  The CD fill accepts 512-4096 bytes in 512-byte steps only on upstream
  master (it zero-filled anything but 512/2352 at `035b86f`).
- **The Quadra's own dependency.** Since the capability probe (2026-09-16),
  the Quadra shows **no CD at all, flat ISO included**, on a Main older than
  `f6a3caa`, which is on master but in no release yet. That contradicts
  `docs/cdrom.md:41-43` ("a flat ISO/TOAST works on a stock Main"). Its disks
  work on any Main. The Quadra ships its own Main binary in `releases/`.

**Current direction** (from the dates above): the *hybrid* model. The FPGA
keeps the SCSI engine, the targets, the READ/WRITE data path and a block
cache. Main answers command responses (first CD only, then disks too for
NeXT), translates CD images and runs the audio playhead. They talk through
magic-LBA windows on the ordinary sector channel. The Quadra plan gives the
reason for keeping the data path in RTL: "a per-command ARM turnaround is too
slow for the disk" (`docs/scsi-hps-offload-plan.md` section 1).

**BlueSCSI** is not a general contract. `BLUESCSI_CORE_HPS_CONTRACT.md`
(MacLC, "FROZEN design", 2026-06-15, `9af7a04`) keeps the target in the FPGA
(`rtl/scsi.v`) and carries only the vendor opcodes 0xD0-0xD5 to the ARM, on
slot 3: a request written at LBA 0, a status read at LBA 0 (signature 0xB5),
data at LBA 1+k. The CD-changer contract uses the same transport on slot 5
(0xD7/0xD8/0xDA). Main implements both in `mac_toolbox.cpp` (64 KB
transfers, file sharing from `games/<core>/shared`). The implementation has
since moved past the frozen text (64 KB and a 17-bit length, not 512
bytes).

### 2.5 OSD / CONF_STR conventions

- `SC0,HDAVHD,Mount SCSI disk 0;`: the `C` flag makes Main store
  `config/<core>.s0` and re-mount the image at the next core start. With a
  plain `S0` the mount is forgotten every boot (`MacQuadra800.sv:68-76`).
  Every Mac sibling core uses `SC`.
- The CD slot's extension list includes CUE/BIN/CHD (`MacQuadra800.sv:80`);
  the Main fork is what makes them work.
- MacLC puts its PRAM on a VD, `SC2,NVR,Mount PRAM;`, and saves it when the
  OSD opens (`MacLC_MiSTer/MacLC.sv:65`, `148-150`, `206-208`). That is the
  precedent for SunSparcStation's NVRAM persistence (HARDWARE_GAPS #5).

### 2.6 Pitfalls from the Mac's history

1. **Wiring the top level is where hardware-only bugs live.** The Mac's
   full-machine sim instantiates `quadra800`, not `emu`, so slot wiring and
   the mount replay are not covered. The CD strobe on the wrong slot was
   found on hardware (`CLAUDE.md`, "Simulation"; `docs/cdrom.md`). Bench the
   top-level glue too.
2. **Width and concatenation errors.** A 7-bit concat zero-extended to 8 and
   an out-of-range bit select that Verilator simulated as 0 while Quartus
   rejected it (`docs/scsi/repo-scsi-issue-history.md:544-548`; `CLAUDE.md`,
   "Simulation"). SunSparcStation has exactly this class today (3.5, D1).
3. **Status and interrupt bit semantics against QEMU `esp.c`** is the one
   class that bit the Mac's chip model twice (`repo-scsi-issue-history.md:532-542`).
4. **Handshakes with no timeout** hang the machine silently
   (`repo-scsi-issue-history.md:556-563`).
5. **A write reported GOOD while its flush is still outstanding** deadlocked
   the installer on a target switch (`7662726`). The cache fixed the shape.
6. **Channel ownership.** When two requesters share one hps_io channel (the
   CD target and its audio engine), a same-cycle request merged into one wrong
   transaction; discard flags armed on the wrong transfer ate the next nexus's
   first block (`docs/cdrom.md`, the `eng_owns` paragraph; Mac commits
   `3ec22e4`, `2922294`). Any second requester on the SS side (CD audio) must
   use an explicit owner register from the start.
7. **Blind transfers.** Serve exactly the allocation length, zero-filled, for
   TOC and sub-channel replies (`docs/cdrom.md`). Sun drivers use DMA with a
   byte count, but the rule costs nothing.

---

## 3. SunSparcStation's storage path today

### 3.1 Block diagram

```
 CPU ── io bus (type_pvc) ──┬── ts_dmaux  DMA2 D_CSR, D_ADDR (no D_BCNT)
                            │      │ dma_esp_iena/reset/addr_w/addr_maj
                            └── ts_esp   53C9x regs, 16-byte FIFO, 16-bit TC,
                                   │     initiator-only command FSM
       DVMA: pw/pr (plomb, one 32-bit word per 4 bytes, PB_SINGLE)
         └─> plomb_mux (ESP, LANCE, APC) ─> ts_iommu ─> memory
                                   │
                type_scsi_w / type_scsi_r  (abstract record "bus", ts_pack.vhd)
                                   │
          ss_core MUX_SCSI: routes the r-record of the one target whose .sel is up
      ┌───────────────┬────────────┴───┬───────────────────┬───────────────────┐
  scsi_mist #0     scsi_mist #1     scsi_mist_cdrom     scsi_sd (Direct SD)
  ID 0 (1 in SD+Img) ID 1           ID 6                ID 0 or 1, SDIO pins
  2x512 B buffer   2x512 B buffer   2x512 B buffer      (to be removed)
      └───────────────┴───────┬────────┘
          ss_core scsimux: one sd_rd/sd_wr at a time, then a 32-cycle wait
                              │
       hps_io VDNUM=3, WIDE, sd_blk_cnt = 0 (one 512-byte block per request)
          slot 0 "S0,RAW,HD"    slot 1 "S1,RAW,HD2"    slot 2 "S2,ISO,CDROM"
```

### 3.2 Modules

| Module | Responsibility | Evidence |
|---|---|---|
| `rtl/sun4m/ts_esp.vhd` | ESP registers (TC lo/hi, FIFO, CMD, STAT/DESTID, INTR, STEP, FFLAGS, CFG1-3), 16-byte FIFO, commands NOP, FLUSH, RESET, BUS RESET, TI, ICCS, MSGACC, PAD, SET ATN, SEL, SELATN, SELATNS, ENSEL; DMA by byte into a word buffer, one plomb request per 4 bytes | `ts_esp.vhd:15-31`, `81-93`, `173-326`, `372-630`, `699-826` |
| `rtl/sun4m/ts_dmaux.vhd` | DMA2 D_CSR (IE, RESET, WRITE, EN_DMA, INT, dev ID `0xA`) and D_ADDR; the address counter itself lives in `ts_esp` | `ts_dmaux.vhd:193-217`; `ts_esp.vhd:787-790` |
| `rtl/sun4m/ts_io.vhd` | ESP instance and its DVMA path: `esp_pw` → `plomb_mux` → `ts_iommu` | `ts_io.vhd:326-380`, `393-411` |
| `rtl/sun4m/ts_pack.vhd` | the record bus: `type_scsi_w` = d, ack, bsy, atn, did, rst; `type_scsi_r` = d, req, phase, sel, d_pc | `ts_pack.vhd:152-167` |
| `rtl/sun4m/scsi_mist.vhs` (→ generated `.vhd`) | microcoded disk target on the record bus, 2×512-byte ping-pong buffer to `hps_io` | `scsi_mist.vhs:26-56`, `75-78`, `1019-1062` |
| `rtl/sun4m/scsi_mist_cdrom.vhs` | the same for a CD-ROM, 2048/512-byte logical blocks (`ssize`) | `scsi_mist_cdrom.vhs:27-57`, `755-800`, `926-932` |
| `rtl/sun4m/scsi_sd.vhs` | Direct SD target driving the SDIO pins, capacity set by firmware through AUXIO0 +0x18/+0x1C | `scsi_sd.vhs:28-52`, `1162-1206`; `ts_dmaux.vhd:321-341` |
| `rtl/sun4m/dl_scsi.vhd` | debug-link tracer that snoops the record bus for `debugarm` | `dl_scsi.vhd:29-48`; `ts_core.vhd:1156-1170` |
| `rtl/mister/ss_core.vhd` | instances, IDs, mount latch, `scsimux`, `MUX_SCSI` | `ss_core.vhd:388-661` |
| `SunSparcStation.sv` | CONF_STR, `hps_io` instance | `ss.sv:209-300` today |

The `.vhd` targets are generated from the `.vhs` microcode by
`asm_mist.rb` / `asm_mist_cdrom.rb` (REWORK.md, "Facts collected so far").
`sclk` is `clk_sys` (`ss_core.vhd:890-905`), so the targets and `hps_io`
share one clock: 65 MHz on SS5, 50 MHz on SS20.

### 3.3 The record-bus contract (what a replacement target must honour)

Read from `ts_esp.vhd` and `scsi_mist.vhs` (this protocol is not the real
SCSI bus):

- **Selection.** The ESP drives `did` and waits one cycle for `sel`. `sel`
  is combinational "a target has this ID" (`scsi_mist.vhs:760-761`). No `sel`
  means a selection timeout: `sNOSEL`, a Disconnected interrupt
  (`ts_esp.vhd:540-554`, `613-621`).
- **Nexus.** `bsy` is initiator-held: set at selection and by ICCS, cleared
  when ICCS completes (`ts_esp.vhd:520-538`). The target idles until `bsy`
  rises and returns to idle when it falls, or when `bsy=0` with another
  `did` (`scsi_mist.vhs:971-973`).
- **Transfer.** The target sets `phase` and raises `req`, with data on `d`
  for IN phases. The ESP answers with `ack`, and the target drops `req`. The
  ESP gates `ack` with its own DMA/FIFO readiness (`ts_esp.vhd:640-690`), so
  flow control is free.
- **Messages.** SELATN sends one message byte, then the command. SELATNS
  stops after the message (`ts_esp.vhd:556-600`). MSGACC is taken to mean the
  target disconnects (`ts_esp.vhd:424-436`).
- **Reset.** `rst` restarts every target (`scsi_mist.vhs:975-978`).

Any new target has to keep this contract (it is also what `dl_scsi` traces),
unless `ts_esp` changes in the same step.

### 3.4 HPS side

`hps_io` has `VDNUM(3)` and `WIDE(1)`, with `sd_blk_cnt('{0,0,0})`
(`ss.sv:265-300`), so every transfer is one 512-byte block. Only 8 bits of
the 13-bit `sd_buff_addr` are wired (`ss.sv:250`), which is enough for 256
words. `scsimux` serialises the three targets, holds the strobe until `ack`
falls, then waits 32 cycles (`ss_core.vhd:531-600`). A request for an
unmounted slot is acked at once without a transfer (`sSKIP*`,
`ss_core.vhd:536-552`, `571-572`, `591-596`). Mounts are latched in a process
without reset, so they survive a machine reset, but nothing clears them
(`ss_core.vhd:510-529`). The CD's read-only flag is forced to 1
(`ss_core.vhd:526`).

### 3.5 Defects (verified by reading)

| # | Defect | Evidence | Effect |
|---|---|---|---|
| D1 | **`scsi_conf` and `scsi_cdconf` are 1-bit wires.** `wire scsi_conf = status[3:1];` and `wire scsi_cdconf = status[5:4];` have no range, so each keeps only its LSB, `status[1]` and `status[4]` | `ss.sv:314-315`, ports `ss_core.vhd:97-98` | SCSI menu: "Image+Image" (2) gives Image only, "SD+Image" (3) gives Direct SD, "Image+SD" (4) gives Image. **The second disk is unreachable.** CDROM menu: "2048" (1) works, but **"512" (2) turns the CD off**, and `ssize = scsi_cdconf(1)` (`ss_core.vhd:492`) is always 0, so 512-byte mode can never be selected. *(inference: Quartus zero-extends the 1-bit actual onto the 3-bit VHDL port with a width warning)* |
| D2 | Mounts forgotten at every core start: `S0`/`S1`/`S2` lack the `C` flag | `ss.sv:214-217`; the Mac's lesson at `MacQuadra800.sv:68-74` | users re-pick every image after each core load |
| D3 | No unmount and no presence. `imgN_mounted` is set for good. The target ports `hd_mounted` and `hd_ro` are declared but never read. The disk target answers selection whether or not an image is mounted | `ss_core.vhd:510-529`; `scsi_mist.vhs:48-49`, `760`; `scsi_mist_cdrom.vhs:48-49` | a phantom disk at target 0 with no image (reads return a stale buffer via `sSKIP`); an OSD unmount is invisible |
| D4 | No media change on the CD: TEST UNIT READY is always good; there is no NOT READY, no UNIT ATTENTION and no eject | `scsi_mist_cdrom.vhs:231-234`, `649-657` | Solaris "Software 2 of 2" and other multi-CD installs cannot see a swap (HARDWARE_GAPS #6) |
| D5 | **READ TOC is not implemented.** `43h` is only in the to-do list; the dispatch has no entry, so it CHECKs ILLEGAL REQUEST | `scsi_mist_cdrom.vhs:225-244`, `736` | HARDWARE_GAPS §6 says "`READ_TOC` implemented"; that is wrong and should be corrected there. `hsfs` mounting works without it (the README's Solaris 8 CD use); audio tools and some installers need it *(inference)* |
| D6 | Read-only ignored: MODE SENSE reports WP=0 and writes proceed | `scsi_mist.vhs:543-545`, `342-420` | a read-only image is written through Main, or fails silently *(not verified which)* |
| D7 | Off-by-one in the bounds check. `capacity_m` is the last LBA, and `TEST_ADRS` rejects `r_adrs >= capacity_m`, so the last block is unreadable. A transfer that starts in range is never checked at its end | `scsi_mist.vhs:765-766`, `921-922` | `dd` of the last sector fails; runs past the end reach Main |
| D8 | Fixed target IDs: 0 (1 in "SD+Image"), 1 and 6; Sun's internal disks are 3 and 1 | `ss_core.vhd:408`, `447`, `471`, `496`; SS5 service manual App. C (`scratch/SparcStation/text/Marquette__…txt:5655-5685`) | images from real machines are installed at `c0t3d0` (HARDWARE_GAPS #12) |
| D9 | Throughput: one Main round trip per 512 bytes, plus a 32-cycle gap; the ping-pong buffer overlaps at most one sector | `ss.sv:294`; `ss_core.vhd:573-577`; `scsi_mist.vhs:236-311` | *(inference)* bounded by Main's per-request latency (~100 µs per block in the Mac's measurements, `docs/scsi-block-cache.md` "Why"), i.e. a few MB/s at best |
| D10 | Thin command set. Disk: READ/WRITE(6/10), INQUIRY, TUR, START STOP, PREVENT, MODE SENSE(6) (block descriptor only, no pages), READ CAPACITY, REQUEST SENSE (key only, no ASC/ASCQ), SYNCHRONIZE CACHE. Anything else CHECKs. INQUIRY advertises Sync=1 but message-out handling reads at most two bytes ("for NextSTEP") and never answers SDTR | `scsi_mist.vhs:170-211`, `464`, `142-167`, `600-640` | Solaris `format` gets no geometry pages 3/4 *(inference)*; MODE SELECT, VERIFY, FORMAT UNIT, READ(12) fail |
| D11 | ESP-side limits that constrain any target: initiator only; no reselection; ENSEL does nothing; sync period/offset ignored; no SELATN3 or RESET ATN; 16-bit TC with no TCHI/chip-ID register at `0x38`; no D_BCNT; EN_DMA stored but ignored | `ts_esp.vhd:81-93`, `247-270`, `322-326`, `468-473`; `ts_dmaux.vhd:202`, `218-220` | targets must never disconnect and must answer SDTR with async (offset 0) or MESSAGE REJECT; register fidelity is phase 4.5 work |
| D12 | Direct SD is wired into firmware-visible state: `swconf(0)` = "SD present" and `swconf(1)` = "two disks" go to AUXIO0, and AUXIO0 +0x18/+0x1C are the SD controller's registers | `ss_core.vhd:868-873`; `ts_dmaux.vhd:321-341` | removing Direct SD must leave `swconf(0)=0` and those registers reading 0, and OpenBIOS's behaviour then has to be checked (question 7) |

---

## 4. Porting options

### 4.1 The options

**(a) Keep `ts_esp`; replace the target and bridge side.** A new SV target
engine on the record bus replaces `scsi_mist*`, `scsi_sd`, `scsimux` and
`MUX_SCSI`. It is one engine with a per-ID personality table (disk or CD,
slot, present, read-only, block size, sense, pending UNIT ATTENTION), like
the Mac's single nexus behind `cur_tgt`. It connects to `hps_io` through the
Mac's `scsi_cache.sv`. The Mac's mount memory, the OSD conventions and the
target *behaviour* (sense rules, eject and PREVENT, bounds checks, the
allocation-length rule) are reused as design. The Mac's target *code* is
folded into `ncr53c96.sv` and speaks the Apple dialect, so it is ported, not
instantiated.

**(b) Replace `ts_esp` with the Mac's `ncr53c96`.** Same 53C9x family and
register map. The interface gap is concrete, though:

| Aspect | sun4m ESP (what the OSes use) | Mac `ncr53c96` | Consequence for (b) |
|---|---|---|---|
| Data mover | DMA2 D channel is a bus master: the ESP raises DREQ, DMA2 fetches or stores words over SBus/DVMA through the IOMMU (`ts_io.vhd:326-411`; QEMU `hw/dma/sparc32_dma.c:147-165` `espdma_memory_read/write`) | pseudo-DMA: the 68040 moves the data through a 32-bit port at `base+$40100`, gated by DREQ and /DTACK hold-off in `iosb` (`docs/scsi/README.md` row 1; `repo-scsi-issue-history.md` Part D) | a DMA2 engine that turns DREQ plus the chip's data port into plomb bursts has to be written, plus D_ADDR/D_BCNT/EN_DMA; the Mac's DREQ thresholds and TC0 burst gating were tuned for the ROM's 16-byte PDMA bursts |
| Drivers to satisfy | OpenBIOS `esp`, SunOS 4 `esp`, Solaris `esp`, NetBSD `esp_sbus` + `lsi64854`, Linux `sun_esp`, NeXTSTEP | Mac ROM, Apple SCSI Manager, A/UX `c94`, NetBSD mac68k | every sun4m OS boot is re-opened; the Mac's validation corpus does not transfer |
| Targets | separate modules on a record bus | folded into the chip, one nexus, Apple CD dialect (SONY CDU-8004, `$30` page, `$C1`/`$C2`/`$CC`, 2048-only, Main response windows) | the targets would have to be split out anyway to drop the dialect |
| DMA handshake | DMA2 moves words; an odd final byte and the FIFO residue must be right for the drivers' residual count | DRQ asks for 2 bytes at a time (`ncr53c96.sv:341-348`); on data-in, TC counts when a byte enters the FIFO, not when DMA takes it (`:917-922`) | the DREQ and TC rules would have to be redone for a byte/word DMA2 |
| Protocol | NetBSD sets SELATN3 for ESP100A and later (`MacQuadra800_MiSTer/docs/scsi/netbsd-ncr53c9x-expectations.md:306-320`) | no reselection (`I_RESEL` never raised); SELATN3 accepted, tag bytes dropped; ABORT and BUS DEVICE RESET not honoured; ATN not modelled; no selection timer (`ncr53c96.sv:1245-1465`) | no protocol gain over `ts_esp` (D11 has the same gaps) |
| Chip identity | sun4m reports FAS100A in QEMU (`qemu hw/scsi/esp.c:1282-1288`, `1601`) | no TCHI or chip-ID register; CFG2/CFG3 fully writable (`ncr53c96.sv:350-363`) | each OS's revision probe must be re-checked |

What (b) would buy is register semantics already diffed against QEMU
`esp.c`. The same diff can be applied to `ts_esp` in phase 4.5, for far less.

**(c) The BlueSCSI HPS contract.** The contract keeps the target in the FPGA
and only adds a side channel for the Toolbox vendor commands (0xD0-0xD5, slot
3) and the CD changer (slot 5), see 2.4. So it is not an alternative to (a)
or (b); it is a feature that can sit on top of (a). Toolbox file sharing
would need a Sun-side client, and none exists for SunOS/Solaris *(inference)*,
so its value here is the CD changer at most. Reserving slots 3 and 5 keeps
the option (question 2). A *full* ARM-side target, like Main's
`ide_cdrom.cpp` for ATAPI, is what the Mac and NeXT work chose not to do for
disk data.

### 4.2 Comparison

| | (a) keep ESP, new targets + Mac cache | (b) swap in `ncr53c96` | (c) BlueSCSI contract |
|---|---|---|---|
| Effort | M-L: target engine ~1-1.5k lines of SV, cache reuse, top glue | XL: chip swap, new DMA2 engine, redo DREQ/TC rules, split out the built-in Apple targets, re-validate six OSes | S-M on top of (a): the slot-3/5 channel, plus a Main predicate |
| Risk | low-medium: the ESP and DVMA path the OSes rely on are untouched; the new code is benchable in Verilator | high: every OS boot path changes at once, and the protocol gaps stay (D11) | low, but little value without a Sun-side Toolbox client |
| Reuse from the Mac | `scsi_cache.sv` (near verbatim, as SGIIndy did), mount replay, CONF_STR, eject/PREVENT rules, tb patterns (`tb_scsi_cache.sv`, `sim_blkdevice`) | chip register model only | `mac_toolbox.cpp` if gated for the core |
| Stock Main | yes for disks and flat ISO (2.4) | same | no |
| What the OSes need | everything in 4.4: IDs 3/1/6, 512-byte CD, media change with UNIT ATTENTION, geometry pages, LUN decode; ESP fixes stay a separate phase 4.5 item | same list, plus re-proving the chip | n/a |

### 4.3 Recommendation

**(a).** It changes the half of the path that is broken (D1-D10) and leaves
the half that works (ESP, DMA2, IOMMU; D11 is a phase 4.5 fidelity item). It
takes the most valuable Mac pieces, the cache and the mount and OSD rules,
nearly as they are. It needs no Main change until CUE/CHD and CD audio, and it
can be simulated on this box with Verilator. It matches the direction the Mac
and NeXT work has taken (2.4): the data path in RTL, and Main only for
responses and image formats where it pays off. Note that the Mac targets are
*not* a feature reference for a Sun target (no UNIT ATTENTION, no range check,
no LUN decode, no write protect, Apple CD dialect). The Sun engine takes the
Mac's structure and cache and follows SCSI-2 and QEMU's `scsi-disk` for
behaviour.

### 4.4 The new target engine (`rtl/sun4m/scsi_targets.sv`, proposed)

- **Interface.** The record bus flattened to ports (VHDL cannot pass records
  into Verilog): `i_d, i_ack, i_bsy, i_atn, i_did, i_rst` in; `t_d, t_req,
  t_phase, t_sel, t_pc` out. A thin VHDL wrapper in `ss_core.vhd` keeps
  `type_scsi_w/r` for `ts_esp` and `dl_scsi`. Engine side of `scsi_cache`:
  `e_lba, e_blk_cnt, e_rd[2:0], e_wr[2:0], e_ack, e_buff_*`.
- **Personalities and IDs.** Up to three targets (HD0, HD1, CD), each with an
  OSD ID. Proposed defaults follow Sun: HD0 = 3, HD1 = 1, CD = 6 (SS5
  service manual App. C). Duplicate IDs: the lower slot wins. ID 7 is the
  host. **A target answers selection only while its image is mounted**
  (fixes D3). The CD answers without a disc, reporting NOT READY, like a real
  drive; that is what OBP `probe-scsi` shows as "Removable Read Only device".
- **Messages.** Accept IDENTIFY (honour the LUN, answer other LUNs by the
  SCSI-2 rules), answer SDTR with offset 0 (asynchronous, since `ts_esp`
  ignores sync, D11), reject WDTR and unknown extended messages with MESSAGE
  REJECT, implement ABORT and BUS DEVICE RESET, and never disconnect. INQUIRY
  must then stop advertising Sync (D10).
- **Disk commands.** TUR, REZERO, REQUEST SENSE (fixed format with key, ASC,
  ASCQ), FORMAT UNIT (no-op), REASSIGN BLOCKS (no-op), READ/WRITE(6/10/12),
  SEEK(6/10), INQUIRY (SCSI-2, vendor string per question 5), MODE SELECT(6/10)
  (accepted and ignored, as the Mac does since `7108f5f`), MODE SENSE(6/10)
  with pages 1, 3, 4, 8 and `3Fh` (3 and 4 carry a synthetic geometry for
  Solaris `format`), RESERVE/RELEASE, SEND DIAGNOSTIC, READ CAPACITY, VERIFY,
  SYNCHRONIZE CACHE. Bounds: start + count ≤ blocks, the last LBA included
  (fixes D7). Read-only: WP bit in MODE SENSE, DATA PROTECT on writes (D6).
- **CD commands.** The disk set minus writes, plus READ TOC formats 0 and 1
  (a one-track TOC synthesised from the image size for flat ISOs), READ
  HEADER, READ SUB-CHANNEL (no audio), PLAY AUDIO answered with ILLEGAL
  REQUEST until the audio phase, START STOP with LoEj, PREVENT/ALLOW.
  **Block size 512 or 2048**: the power-up size comes from the OSD (Sun's
  CD-ROM drives run at 512 and the core's OSD already offers 512, D1). A MODE
  SELECT block descriptor may switch between 512 and 2048, as QEMU's
  `scsi-disk` allows (`qemu hw/scsi/scsi-disk.c:1676-1690`); READ CAPACITY and
  MODE SENSE report the current size. This is the deliberate difference from
  the Mac, which refuses the switch (2.3).
- **Media state and sense.** On a mount pulse with size > 0: present, UNIT
  ATTENTION 28h/00 (medium changed). On size 0 or LoEj: NOT READY 3Ah/00.
  After a bus reset or machine reset: UNIT ATTENTION 29h/00 once per target.
  Eject lasts until the next mount pulse (the Mac keeps it until bus reset,
  `cd9deb8`, so that the ROM can boot from the disc; check OBP's CD boot, which
  may send STOP UNIT, before choosing).
- **Data path.** Engine → `scsi_cache` → `hps_io`. The engine keeps a
  512-byte staging buffer per direction; for 2048-byte CD blocks it scales
  LBA × 4 and count × 4, as the Mac does. Throughput goal: back-to-back cache
  hits at the ESP's handshake rate *(inference: 2-4 cycles per byte, over
  15 MB/s at 65 MHz, above what a real ESP100A does)*.
- **Top glue.** `hps_io` gets VDNUM 5 (question 2 has the slot layout), the
  full 13-bit `sd_buff_addr`, `sd_blk_cnt` from the cache, and per-slot
  `sd_rd`/`sd_wr` assigns (pitfall 1). SS already latches mounts outside
  reset (`ss_core.vhd:510-529`); keep that, but on each reset release
  re-deliver the mount state to the engine as the Mac does, because the
  engine's sense and UA state is reset-gated.

### 4.5 Phased plan

Each step is one session and ends with a test. Hardware steps need the
user's build machine (there is no Quartus on this box).

| Step | Work | Test |
|---|---|---|
| **S0** (with phase 3, step 3) | Remove Direct SD: `i_scsi_sd`, the SDIO ports, `sd_reg_*` (AUXIO0 +0x18/+0x1C read 0), `swconf(0) = 0`. Replace the SCSI menu by presence per mount. Give the CD option a real `[5:4]` range (D1). Change `S0/S1/S2` to `SC0/SC1/SC2` (D2). Keep the old targets for now | A&S of both revisions. Hardware: OpenBIOS `probe-scsi` shows HD at t0 and CD at t6; the CD "512" option now reaches `ssize`; an existing NetBSD and Solaris image still boots; a second disk appears at t1 |
| **S1** | Simulation harness: install GHDL (needs the user; phase 6 needs it anyway), convert `ts_esp.vhd` and the generated `scsi_mist*.vhd` with `ghdl synth --out=verilog`, and drive them from Verilator with an initiator BFM that does what OpenBIOS and NetBSD do (SELATN + DMA TI + ICCS + MSGACC, SELATNS + SDTR). Port the Mac's `sim_blkdevice` model | golden traces of today's targets: INQUIRY, READ CAPACITY, READ(10) of 64 blocks, WRITE(10), CD READ at 2048 and 512 |
| **S2** | `scsi_targets.sv`, disk personality, messages, sense, bounds, read-only, IDs from ports | the S1 BFM against the new engine: every disk command, SDTR answered async, UA after reset, a phantom-free empty slot, last-LBA read, DATA PROTECT |
| **S3** | Take the Mac's `scsi_cache.sv` (3 slots; drop the `LBA >= 0x40000000` pass-through, or keep it for step S6); VDNUM 5, 13-bit `sd_buff_addr`, `sd_blk_cnt` | the Mac's `tb_scsi_cache.sv` adapted (random reads and writes against a mirror, re-base with dirty data, same-size replay); a 1 MB sequential read counts ≤ 20 platform transactions |
| **S4** | Wire into `ss_core.vhd` (VHDL wrapper, record flattening), OSD IDs (HD0/HD1/CD, defaults 3/1/6), delete `scsi_mist*`, `scsimux`, `MUX_SCSI` | sim: BFM through `ts_esp` into the new engine and the cache. Hardware: `probe-scsi` lists t3, t1, t6 with the new INQUIRY strings; **NetBSD boots from HD at t3**; **Solaris 2.x boots from HD at t3** (an image installed at t3, or HD0 ID set to 0 for existing t0 images) |
| **S5** | CD personality: 512/2048 with MODE SELECT, READ TOC 0/1, NOT READY / UA / eject, PREVENT | sim: the swap sequence (mount, UA 28h, read, unmount, NOT READY 3Ah, mount another size, UA). Hardware: **Solaris install from CD, swapping to "Software 2 of 2"** mid-install; NetBSD install from ISO; OpenBIOS `boot cdrom` |
| **S6** (optional, Main) | CUE/BIN/CHD and CD audio: the Main change in section 5; in RTL, TOC from the blob and a CD-DA frame fetcher with an explicit channel owner (pitfall 6), mixed into the audio out (SS5) | Solaris `audioplay`-free test: `cdplayer`/`workman` or NetBSD `cdplay` on a mixed-mode CHD; the Mac's `ToneTest.cue` generator (`scripts/make_tonedisc.py`) as the listening disc |
| **S7** (optional) | NVRAM persistence on slot 2 (`SC2,NVR,…`, MacLC's pattern), HARDWARE_GAPS #5 | `eeprom`/`setenv` survives a core reload |

Regression gate for the release after S4/S5: OpenBIOS `probe-scsi`; NetBSD
and Solaris boot from t3; SunOS 4.1.4 boot *(where an image exists)*; Linux
and NeXTSTEP boots as today; a Solaris CD install with a media swap; a
multi-GB file copy with `cmp` afterwards (the write-behind path); a clean
shutdown followed by a core reload with the image intact.

---

## 5. Main_MiSTer changes

- **S0-S5: none.** The disks and flat ISO images use the generic path, which
  honours `sd_blk_cnt` up to 16 KB per request (2.4,
  `user_io.cpp:3254-3269`). Keep `sd_blk_cnt ≤ 7`, as the Mac and SGIIndy
  do, so a request stays inside Main's 16 KB slot buffer and its read-ahead.
- **S6 (CUE/BIN/CHD, CD audio): a Main change is needed**, because stock Main
  serves a CD slot only as a flat file. Following the upstream pattern (one
  family directory per core, gated by name, no new UIO opcodes):
  1. `support/sparc/sparc.cpp/.h`: `is_sparc()` on the core name
     `SunSparcStation`, plus mount, unmount and sector-service hooks called
     from `user_io.cpp` next to `mac_mount_hook` / `mac_sd_service` (`:2204`,
     `:3330`) and the NeXT ones;
  2. the CD image layer: call into, or copy, `mac_cdrom.cpp`'s CUE/CHD/raw
     readers, the `MCDA` blob at `0x7FFF0000` and the CD-DA window at
     `0x40000000 + lba`. Copying is what NeXT did; a shared
     `support/scsicd/` would be cleaner but touches three families
     (question 3);
  3. the 512-byte logical block option: the data window must serve
     2048-byte sectors at 512-byte granularity, which the Mac layer already
     does, since its HPS blocks are 512 bytes;
  4. **none** of the Apple-dialect response windows (`0x7E…`, `0x7D…`,
     `0x7C…`). The Sun CD answers INQUIRY, MODE SENSE and READ TOC in RTL
     from the blob, and plays audio from the raw-frame window: the older
     "blob plus raw frames" contract (`docs/cdrom.md`: "the other Mac cores
     … see the old blob / raw-audio windows unchanged");
  5. mind `mac_sd_service`'s 4 KB limit (`mac.cpp:112-113`) if any code is
     shared: the SS cache's 8-block CD groups (4 KB) fit, larger ones would
     not.
- **Before starting S6, update the local checkout.** `../Main_MiSTer` is at
  `915ca33` and has none of #1321, #1327 or the fork branches.
- **HPS Ethernet** (HARDWARE_GAPS #1) is a separate Main change and does not
  interact with this design.
---

## 6. Open questions for the user

1. **Responses on the ARM, as NeXT does?** NeXT (#1327) serves even the
   disks' INQUIRY, READ CAPACITY and MODE SENSE from Main. This design keeps
   all responses in RTL, so that stock Main is enough for S0-S5. Is that the
   trade-off you want, or should the Sun core follow NeXT and make its disk
   identity and mode pages Main's job from the start (smaller RTL, but it
   needs a Main at or after the new family code)?
2. **Slot layout.** Keep 0 = HD, 1 = HD2, 2 = CD, or adopt the Mac family
   layout (0/1 disks, 2 NVRAM, 3 and 5 reserved for Toolbox and changer,
   4 CD), so a future `support/sparc/` can copy the Mac code unchanged?
   Either way the release breaks saved `config/*.s2` files, as the rename does
   already.
3. **Main work for S6**: an upstream PR with its own `support/sparc/` (the
   NeXT pattern: copy the CD code), or first factor `mac_cdrom.cpp` into a
   shared module?
4. **Default IDs.** Sun's 3/1/6, or 0/1/6 for images installed on today's
   core or in QEMU (both put the disk at t0)? Solaris records the target in
   `/etc/vfstab` and `boot-device`, so a t0 image must stay at t0. Proposal:
   defaults 3/1/6, an OSD ID per slot, and a line in the release notes. The
   rename to `games/SunSparcStation/` already forces users to act.
5. **Identity strings.** Keep "TACUS … MISTER", or present Sun-branded drive
   identities (for example a Toshiba `XM-4101TASUNSLCD`-style CD string)?
   Some SunOS/Solaris CD paths may key on vendor strings *(not verified)*.
6. **Two disks or more?** The engine can serve four or more IDs for the cost
   of VD slots and cache sectors. Is two enough?
7. **OpenBIOS changes.** The `ss_openbios` fork builds its `disk`/`cdrom`
   aliases and SD-card handling around today's IDs and `swconf`. Is changing
   it (default `boot-device` at t3, the SD code removed) in scope for this
   work? That source was not available on this machine.
8. **CD audio priority.** Is S6 wanted (it needs Main work and an audio mix
   on SS5; SS20 has no audio path, HARDWARE_GAPS #10), or is data-only CD
   enough?
9. **GHDL.** May a VHDL simulator (GHDL, which can also emit Verilog for
   Verilator) be installed? S1 depends on it.
