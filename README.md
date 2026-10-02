# [SPARCstation](https://en.wikipedia.org/wiki/SPARCstation) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

SunSparcStation_MiSTer: Sun SPARCstation 5 and SPARCstation 20 (sun4m) for
MiSTer, by Grabulosaure, reworked for distribution. The rework is in
progress on branch `danifunker`; the plan and its status are in
[docs/REWORK.md](docs/REWORK.md).

## Compilation Modes

Two builds come from one Quartus project (`SunSparcStation.qpf`), one per
revision:

### SunSparcStation5
SparcStation 5: single CPU. MicroSparcII compatible CPU. Up to around 65MHz.

Compatible with all the OSes which supported actual Sun4m SparcStations: Linux, NetBSD, OpenBSD, SunOS, Solaris, NextSTEP. Some OSes require a special configuration.

### SunSparcStation20
SparcStation 20: up to 3 CPUs can fit in MiSTer FPGA. SMP with write-back caches, MESI coherency. SuperSparc compatible CPU. Up to around 50MHz.

SS20 seems to work with NetBSD with 3 CPUs. This is quite complex code and difficult to validate. Linux hardly ever supported multicore on these computers. I would like to be able to run multicore Solaris. IIRC, the debug monitor (`tools/debugarm`) is currently needed to properly activate SMP mode.

## Code
Core upstream: https://github.com/Grabulosaure/ss

There is also the OpenBIOS sources with the changes for this core (original repo. works with QEMU): https://github.com/Grabulosaure/ss_openbios

## Setup
### BIOS
Place this repository's [`bios/boot.rom`](bios/boot.rom) in the
`games/SunSparcStation` folder, as `boot.rom`. It is OpenBIOS (GPL-2) built
from [`bios/`](bios/) (Grabulosaure's
[ss_openbios](https://github.com/Grabulosaure/ss_openbios) with this core's
changes) by `scripts/build-bios.sh`; one image serves the SS5 and the SS20.
The Sun PROMs (SS5 OBP 2.15, SS20 OBP 2.25) also work, from your own
machine: they are not distributed.

**Upgrading from the SparcStation core:** the folder was `games/SparcStation`.
Move `boot.rom` and your disk images to `games/SunSparcStation`.

### NVRAM
The machine's NVRAM (the firmware settings: `boot-device`, `auto-boot?`,
`diag-switch?`, Solaris `eeprom` values, and the IDPROM with the Ethernet
address and host ID) is kept in an image file on the SD card. Create an
8192-byte file once, for example on the MiSTer:

`dd if=/dev/zero of=/media/fat/games/SunSparcStation/ss20.nvr bs=8192 count=1`

and pick it in the OSD under **NVRAM**. The core loads it at every start
and writes changes back to it about half a second after the machine
makes them. Without a file, the NVRAM starts blank at every core load.

A blank file gets an IDPROM of its own on its first load: the Sun
Ethernet prefix `08:00:20` and a random serial, which is also the host
ID's. It is written back to the file at once, so the machine keeps its
identity from then on.

Both firmwares keep their settings there: `setenv` at the `ok` prompt,
or `eeprom` from the OS (checked with Solaris). OpenBIOS stores the variables that
differ from their defaults. Two OSD options win over the NVRAM for one
boot without changing it: **System → Console** (screen and keyboard, or
serial) picks the OpenBIOS console, and **System → Auto boot: Off** stops
at `ok`; with Auto boot On, `auto-boot?` in the NVRAM decides. OpenBIOS and the Sun PROMs use
different formats: each formats the area for itself the first time a
setting changes, so keep one file per firmware and machine (SS5, SS20).

### OS
You can make your own images using the core, QEMU, or a real SparcStation.

