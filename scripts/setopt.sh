#!/usr/bin/env bash
# setopt.sh [name=value ...] - set the core's OSD options without the OSD.
#
# MiSTer keeps a core's OSD state in /media/fat/config/<CORENAME>.CFG: the
# 128-bit status word, 16 bytes, bit N in byte N/8 bit N%8. It is read when the
# core starts, so this writes the file and the caller relaunches the core.
# Names follow CONF_STR in SunSparcStation.sv; keep them in step.
#
#   cdbs=2048|512            O[4]    CD-ROM block size (System)
#   aspect=4:3|full|arc1|arc2 O[7:6]  (Video)
#   scale=normal|vint|hvint-|hvint+ O[15:14] (Video)
#   autoboot=on|off          O[8]    (System)
#   console=video|serial     O[9]    the console (System)
#   video=tcx|cg3            O[10]   graphics card (Video)
#   fb=internal|scaler       O[11]   output: core video or MiSTer fb (Video)
#   kbd=us|fr|de|es          O[13:12] (System)
#   cache=on|off             O[16]   (Advanced)
#   l2tlb=off|on             O[17]   (Advanced)
#   wb=off|on                O[18]   SS20 (Advanced)
#   aow=off|on               O[19]   SS20 (Advanced)
#   iommu=26|11|23|30        O[21:20] (Advanced)
#   memory=464|256|128|64    O[23:22] SS20 (System)
#   network=eth0|off|eth1|macvlan|tap0 O[26:24] (System; Main's sun_enet)
# The disks and the CD are always there (a disk while its image is
# mounted); O[1] (two disks) and O[5] (CD off) are retired.
#
#   scripts/setopt.sh console=serial cdbs=512
#   scripts/setopt.sh            # all defaults
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
TMP=$(mktemp)
python3 - "$@" > "$TMP" <<'PY' || { rm -f "$TMP"; exit 2; }
import sys
F = {
    "cdbs":     (4, 1, {"2048": 0, "512": 1}),
    "aspect":   (6, 2, {"4:3": 0, "full": 1, "arc1": 2, "arc2": 3}),
    "autoboot": (8, 1, {"on": 0, "off": 1}),
    "console":  (9, 1, {"video": 0, "serial": 1}),
    "video":    (10, 1, {"tcx": 0, "cg3": 1}),
    "fb":       (11, 1, {"internal": 0, "scaler": 1}),
    "kbd":      (12, 2, {"us": 0, "fr": 1, "de": 2, "es": 3}),
    "scale":    (14, 2, {"normal": 0, "vint": 1, "hvint-": 2, "hvint+": 3}),
    "cache":    (16, 1, {"on": 0, "off": 1}),
    "l2tlb":    (17, 1, {"off": 0, "on": 1}),
    "wb":       (18, 1, {"off": 0, "on": 1}),
    "aow":      (19, 1, {"off": 0, "on": 1}),
    "iommu":    (20, 2, {"26": 0, "11": 1, "23": 2, "30": 3}),
    "memory":   (22, 2, {"464": 0, "256": 1, "128": 2, "64": 3}),
    "network":  (24, 3, {"eth0": 0, "off": 1, "eth1": 2, "macvlan": 3, "tap0": 4}),
}
st = 0
for a in sys.argv[1:]:
    k, _, v = a.partition("=")
    if k not in F or v not in F[k][2]:
        sys.exit(f"setopt: bad option {a!r}; see the header of scripts/setopt.sh")
    lo, w, m = F[k]
    st = (st & ~(((1 << w) - 1) << lo)) | (m[v] << lo)
sys.stdout.buffer.write(st.to_bytes(16, "little"))
sys.stderr.write(f"status = 0x{st:032x}\n")
PY
scp -q "${SSH_OPTS[@]}" "$TMP" "$DEV:/media/fat/config/$GAMES_DIR.CFG" && log "wrote /media/fat/config/$GAMES_DIR.CFG"
rm -f "$TMP"
