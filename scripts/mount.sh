#!/usr/bin/env bash
# mount.sh [--hd0 FILE] [--hd1 FILE] [--cd FILE] [--nvram FILE] [--mgl REV]
#
# Attach images without the OSD. FILE is a name in games/SunSparcStation/ or
# an absolute path on the MiSTer; "" detaches.
#
# --nvram is slot 3, the NVRAM image (an 8192-byte file, read at every core
# start and written back when the machine changes the NVRAM).
#
# With the remembered slots (CONF_STR "SC0" to "SC3"), MiSTer keeps each
# slot's image in /media/fat/config/<core>.s<n>: a fixed 1024-byte record,
# the absolute path NUL-padded (Main menu.cpp FileSaveConfig). The core
# remounts them at every start, so this writes the records and nothing else.
#
# --mgl REV (5|20) instead writes a one-shot MGL (for builds without the
# SC slots) and launches the core with it through /dev/MiSTer_cmd.
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
GAMES="/media/fat/games/$GAMES_DIR"
declare -A SLOT; MGL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --hd0) SLOT[0]="$2"; shift ;;
        --hd1) SLOT[1]="$2"; shift ;;
        --cd)  SLOT[2]="$2"; shift ;;
        --nvram) SLOT[3]="$2"; shift ;;
        --mgl) MGL=$(rev_of "$2") || exit 2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
abs() { case "$1" in ""|/*) echo "$1" ;; *) echo "$GAMES/$1" ;; esac; }
if [ -n "$MGL" ]; then
    X="<mistergamedescription>\n  <rbf>$MISTER_CORE_FOLDER/$MGL</rbf>\n"
    for n in "${!SLOT[@]}"; do
        [ -n "${SLOT[$n]}" ] && X="$X  <file delay=\"1\" type=\"s\" index=\"$n\" path=\"$(abs "${SLOT[$n]}")\"/>\n"
    done
    X="$X</mistergamedescription>\n"
    printf "$X" | ssh "${SSH_OPTS[@]}" "$DEV" "cat > /tmp/sss.mgl && echo 'load_core /tmp/sss.mgl' > /dev/MiSTer_cmd" \
        && log "launched $MGL with /tmp/sss.mgl"
    exit
fi
for n in "${!SLOT[@]}"; do
    P=$(abs "${SLOT[$n]}")
    python3 -c "import sys; p=sys.argv[1].encode(); sys.stdout.buffer.write(p + bytes(1024-len(p)))" "$P" \
        | ssh "${SSH_OPTS[@]}" "$DEV" "cat > /media/fat/config/$GAMES_DIR.s$n" \
        && log "slot $n = ${P:-(empty)}"
done
