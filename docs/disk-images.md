# Building OS disk images in QEMU

How the test images were made (2026-09-28), so they can be rebuilt. Both are
built under QEMU 11.1.1 (`~/.local/qemu-11.1.1`, built from source) on the
`SS-5` machine. Ubuntu's QEMU 8.2.2 cannot install Solaris: it panics
("Non-parity synchronous error" in `fetch_user_instr` / `simulate_unimp`) at
the first instruction Solaris emulates. It also has known V8 bugs
(`tests/cpu/README.md`).

The ISOs are on the NAS (`smb://daninas.local/software/Sun-Solaris/Sparc32`).
The images live in `scratch/images/` (gitignored), and on the MiSTer in
`games/SunSparcStation/`. A fixed VHD is the raw image plus a 512-byte
`conectix` footer:

```bash
qemu-img convert -O vpc -o subformat=fixed,force_size=on in.img out.vhd
```

MiSTer and the core treat `.vhd`, `.img`, `.hda` and `.raw` alike (the OSD
HD slots accept all four).

| Image | Size | SCSI target | Contents |
|---|---|---|---|
| `netbsd11.vhd` | 2 GB | any (installed at 0) | NetBSD 11.0 GENERIC; `sd0a` / 1.7 GB FFSv1, `sd0b` 256 MB swap; sets base etc kern-GENERIC modules rescue text misc man games comp; root password empty |
| `sol8-t3.vhd` | 2.9 GB | **3** (`c0t3d0`) | Solaris 8 2/04, Entire Group, 32-bit, C locale, GMT; `s0` / 1.39 GB, `s1` swap 512 MB, `s7` /export/home; host `sunsparc8`; root password empty |

NetBSD finds its disk as `sd0` whatever the target. Solaris names it by
target (`c0t3d0`) in `/etc/vfstab`, so `sol8-t3` boots only where the disk
is at target 3. Real Suns put it there, and so will the core after the SCSI
rework. The core still puts HD0 at target 0 today.

## NetBSD 11.0

1. **Boot the install CD with the real SS5 PROM.** QEMU's OpenBIOS cannot:
   the CD's Sun label addresses 512-byte blocks, and OpenBIOS reads the
   2048-byte CD without switching the block size.
   ```bash
   qemu-img create -f raw netbsd11.img 2G
   ```
   ```bash
   qemu-system-sparc -M SS-5 -m 256 -bios scratch/SparcStation/ss5.bin -nographic -drive file=netbsd11.img,format=raw,if=scsi,bus=0,unit=0 -drive file=NetBSD-11.0-sparc32.iso,format=raw,if=scsi,bus=0,unit=6,media=cdrom
   ```
   - Use `-nographic`. With a display, OBP moves its console to the
     invisible screen.
   - At `ok`, after the diag-mode memory test, type `boot cdrom`.
2. **Load the installer from the CD.** In the microroot, answer `1`
   (cdrom), then `/dev/cd1a` (the CD at target 6; QEMU adds an empty CD at
   target 2 as `cd0`), then accept the path. At
   `(I)nstall/Upgrade, (H)alt or (S)hell?` choose `S`.
3. **Install by hand.** The ramdisk has no `head`, `tr` or `grep`, and no
   `cd1` device nodes.
   ```sh
   mknod /dev/cd1a b 18 8; mknod /dev/rcd1a c 58 8
   mkdir /cd; mount -t cd9660 -o ro /dev/cd1a /cd
   ```
   ```sh
   # disklabel -R -r sd0 /tmp/proto, where /tmp/proto is:
   #   geometry 63 sect x 16 heads x 4161 cyl (total 4194304)
   #   a: 3670128 0 4.2BSD 2048 16384 0
   #   b: 524160 3670128 swap
   #   c: 4194288 0 unused 0 0
   ```
   ```sh
   newfs -O 1 /dev/rsd0a            # FFSv1 for the OBP-era boot blocks
   mount /dev/sd0a /mnt
   mount -u -o async /dev/sd0a /mnt  # names the device: there is no fstab
   for s in base etc kern-GENERIC modules rescue text misc man games comp; do
     tar -xzpf /cd/sparc/binary/sets/$s.tgz -C /mnt; done
   cd /mnt/dev && sh ./MAKEDEV all; cd /
   cp /mnt/usr/mdec/boot /mnt/boot
   chroot /mnt /usr/sbin/installboot -v /dev/rsd0c /usr/mdec/bootxx /boot
   mkdir -p /mnt/kern /mnt/proc
   ```
   Then write `/mnt/etc/fstab`:
   - `/dev/sd0a / ffs rw,log 1 1`
   - `/dev/sd0b none swap sw 0 0`
   - kernfs, ptyfs and procfs lines.

   Append `rc_configured=YES`, `hostname=sunsparc`, `sshd=NO` and
   `postfix=NO` to `/mnt/etc/rc.conf`, then `umount /mnt; halt`.

   The ramdisk's `printf` cannot print `%`, so keep tmpfs options out of
   `fstab`.
4. **Test boot under QEMU's OpenBIOS.** Drop the `-bios` option and use
   `boot disk`. Under the real PROM in QEMU, GENERIC panics attaching
   `SUNW,bpp` (the PROM lists the parallel port, and QEMU does not emulate
   it).

## Solaris 8 2/04

1. **Label the disk before installing.** `SOL_8_204_SPARC.iso` is the
   single all-in-one install disc. Boot it with QEMU's own OpenBIOS:
   ```bash
   qemu-img create -f raw sol8.img 2900M
   ```
   ```bash
   qemu-system-sparc -M SS-5 -m 256 -nographic -prom-env 'auto-boot?=false' -drive file=sol8.img,format=raw,if=scsi,bus=0,unit=3 -drive file=SOL_8_204_SPARC.iso,format=raw,if=scsi,bus=0,unit=6,media=cdrom
   ```
   ```
   0 > boot /iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd@6,0:d
   ```
   (OpenBIOS's `cdrom` alias points at QEMU's empty target-2 drive.)
2. **Language, locale, terminal:** answer 0, 0 and 3 (VT100). It runs "Web
   Start" in command-line mode.
3. **Label the disk.** On a disk with no label the installer fails with
   `InvocationTargetException … ProfileServerObject.initProfile` and drops
   to a shell. Label it there with `format`:
   - `format`, then pick disk 0, `c0t3d0` (`<drive type unknown>`);
   - `type` → `18` (other). Auto configure fails on QEMU's drive;
   - enter 5890 data cylinders, 2 alternates, 16 heads and 63
     sectors/track, and take the defaults for the rest;
   - name it `"QEMU 2900MB"`, then `label`, `y`, `quit`;
   - `reboot` and boot the CD again.
4. **Answers.**
   - Networked `n`, host `sunsparc8`, Kerberos `n`, time zone `2` (offset)
     `0`, date `y`.
   - Root password: empty. The installer asks twice, then asks again after
     the "optional password" note; give empty answers until the summary.
   - Then `y`, Enter, Reboot automatically `y`, Eject `n`, `y`, Media `1`,
     Default Install `1`, `y`.
   - The install (software group, additional software, documentation)
     took about 1 h 45 min under QEMU 11.1.1 on this box.
5. **First boot.**
   ```
   0 > boot /iommu@0,10000000/sbus@0,10001000/espdma@5,8400000/esp@5,8800000/sd@3,0:a
   ```
   You get `sunsparc8 console login:`. Log in as `root` with no password.
