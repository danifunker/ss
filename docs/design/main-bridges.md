# Stage 4 research: Ethernet and SCSI through Main_MiSTer (Mac and NeXT models)

Date: 2026-10-02 (session 7). Read-only research, the input for Stage 4
(REWORK.md) and the revision of [scsi-hps.md](scsi-hps.md). The fetched
copies it cites under `scratchpad/` were working files of that session and
are not kept; the PRs and repositories they came from are named below.

**Status:** SCSI waits for the user's Mac-side PR (#1336) and follows the
NeXT or the Mac model (user, 2026-10-02). The Main reviewer accepts a
core's Main changes once the core is in MiSTer-devel (or about to be),
which needs the licence confirmation (REWORK phase 0).

## Sources and how they were read

- **Main_MiSTer upstream master `57276f0`** (2026-10-01, "Change user_io_status_set value in
  video.cpp (#1335)"), files fetched read-only with `gh api` into
  `scratchpad/upstream/`. "Main `file:line`" below means that revision.
- **Local `/home/dani/repos/Main_MiSTer`** is at `915ca33` (2026-08-28), behind master: it has
  #1255 (Mac CD/Toolbox) and the Minimig A2065 Ethernet, but not #1304/#1321/#1327/#1329/#1336.
  "local Main `file:line`" means that checkout (A2065 files are unchanged upstream).
- **PR diffs** `gh pr diff N` for #1255, #1304, #1321, #1327, #1329, #1336, split per file in
  `scratchpad/prs/split/`. "PR#N `file`" cites the file as the PR adds it.
- **NeXT core:** no source on this machine (only `/home/dani/NextOSROMS`, `/home/dani/nextstep-test`).
  It is public as **`MiSTer-devel/NeXT_MiSTer`** (HEAD `bdf086b`, 2026-09-26); key files fetched
  read-only into `scratchpad/next/` (`NeXT.sv`, `rtl/next/next_scsi.sv`, `next_enet_bridge.sv`,
  `docs/HPS_SCSI_MO.md`, `SCSI_TI.md`, `SCSI_DMA.md`, `NETWORK_SERVER_PLAN.md`,
  `BLUESCSI_TOOLBOX.md`). `danifunker/NeXT-Color_MiSTer` also exists (not read).
- **Mac cores:** `MacQuadra800_MiSTer` (main `6c8bfe9`): `rtl/sonic_mbx.sv`, `rtl/ncr53c96.sv`,
  `MacQuadra800.sv`, RESUME notes. `MacLC_MiSTer`: Ethernet is only on branches
  (`origin/pds-enet-icache-fix`, `origin/cpu-icache`: `rtl/pds/pds_enet.sv`,
  `docs/port_enet_to_nubus_cores.md`), read with `git show`, no checkout.
  `MacIIvi_MiSTer` and `lbmactwo_MiSTer` have no Ethernet RTL. #1321 removed both from Main's
  Mac family list.
- **Kernel:** local `Linux-Kernel_MiSTer` branch `MiSTer-v5.15` at `5fcfae369` (2026-07-24).
- **Labels:** an unmarked claim was read in the cited place. *(inference)* marks my conclusion.

---

## 1. Ethernet bridging in Main

Main has three Ethernet designs. They differ in where the network chip model runs.

| | Minimig A2065 (Am7990 LANCE) | Mac (SONIC DP83932: LC PDS card, Quadra 800 built-in) | NeXT (MB8795) |
|---|---|---|---|
| Chip model | **ARM** (`support/minimig/minimig_a2065_registers.cpp`, `_rings.cpp`) | **ARM** (`support/mac/mac_sonic.cpp`, PR#1321) | **FPGA** (`rtl/next/next_enet_dma.sv`) |
| What crosses | LANCE register writes, CSR shadow, INT line, and the whole 32 KB card RAM (shared in DDR3) | register writes (doorbell ring), register shadow, ISR bits, MAC PROM, and **DMA-RPC** ops that make the FPGA copy guest RAM to and from a DDR3 staging area | **raw Ethernet frames only**, plus the guest MAC |
| Main files | `support/minimig/minimig_a2065*.cpp` | `support/mac/mac_eth.cpp`, `mac_eth_q8.cpp`, `mac_eth_iface.cpp`, `mac_sonic.cpp` | `support/next/next_enet.cpp` (255 lines) |
| Host network layer | `minimig_a2065_ethernet.cpp` | its own `mac_eth_iface.cpp` | **reuses the A2065 layer** (`extern ethernet_open/...`, PR#1304 `next_enet.cpp:24-31`) |

### 1.1 Transport between FPGA and ARM

None of the three uses hps_io/UIO commands or an interrupt. All of them use a **DDR3 shared-memory
mailbox at ARM physical `0x1FF00000`**, which the FPGA reaches as Avalon 64-bit word address
`29'h03FE0000`:

- Main maps the mailbox with `shmem_map()`, which mmaps `/dev/mem` opened `O_RDWR|O_SYNC`
  (local Main `shmem.cpp:18-30`).
- **NeXT layout** (PR#1304 `next_enet.cpp:3-12`; FPGA twin `next_enet_bridge.sv:12-29`):
  - `+0x00` MAGIC `"NXTETH01"`
  - `+0x08` TX_WPTR (written by the FPGA)
  - `+0x10` RX_WPTR (written by the ARM)
  - `+0x18` RX_RPTR (written by the FPGA)
  - `+0x20` GUEST_MAC (bit 63 = valid)
  - `+0x800` TX slots and `+0x2800` RX slots, **4 × 2048 bytes** each. A slot is a u64 length
    header (`[10:0]`) followed by the frame bytes, little-endian, from `+8`.
- **Polling on both sides.**
  - Main calls `next_enet_poll()` on every `user_io_poll` pass (Main `user_io.cpp:3346`).
    The call returns at once unless the bridge was started and MAGIC is valid
    (`next_enet.cpp:177-181`).
  - The FPGA reads RX_WPTR about every 200 µs (`next_enet_bridge.sv:72-76`).
  - Main is a single-threaded busy loop pinned to CPU 1 (local Main `main.cpp`). The A2065 header
    says a thread would compete for that one CPU (local Main `minimig_a2065.cpp:443-446`).
- **Flow control.**
  - TX never blocks the FPGA: a stale TX frame is overwritten. Main resyncs when it falls more
    than 4 frames behind (`next_enet.cpp:213-225`).
  - RX respects RX_RPTR. Main drains the socket dry on every pass and **drops frames when the
    ring is full** (`next_enet.cpp:227-253`). The comment there gives the reason: stale broadcasts
    queued in the kernel broke the NeXT ROM's Ethernet self-test on a live LAN.
- **Frame size.** `MAX_FRAME 1600` in Main (`next_enet.cpp:55`). The FPGA drops a length of 0 or
  above 1600 (`next_enet_bridge.sv`, `S_RX_HDR`). The Mac code reads into 2048 bytes and warns
  about frames above 1518, the sign of GRO leaking (PR#1321 `mac_eth.cpp:670-678`).
- **Mac mailbox.** Same base address, larger windows:
  - LC window 0x21000 bytes: XFER, declROM, CTRL. Quadra window 0x5000 bytes, 16 KB XFER
    (PR#1321 `mac_eth.h:11-46`; `sonic_mbx.sv:28-58`).
  - The FPGA posts register writes into a 256-entry doorbell ring.
  - The ARM posts up to 8 DMA ops `{dir, addr, len}` and **spin-waits** for the FPGA's sequence
    echo: busy for up to 1.5 ms, then `usleep(50)`, with a 250 ms timeout
    (PR#1321 `mac_eth_q8.cpp:50-98`; LC: `mac_eth.cpp:137-182`).
  - Measured on the Quadra: **62.6 KB/s download, 227 KB/s upload**
    (`MacQuadra800_MiSTer/RESUME-ethernet-20260919.md:90,96-97`).
- **The window is shared by convention.** A2065, NeXT and Mac all use `0x1FF00000`; only one core
  is ever loaded (`next_enet.cpp:3-5`). Main also uses `0x1FFFF000` for its own 4 KB
  (local Main `fpga_io.cpp:397`, `user_io.cpp:1331`), so a window must stay below that.
  The MacLC porting guide adds: give each layout its own MAGIC value and a geometry/version word
  so a stale host and FPGA never half-pair (`port_enet_to_nubus_cores.md`, delta 5).
  *(inference)* The `0x1FF00000-0x1FFFFFFF` megabyte is outside Linux's RAM on MiSTer. I did not
  find the reservation in the DTS: `memory reg` is the full 1 GB, and `bootargs` has no `mem=`.
  The evidence is that three shipped features rely on it.

### 1.2 How Main connects to the network

These are the modes of the A2065 layer that NeXT reuses (local Main `minimig_a2065.h:17-37`,
`minimig_a2065_ethernet.cpp`; PR#1304 `next_enet.cpp:99-140`):

| mode (status `[54:52]`) | mechanism | MAC handling |
|---|---|---|
| 0 Off | the bridge still consumes the guest's TX frames (`next_enet.cpp:206-211`) | – |
| 1 eth0 (shared) | `AF_PACKET` raw socket, **promiscuous**, plus an 11-instruction **cBPF filter**: dst == guest MAC or broadcast; drops multicast and the host's own outgoing frames (`minimig_a2065_ethernet.cpp:249-312`) | the filter follows GUEST_MAC from the FPGA |
| 2 eth1 (dedicated NIC) | raw socket, **not** promiscuous | A2065 rewrites eth1's MAC to the Amiga MAC; **NeXT does not** *(inference: so NeXT eth1 only receives broadcasts and frames sent to eth1's own MAC)* |
| 3 macvlan | `ip link add next0 link eth0 address <guest MAC> type macvlan mode bridge` (shell-out) | needs the guest MAC first (`next_enet.cpp:113-117`) |
| 4 tap0 | `/dev/net/tun`, `IFF_TAP\|IFF_NO_PI`, interface brought up | the guest MAC is used as-is |

What Main does and does not do:

- **No bridge, no NAT, no slirp in Main.**
  - tap0 gets no IP address and no routes from Main.
  - The kernel config has `CONFIG_TUN=y` (#76), `CONFIG_MACVLAN=y` (#71), `# CONFIG_BRIDGE is not
    set`, `# CONFIG_NF_NAT is not set`, `# CONFIG_IP_NF_NAT is not set`, `# CONFIG_BPF_JIT is not
    set` (`arch/arm/configs/MiSTer_defconfig:94,785,849,937-945,960,1302,1310`).
  - So tap0 means the user routes it by hand. The A2065 header says tap covers "local-only access
    between the Amiga and the MiSTer" and Wi-Fi, because a Wi-Fi station cannot send frames with a
    second source MAC (`minimig_a2065.h:26-31`).
  - *(inference)* Main never calls `TUNSETPERSIST`, so tap0 and any address the user put on it
    disappear when the bridge closes (core change, mode change).
- A user-space NAT (Previous's slirp in a helper process) is only a **proposal** for NeXT
  (`docs/NETWORK_SERVER_PLAN.md`, "Status: proposed").
- `a2065_mode_available()` probes `/dev/net/tun`, eth1 presence and macvlan (by creating and
  deleting a probe link once). An unavailable mode becomes Off
  (local Main `minimig_a2065.cpp:104-130`). NeXT uses it too (`next_enet.cpp:170-176`).
- **Mac (PR#1321) has its own network layer**: a promiscuous raw socket with GRO turned off,
  including on the parent interfaces through `lower_*`, or a tap
  (`mac_eth_iface.cpp:60-137`).
  - LC: OSD `[37:36]` picks eth0, tap0, `macvlan` or eth1; `[35:32]` is a MAC suffix. An `eth.cfg`
    in the core's home folder can override `iface=`, `mac=`, `macbyte=`, `addrbits=`
    (`mac_eth.cpp:48-135`).
  - Quadra: `[6]` enable, `[8:7]` picks eth0, eth1, wlan0 or tap0.
  - The guest MAC is `08:00:07:4D:<core>:<suffix>`; the Quadra takes the low three bytes from the
    host NIC.
  - *(inference)* The LC's "macvlan" choice opens an interface literally named `macvlan` that the
    user must create.
- **Configuration is OSD status bits only.** There is no MiSTer.ini key for networking. The NeXT
  OSD line is `"O[54:52],Network,Off,eth0,eth1,macvlan,tap0;"` and
  `"O[58],Ethernet cable,Connected,Disconnected;"` (`NeXT.sv:78-79`).
- **Gotchas the A2065 and Mac handle and NeXT does not** *(inference)*:
  - turning GRO/offload off on shared NICs (`minimig_a2065.cpp:372-398`);
  - the dhcpcd `denyinterfaces` entry for the macvlan child.
  With GRO on, a super-frame would reach the guest truncated to 1600 bytes.
  - The cBPF filter drops multicast, so a guest multicast group never works in eth0 mode
    (`minimig_a2065_ethernet.cpp:258-266`). NeXT has no PROM-mode filter detach; the A2065 has one.

### 1.3 What the NeXT core-side RTL implements (the template for SPARC)

These are `next_enet_bridge.sv` and `NeXT.sv:402-525`:

- **A DDR3 master sharing DDRAM with guest RAM** through a small arbiter (`next_ddram_arb.sv`).
  It does single 64-bit beats with no bursts, to word address `0x03FE0000 + n`.
- **Reset sequence:** clear MAGIC, zero TX_WPTR, RX_WPTR and RX_RPTR, write the MAC, write MAGIC
  last. "Clear any mailbox generation left by the preceding core" (`next_enet_bridge.sv` reset and
  `S_INIT_*`).
- **TX:** stream the frame from the MAC's buffer into slot `tx_wptr[1:0]`, write the header, bump
  TX_WPTR, pulse `btx_done`. With the bridge disabled it completes one pending TX so the MAC does
  not wedge (`S_OFF`).
- **RX:** every 200 µs read RX_WPTR. If it differs from RX_RPTR and the MAC is ready, read the
  header, stream the bytes, bump RX_RPTR.
- **Republish GUEST_MAC** when the MB8795 NodeID registers change.
- **Enable** = `|status[54:52] && !status[58]` (`NeXT.sv:95`).

### 1.4 Can SPARC (LANCE Am7990 with DMA through the IOMMU) reuse it?

**The NeXT frame mailbox fits; the Mac and A2065 chip-on-ARM models do not.**

- The SS core already has the LANCE descriptor engine and DMA in the FPGA:
  - `rtl/sun4m/ts_lance.vhd` has a plomb master `pw/pr` through the IOMMU.
  - It has a clean MAC boundary: `type_mac_emi_w/r` (TX: 16-bit words, `stp/enp/len/crcgen`) and
    `type_mac_rec_w/r` (RX: `d/deof/len/eof/crcok`; `padr/ladrf` go to the MAC)
    (`rtl/sun4m/ts_pack.vhd:48-78`).
  - Today it ends in `ts_lance_mac_void.vhd` or `ts_lance_mac_rmii*.vhd`.
  - A `ts_lance_mac_hps` adapter on that boundary is the same shape as NeXT's `btx_*/brx_*`
    streams *(inference)*.
- A chip-on-ARM LANCE (the A2065 port) would need the ARM to walk descriptor rings at **DVMA
  addresses**. Every access would need IOMMU translation and cache-coherent DMA into guest RAM,
  which is exactly what `ts_lance` already does in hardware. Mac's DMA-RPC reaches only 62-227 KB/s
  even without an IOMMU *(inference)*.
- **Address-map check:**
  - The SS core forces DDRAM addresses to `"001" & ...` (0x2000_0000 to 0x3FFF_FFFF)
    (`rtl/mister/ss_core.vhd:757-765`). SS20 guest RAM is `512-32-16` MB (`ss_core.vhd:160`).
  - So `0x1FF00000` does not collide with guest RAM.
  - But the mailbox client needs its own unforced 29-bit address into `rtl/mister/ddram_arb.sv`.
    That arbiter is 2-port today (m0 video, m1 CPU). Port 3, or a mux in front of m1 *(inference)*.

**What the SPARC RTL would have to add** *(inference, modelled on NeXT)*:

1. Port `next_enet_bridge.sv` with a third DDRAM client.
2. `ts_lance_mac_hps`:
   - TX: pack emi words into a 2 KB buffer and drop CRC generation (Linux adds the FCS).
   - RX:
     - **append a 4-byte FCS**: the Am7990 writes it into the receive buffer and drivers subtract
       it. The A2065's ARM LANCE does this (`minimig_a2065_rings.cpp:306-310`). Sun `le` drivers
       are assumed to behave the same, which is the inference.
     - assert `crcok`.
     - **filter by PADR, LADRF and PROM in the FPGA.** Main filters only in eth0 mode, and drops
       all multicast there. The A2065 filter is the reference (`minimig_a2065_rings.cpp:268-298`).
3. Publish the LANCE's PADR as GUEST_MAC. PADR is the station address the OS loaded from the
   IDPROM; the NVRAM IDPROM work in `c6c45eb` makes it unique.
4. OSD `"O[54:52],Network,Off,eth0,eth1,macvlan,tap0;"`. Bits 54:52 are free in
   `SunSparcStation.sv:75-101`.

**Main changes for SPARC Ethernet:**

- **Minimum:** the SS core speaks the identical `NXTETH01` protocol, and Main arms the existing
  daemon for it: `if (is_next() || is_sparc()) next_enet_start();` (Main `user_io.cpp:1628`).
  `next_enet_poll()` is already called for every core (`:3346`) and the stop is unconditional
  (`:1467`). The macvlan child would still be named `next0`.
- **Cleaner, and in line with sorgelig's review rules:** a `support/sparc/` module with
  `sparc_enet_*` and its own MAGIC, or a generalised shared frame bridge. Rule source: #1255
  comment, "Core specific functions should reside in support code, not in user_io".
- **Deeper rings need a Main change:** `NB_RING 4` is a compile-time constant
  (`next_enet.cpp:46`). The 64 KB window has room for about 15 slots per direction.

## 2. SCSI in Main: NeXT vs Mac

### 2.1 Where things live

In **both** models the SCSI chip, the bus phases and the target state machines are in the **FPGA**.
Main never sees a SCSI phase. It does three things:

- (a) serves sector data through the ordinary hps_io block channel;
- (b) builds selected **response payloads** that the RTL fetches by reading a "magic" LBA;
- (c) takes forwarded commands that the RTL writes to a magic LBA.

All of it is ordinary `UIO_GET_SDSTAT`/`UIO_SECTOR_RD`/`UIO_SECTOR_WR` traffic, polled by Main
(Main `user_io.cpp:3375-3500`). There is no new UIO opcode, no interrupt and no DDR buffer.

| | **NeXT** (`MiSTer-devel/NeXT_MiSTer` + Main `support/next/`, #1327/#1329) | **Mac** (Quadra 800 `ncr53c96.sv` + `scsi_cache.sv`; MacLC/MacPlus `ncr5380.sv` + `scsi.v`; Main `support/mac/`, #1255/#1321/#1336) |
|---|---|---|
| Chip | **NCR53C90 "ESP"** + NeXT DMA bus-master + target engine in one module `next_scsi.sv` (2283 lines), "modeled after esp.c, scsi.c and dma.c of the Previous emulator" (`next_scsi.sv:1-28`) | 53C96 register/FIFO model with 3 targets folded in; **CPU pseudo-DMA** (the Quadra has no bus-master SCSI DMA) |
| Responses from Main | **every unit**: INQUIRY (LUN≠0 → qualifier `0x7F`), READ CAPACITY, MODE SENSE pages 0/1/3/4/3F (+0E/2A for CD), READ TOC, READ SUB-CHANNEL (Main `next_scsi.cpp` via PR#1327 `next_scsi.cpp:53-177`) | **CD-ROM only**, Quadra only (`is_mac_scsi_optimized()`): INQUIRY, MODE SENSE, TOC 43/C1, SUB-CHANNEL, Apple C2/CC (PR#1321 `mac_cdrom.cpp` `mac_cdrom_window_fill`). Disk responses stay in RTL |
| Response window | read 1 block at `0x7E000000\|unit<<20\|flags<<16\|op<<8\|a` on the **CD slot (3)**; length big-endian at bytes 510-511 (`HPS_SCSI_MO.md`, Windows) | `0x7E000000 + op<<16 + a<<8 + b` on the CD slot (4), no unit field (`ncr53c96.sv:467-482`) |
| Command window | write `0x7D000000\|unit<<20\|op<<8`, CDB at bytes 496-505, MODE SELECT list at 0 | `0x7D000000 + op<<16`, CDB at 496 |
| CD audio | frame window `0x7C000000`, 5 blocks (2352 PCM + state/flush gen); playhead on the ARM | same windows + older `MCDA` TOC blob `0x7FFF0000` and raw CD-DA at `0x40000000+lba` (blksz 2352) (Main `support/mac/mac_cdrom.h`) |
| REQUEST SENSE, READ/WRITE | RTL (`HPS_SCSI_MO.md`: "the sense is the engine's own state") | RTL |
| CD images | CUE (multi-FILE, pregap), CHD, raw 2048/2352/2336; **all** translated by Main and served as **512-byte LBAs** of the 2048-byte data track (PR#1327 `next_cdrom.cpp:336-437`); `f->size = sectors*2048` | CUE/CHD/raw-2352 translated; **flat ISO/TOAST passes through** the generic path (Main `mac.cpp:45-63`); CD block size 2048 only, MODE SELECT to 512 refused |
| Block cache | **none**; disks `sd_blk_cnt = 0`, one 512-byte request per sector (`NeXT.sv:174`); relies on Main's 16 KB read-ahead | **`scsi_cache.sv`** (Quadra): per-slot LBA window, 8-sector groups, read-ahead + write-behind, multi-block HPS requests (`docs/design/scsi-hps.md` 2.3) |
| Targets / slots | IDs 0, 1, 3 (CD) = hps_io slots 0, 1, 3; `has_unit = t<4 && t!=2`; host ID 7 (`next_scsi.sv:173-188`, `next_system.sv:1182` `CD_UNITS=6'b001000`); Main `NEXT_SCSI_UNITS 4`, `NEXT_CDROM_SLOT 3`, `NEXT_MO_SLOT 5` | ID 0 = slot 0, ID 1 = slot 1, ID 3 CD = slot 4; Toolbox slot 3, CD changer slot 5 (Main `mac.cpp:31-43`, `mac_cdrom.h:9`) |
| Without the matching Main | **hard failure**: INQUIRY gets CHECK CONDITION, no disks (`HPS_SCSI_MO.md`, Testing) | disks work; the CD target does not answer selection until the INQUIRY-window **capability probe** sets `cd_hps_ok` (`ncr53c96.sv:505-511,814`) |
| Extras | MO Reed-Solomon ECC offloaded (`next_mo.cpp`, `next_rs.cpp`) | BlueSCSI Toolbox file sharing and CD changer (slots 3/5), boot repulse, #1336 write buffer |

### 2.2 Fast mac scsi (#1336, open)

As of PR HEAD `bf0ae73` (2026-10-02) it adds `support/mac/mac_disk.cpp`:

- **What it does:** a write-behind buffer for **hard-disk slots 0-1 of Mac-family cores**:
  - Writes are acknowledged immediately and gathered into contiguous runs: up to 64 KB, 8 runs per
    slot.
  - A run is flushed on 20 ms idle, 500 ms age, a full run, an overlapping read, or a remount.
  - A remounted image is still written by path, with a dev/inode check (`mac_disk.cpp:20-209`).
  - It is hooked only through `mac_sd_service`, `mac_poll` and `mac_mount_hook`. `user_io.cpp`
    only passes `&sd_image[disk]` (PR#1336 diff).
- **Why:** images are opened `O_RDWR|O_SYNC` (Main `user_io.cpp:2224`), and the Mac cores write one
  512-byte sector per request, so each costs about 4 ms. Finder copies went from about 250 KB/s to
  about 1 MB/s (PR body and the author's reply to review).
- **The "tight service loop" is gone from the current diff.** It spun on `UIO_GET_SDSTAT` for up to
  250 µs per request (2 ms budget, `MAC_SD_SPIN_US`) and is still described in the PR body.
  - It existed in commit `31688f7`: a sector request arrives about 110 µs after the previous one
    and otherwise waits a whole Main pass.
  - It was removed in `98b4aa6` after sorgelig's review: no core code in `fpga_io`, check the core
    before costly calls, keep the code inside the Mac hooks. He also questioned the purpose.
- **For SPARC:** the buffer is gated `is_mac_scsi_family()`, so SPARC would need its own copy or a
  generalisation. Alternatively, multi-block writes from `scsi_cache.sv` already amortise
  `O_SYNC`: one request carries up to 16 KB *(inference)*.

### 2.3 Which model fits an ESP host adapter driven by Sun OBP, Solaris and NetBSD

Both chip models handle the protocol points that matter:

- **Selection.**
  - NeXT handles SEL, SELATN and SELATNS (0x41/42/43) with partial CDBs continuing through TI, and
    the LUN from IDENTIFY or else CDB byte 1 (`next_scsi.sv:697,741,856-871`, `SCSI_TI.md`).
  - The Quadra 53C96 does the same for A/UX's `c94` driver.
- **Messages.** Both answer an EXTENDED message (SDTR/WDTR) with **MESSAGE REJECT** in MSG IN and
  resume in COMMAND phase. Sun drivers read that as "stay asynchronous"
  (`next_scsi.sv:674-706`; `ncr53c96.sv:36-38,1144-1158`).
- **Disconnect.** Neither disconnects: NeXT implements ENSEL "no reselections" (`next_scsi.sv:891`).

Differences that matter for SPARC:

1. **DMA.** NeXT's ESP feeds its own bus-master DMA channel, which is structurally the sun4m case
   (ESP + DMA2 + IOMMU). The Quadra's 53C96 is CPU pseudo-DMA. But NeXT DMA semantics
   (next/limit, ESPCTRL flush; `SCSI_DMA.md`) are not DMA2, so the SS core keeps
   `ts_esp`/`ts_dmaux` either way. Only the **target engine plus the Main contract** is the real
   choice. This matches the existing design doc (`docs/design/scsi-hps.md` section 1)
   *(inference)*.
2. **Main contract.**
   - The NeXT contract puts INQUIRY, READ CAPACITY and MODE SENSE for every unit in Main.
     - It answers non-zero LUNs with qualifier `0x7F`. The Mac model has no LUN decode, so Solaris
       LUN scans would see ghost units (`scsi-hps.md` 2.3).
     - It already builds pages 3/4 geometry.
     - It serves CD data at 512-byte granularity, which a Sun CD-ROM needs to boot in 512-byte
       mode. The NeXT RTL is 2048-only today and the Mac refuses 512, so the SPARC engine must add
       MODE SELECT block-length switching either way.
   - The Mac contract keeps disk answers in RTL. A Main without the module still boots disks,
     thanks to the capability probe.
3. **Throughput.**
   - NeXT has no block cache and does one sector per request, so writes run at about 4 ms per
     `O_SYNC` sector.
   - The Mac's `scsi_cache.sv` (877 ALMs, 40 M10K per `scsi-hps.md` 2.2) gives multi-block
     transfers and write-behind.
   - The windows coexist with the cache: it passes LBAs ≥ `0x40000000` through.
   - *(inference)* The best fit is the **NeXT-style Main windows (all units, unit field) behind the
     Mac `scsi_cache.sv`**, plus a Mac-style capability probe so a stock Main still boots disks.
4. **IDs vs slots.**
   - Sun convention is disk ID 3 (sd0), ID 1, CD ID 6.
   - The SS slots are 0/1 HD, 2 CDROM, 3 NVRAM (`SunSparcStation.sv:79-83`).
   - NeXT's Main code assumes **target ID == slot**, unit < 4, CD slot 3 (`next_scsi.cpp:15-22,149-154`).
   - So SPARC cannot reuse `next_sd_service` as-is: it needs its own slot constants and an
     ID-to-slot map, either in the engine (put the slot index in the unit field) or in a
     `support/sparc/` module.
   - The generic SCSI-2 builders `next_cd_resp_toc/subch` and the `next_cd_play` playhead are
     reusable code *(inference)*.

## 3. How Main detects the core and what a new core adds

- **Core name.** `user_io_read_core_name()` takes the CONF_STR's first field as `orig_name`;
  `core_name` is the MGL/setname override, if any (Main `user_io.cpp:471-510`).
- **NeXT:** `is_next()` is an exact `strcasecmp(orig_name, "NeXT")`, and since #1329 also
  `"NeXT-Color"` (Main `user_io.cpp:290-294`; declared in `user_io.h:276`).
  `rtc_is_utc()` returns `is_next()` (`:298-301`).
- **Mac:** `is_mac_scsi_family()` is a **prefix** match (`strncasecmp` against `maclc`, `macplus`,
  `macquadra800`) on either name (Main `support/mac/mac.cpp:14-29`). `mac_eth` uses **exact**
  matches on purpose; the porting guide warns that prefix matching collides MacLC and MacLCII
  (`port_enet_to_nubus_cores.md` delta 6).
- **Every hook self-gates on the family:**
  - mount: `mac_mount_hook`, `next_mount_hook` (`user_io.cpp:2280-2281`)
  - unmount: `:2301-2302`
  - sector service chain: `mac_sd_service`, `next_sd_service` (`:3477-3485`)
  - poll: `mac_poll` (`:3304`), `next_enet_poll` (`:3346`), NeXT RTC refresh (`:3353`)
  - init: `next_enet_stop` and `next_enet_start` (`:1467`, `:1628`)
  - includes: `support.h`
- **A SPARC core would add** *(inference, following #1304/#1327)*:
  - `is_sparc()`: exact match on `"SunSparcStation"`, the shared SS5/SS20 name, or a prefix check
    if the machines get split names.
  - `support/sparc/sparc_*.{h,cpp}`: mount hook, sector service, Ethernet start/stop/poll.
  - One line each in the hook sites above and in `support.h`.
  - `rtc_is_utc()` for UNIX guests. Note it only affects `UIO_TIMESTAMP`; the BCD `UIO_RTC` that
    the SS core consumes via `RTC` is always local time (`user_io.cpp:1118-1160`). So a UTC TOD
    needs core or Main work either way.

## 4. Constraints and gotchas from the PRs and code

- **Upstream review rules (sorgelig on #1255 and #1336).** Submit Main changes only when the core is
  in MiSTer-devel or about to be. Minimise common-code changes and put core code in `support/`. No
  core code in `fpga_io`. Gate time-consuming calls on the core.
- **Slot ceiling of 7.** Main announces a mount as one byte, `(1<<index)|(ro?0x80)`
  (Main `user_io.cpp:2363`): slot 7 collides with the read-only bit, and slots 8 and above shift
  out and arrive as slot 0 (`NeXT.sv:104-111`). hps_io allows VDNUM up to 10. The SS core uses 4
  slots today, so it can add at most 3 more.
- **One slot layout per family.** A wrong slot "corrupts another device's sector stream"
  (#1255 body, `mac.cpp:34-37`). Toolbox and changer slots are announced once per session by a
  `UIO_SET_SDSTAT` pulse.
- **Request size and rate.**
  - At most 16 KB per request (`sd_blk_cnt`; Template `sys/hps_io.sv:134`), decoded
    `blks=((c>>9)&0x3F)+1` (Main `:3399`).
  - At most 4 requests per poll pass (`:3375`).
  - 16 KB read-ahead buffer per slot, and the next 16 KB is prefetched when the request reaches the
    buffer's end.
  - Writes are `O_SYNC`.
  - A response window costs about one Main poll each way, 0.1-1 ms (`HPS_SCSI_MO.md`, Timing).
- **Start-order trap (#1304).** `next_enet_start()` must sit before the `else if` core-init chain,
  "or the core skips the boot ROM load" (Main `user_io.cpp:1621-1628`).
- **RX flood (#1304).** Drain the socket every pass and drop when the ring is full, so the guest
  never sees stale broadcasts.
- **Mailbox generation.** The FPGA clears MAGIC first at reset, and Mac Main zeroes both MAGIC
  words once at start (`mac_eth.cpp:608-619`). Use a distinct MAGIC per layout.
- **Kernel requirements.**
  - tap0 needs `CONFIG_TUN`; macvlan needs `CONFIG_MACVLAN`. Both are enabled in the MiSTer kernel
    (#76, #71), and modes are probed and hidden or set Off when absent.
  - There is no bridge or NAT support, so tap0 needs manual routing (address on tap0, forwarding,
    proxy ARP or a LAN route).
  - cBPF is interpreted, not JIT-compiled.
  - Wi-Fi cannot carry a second MAC. macvlan children cannot reach the MiSTer host itself; tap0 is
    the local path (`minimig_a2065.h:26-31`).
- **Offload.** GRO must be off on the bridged NIC, or super-frames reach the guest. Mac and A2065
  do it; NeXT does not *(inference)*.
- **Main's single thread.** Mac DMA-RPC busy-waits up to 1.5 ms (250 ms timeout) inside the poll.
  The NeXT frame bridge never waits. That argues for the frame model for a busy SPARC guest
  *(inference)*.
- **Release coupling.**
  - The NeXT core needs a Main with `support/next`.
  - The Quadra README pointed at a fork branch until #1321 merged.
  - #1329 says the NeXT-Color core waits for the Main binary in update_all.
  - Plan SPARC releases the same way, or add a capability probe.
- **CD boot repulse (#1255).** The early mount pulse can precede the guest driver's init. The Mac
  re-fires the mount after about 60 s. For SPARC, replay the mount after every reset instead
  (`scsi-hps.md` 2.3).
