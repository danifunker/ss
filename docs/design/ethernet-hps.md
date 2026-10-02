# Ethernet through Main: the LANCE's frame mailbox

Session 8 (2026-10-02). The design follows the research in
[main-bridges.md](main-bridges.md) §1: the NeXT model (raw frames cross a
DDR3 mailbox; Main moves them to a socket), not the Mac/A2065 model (the
chip on the ARM). The SPARCstation's LANCE walks its descriptor rings and
DMAs through the IOMMU, which the FPGA already does; only the wire is new.

## Pieces

| where | what |
|---|---|
| `rtl/sun4m/ts_lance.vhd` (from `ts_lance.vhs`) | the Am7990, unchanged but for `prom` on its MAC record |
| `rtl/sun4m/ts_io.vhd`, `ts_core.vhd` | the MAC records (`mac_emi_*`, `mac_rec_*`) are ports now; the RMII MACs (`ts_lance_mac_rmii*`, `_void`) are no longer built |
| `rtl/mister/eth_hps.vhd` | the MAC: 2 KB transmit and receive buffers, the address filter, and the mailbox (an Avalon master on the DDR3, single beats) |
| `rtl/mister/ss_core.vhd` | `ddram3_*` (the mailbox master) and `eth_ena` instead of the RMII pins |
| `SunSparcStation.sv` | a second `ddram_arb` merges the mailbox into the CPU's DDR3 port; OSD System → Network `O[26:24]`: Off, eth0, eth1, macvlan, tap0 |
| Main `support/sparc/sparc_enet.cpp` (branch `sparcstation-enhancements`) | the other side: the A2065 module's host network layer (raw socket with the BPF MAC filter, macvlan, tap) |
| `sim/sim_main.cpp` `--eth`, `--eth-loop` | the mailbox in the DDR model and a stand-in for Main that logs frames and sends them back |
| `tests/cpu/src/ethtest.S`, `sim/run-eth.sh` | the LANCE through the IOMMU: init, a frame looped back, the filter, a 1514-byte frame, MISS |

## The mailbox

ARM physical `0x1FF00000` (Avalon word address `0x03FE0000`), 64-bit
little-endian words; frame byte *i* is byte lane *i* mod 8 of word 1 + *i*/8
of its slot.

| offset | name | written by |
|---|---|---|
| `0x0000` | MAGIC `"SSETH001"` (`0x5353455448303031`) | FPGA, last at start-up |
| `0x0008` | GEN: a new value at every FPGA start-up | FPGA |
| `0x0010` | TX_WPTR | FPGA |
| `0x0018` | TX_RPTR | Main |
| `0x0020` | RX_WPTR | Main |
| `0x0028` | RX_RPTR | FPGA |
| `0x0030` | MAC: bit 63 valid, 47:40 the first byte | FPGA (the LANCE's PADR) |
| `0x1000` | TX ring: 8 slots of 2048 bytes; header bits 10:0 = length | FPGA |
| `0x5000` | RX ring: 8 slots; header 10:0 = length with the FCS, 21:16 = the LADRF index of the destination | Main |

Differences from NeXT's `NXTETH01`: its own magic and a generation word
(Main resynchronises after a core reset); Main returns TX_RPTR, so the FPGA
never overwrites a slot Main has not read (it drops the frame instead, as a
congested wire would); eight slots each way; Main appends the FCS (drivers
subtract four bytes from the LANCE's message count) and computes the
multicast hash index, so the FPGA filters without a CRC unit.

## The MAC side (eth_hps)

- **Transmit.** The LANCE pushes 16-bit words, the first with `stp`.
  `busy` from the first word until the frame is in the mailbox keeps the
  LANCE from starting the next one (a chained frame continues: the LANCE's
  `act_tx_new` takes `busy` with `fifordy`). The frame is complete when its
  bytes reach `len` (cumulative over the chain) with `enp`. With `crcgen`
  off (DTCR, the driver supplied the FCS) the last four bytes are not sent.
- **Receive.** With its buffer empty the bridge polls RX_WPTR every 1024
  cycles (about 19 µs). A frame is read whole, then offered to the LANCE:
  `fifordy` while words remain, `deof` with the last. **No `eof` pulse**:
  the LANCE latches `eof` until it pops the last word (only a reset clears
  it), so a frame offered and then withdrawn would leave it set. A frame
  the LANCE never takes (receiver off) is dropped after 200 ms or at INIT.
- **Filter.** PADR, broadcast, multicast whose LADRF bit is set, or
  everything with PROM. Byte order: PADR\[7:0\] is the first byte on the
  wire (the init block's words are byte-swapped on a big-endian Sun, as
  every sun4m driver writes them).

## Main side

`sparc_enet_start()` at core load (`is_sparc()`), `sparc_enet_poll()` every
pass, `sparc_enet_stop()` at the next core load, as the NeXT bridge. Modes
as the A2065 and NeXT: eth0 is promiscuous with the BPF filter on the guest
MAC (broadcasts too; multicast dropped), eth1 a dedicated NIC, macvlan a
child of eth0 named `sparc0`, tap0 needs `/dev/net/tun` (the test MiSTer's
kernel has none). The guest's MAC is the one the OS loads into the LANCE
(from the IDPROM, unique per NVRAM image since `c6c45eb`).