[Using QEMU Sparc emulator to build a RAW image](https://learn.adafruit.com/build-your-own-sparc-with-qemu-and-solaris?view=all)

`qemu-img create -f raw solaris8.raw 2.9G`

`qemu-system-sparc -m 256 -drive format=raw,file=solaris8.raw,bus=0,unit=0,media=disk -cdrom sol-8-hw4-sparc-v1.iso -prom-env 'auto-boot?=false'`

## Core Notes
Type "boot" in OpenBIOS prompt if the OS doesn't start right away. And be patient. Keep a backup copy of the OS images on the SD card.

It's better to reboot MiSTer when trying different OSes, probably a few missing register reset.

When trying different IOMMU rev options, do a core RESET after applying a new value as this is copied by the BIOS into
a configuration structure.

### OSD
The first line names the model the core was built as (SPARCstation 20 or
5). Below it:

- **Disk 0 (SCSI 3)**, **Disk 1 (SCSI 1)**, **CD-ROM (SCSI 6)**: images on
  the MiSTer's SD card (VHD, IMG, HDA or RAW for disks, ISO for the CD), at
  the SCSI IDs of a real Sun (the boot disk is `sd3` / `c0t3d0`). A disk is
  there while an image is mounted; images can be mounted or swapped at any
  time (the drive reports a medium change to the OS). The core remembers
  the images and mounts them again at the next start.
- **NVRAM**: see above.
- **Video**: the graphics card (TCX, 8-bit, or CG3), the output (the
  core's own video or the MiSTer framebuffer), the aspect ratio.
- **System**: the console (screen and keyboard, or serial on ttya), auto
  boot, the keyboard layout, the CD-ROM block size (2048 bytes, or 512 as
  on Sun's own CD drives), and on the SS20 the memory (464, 256, 128 or
  64 MB).
- **Advanced**: developer tuning of the CPU caches, the L2 TLB, the
  SS20's write-back cache and the IOMMU revision OSes see. The defaults
  are the tested ones.

The "Direct SD" modes of the SparcStation core, which drove the secondary
SD card directly, were removed with the move to the standard MiSTer
framework.

CDROM works with Solaris (8), NextSTEP, Linux (RH). To mount the CD with Solaris, type: `mount -F hsfs -r /dev/dsk/c0t6d0s0 /cdrom`; for old Linux, it's `/dev/scd0`.

I've changed L2TLB control so that it can be enabled/disabled at any time. NextSTEP isn't compatible, Solaris and Linux seem safe. There are a few other possible tweaks for better performance, I'm curious of the effects on real-time games.

Ethernet: the SparcStation core reached the network through an MII PHY board
(LAN8720) on the USER_IO port. The standard framework drives USER_IO
open-drain only, which cannot carry that interface, so the option is gone;
Ethernet through the MiSTer's own network port is planned
([docs/HARDWARE_GAPS.md](docs/HARDWARE_GAPS.md), gap #1).

## OS Notes
Besides my own bugs, running all these different OSes is a bit tricky because the actual CPUs on SparcStations,
MicroSparcII on SS5 and SuperSparc on SS20 cannot be efficiently implemented exactly the same in a FPGA, and, more
than that, these microprocessors made by Fujitsu and Texas Instruments and designed partly by Sun were full of bugs,
particularly in the MMU and cache, so that the Operating Systems had to detect which CPU was present (hence IOMMU rev parameter)
to enable different cache and MMU management code. Awful.
(Just have to read old Linux kernel source code for Sparc32 support, it's full of profanities)

And NextSTEP has some bugs as well, it does weird things during boot and cannot yet be emulated with QEMU.
I didn't expect all these problems when I started this project, a long, long time ago.

## License
This core is distributed under the GNU General Public License, version 2
([LICENSE](LICENSE)), like the other MiSTer cores:

- the MiSTer framework (`sys/`): GPL-2.0 or later;
- OpenBIOS (`bios/`) and the TCX/CG3 FCode it carries (from the OpenBIOS
  project, as shipped with QEMU): GPL-2.0;
- the files and changes of this rework (branch `danifunker`, by Dani
  Sarfati): GPL-2.0 or later;
- Grabulosaure's original sources (the files whose header reads "This source
  file is copyrighted. Read the "lic.txt" file before use. … All rights
  reserved."): the author has been asked to confirm the GPL-2 licence for
  them; until he does, those files keep their own notice.

The Sun PROM images are Sun/Oracle copyright and are not part of this
repository.
