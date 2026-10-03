# Releases

| file | what |
|---|---|
| `SunSparcStation20_20261002.rbf` | the SPARCstation 20 core: 3 CPUs at 55 MHz |
| `boot0.rom` | OpenBIOS for the core (GPL-2), built from `bios/` (one image for the SS5 and the SS20) |
| `MiSTer` | the Main binary the core's network and CUE/CHD support need |

## Installing

1. Copy `SunSparcStation20_20261002.rbf` to `_Computer/` (or wherever your
   cores live) on the MiSTer's SD card.
2. Copy `boot0.rom` to `games/SunSparcStation/boot0.rom`. Remove any
   `boot.rom` in that folder: Main sends `boot0.rom` first and then a
   `boot.rom` to the same place, so an old `boot.rom` would win.
3. Disk images (VHD, IMG, HDA or RAW), CD images (ISO, CUE/BIN, CHD) and an
   NVRAM file (`.nvr`, 8192 bytes, may start empty) go in
   `games/SunSparcStation/`; pick them in the OSD.
4. For Ethernet (OSD System → Network) and CUE/CHD CDs, replace `MiSTer` on
   the SD card with the one here (keep the old one: rename it), then
   reboot. It is the official Main plus the `fast-mac-scsi` write buffer
   ([MiSTer-devel/Main_MiSTer#1336](https://github.com/MiSTer-devel/Main_MiSTer/pull/1336))
   and the `sparcstation-enhancements` branch of
   [danifunker/Main_MiSTer](https://github.com/danifunker/Main_MiSTer).
   With the official Main the core boots and runs from disks and ISO CDs;
   the network stays off and disk writes are slower.

See the main [README](../README.md) for the OSD, the NVRAM and the OS notes.

## SunSparcStation20_20261002

- rbf md5 `0913c49e39ca33677eca966316a8c679`; RTL as of `75d5054`
  (branch `danifunker`); Quartus 17.0.2 Lite, fit seed 1: 89 % ALMs, every
  clock met (core +0.311 ns, HDMI +0.141 ns, hold +0.249 ns).
- `boot0.rom` md5 `1d88d584578ee7440500f562005ef10b` (`f885cf2`, the
  repository's `bios/boot.rom`).
- `MiSTer` md5 `7632b9e54c3d4cfd4b6e7eb941f0a192` (Main
  `sparcstation-enhancements` at `c00a7d1`).
- New since the SparcStation core: the standard MiSTer framework; SCSI disks
  and CD through the MiSTer's Linux side (one target engine, 16 KB
  requests); Ethernet through the MiSTer's network port; CUE/CHD CDs; the
  NVRAM saved on the SD card, with its own IDPROM per NVRAM file; an OSD
  memory size; the official Sun OBP 2.25 boots Solaris on all three CPUs;
  a much faster OpenBIOS screen console.
- Tested on the board: the CPU test suite (65/0/0), the SCSI test ROM
  (6/0/0), NetBSD 11 and Solaris 8 under OpenBIOS, Solaris 8 under the Sun
  OBP with 3 CPUs, NetBSD on the LAN (DHCP, ping to the internet), NetBSD's
  install CD as ISO, CHD and CUE, two disks, the memory option, a blank
  NVRAM's own IDPROM, CDE on the screen, and 74 minutes of a three-CPU
  Solaris disk stress (find | cksum loops) without a fault.
