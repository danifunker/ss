#!/usr/bin/env bash
# machine.sh 5|20 | status - switch the MiSTer's per-machine files.
#
# Both revisions share the CONF_STR name SunSparcStation (decided
# 2026-09-30, for now), so they share games/SunSparcStation/boot.rom,
# config/SunSparcStation.CFG and the remembered slots
# config/SunSparcStation.s0-s2. This keeps one set per machine in
# games/SunSparcStation/machines/{ss5,ss20}/ and swaps them:
#
#   machine.sh 20     save the live files as the current machine's set,
#                     then restore the SS20 set (if there is one)
#   machine.sh status which machine is live, and what each set holds
#
# The live machine is recorded in machines/current. Before the first switch
# the live files are taken to be the SS5's. A machine with no saved set yet
# keeps the live files (OpenBIOS boots both). deploy.sh calls this before it
# pushes anything.
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
GAMES="/media/fat/games/$GAMES_DIR"
CFG="/media/fat/config"
M="$GAMES/machines"

case "${1:-}" in
    5|ss5|SunSparcStation5)    WANT=ss5 ;;
    20|ss20|SunSparcStation20) WANT=ss20 ;;
    status)                    WANT=status ;;
    *) echo "usage: $0 5|20|status" >&2; exit 2 ;;
esac

# One remote script: the live file names and the sets are all on the MiSTer.
ssh "${SSH_OPTS[@]}" "$DEV" sh -s -- "$WANT" "$GAMES" "$CFG" "$M" "$GAMES_DIR" <<'EOF'
want=$1; games=$2; cfg=$3; m=$4; name=$5
live="$games/boot.rom $cfg/$name.CFG $cfg/$name.s0 $cfg/$name.s1 $cfg/$name.s2"
mkdir -p "$m/ss5" "$m/ss20"
cur=$(cat "$m/current" 2>/dev/null || echo ss5)
if [ "$want" = status ]; then
    echo "live machine: $cur"
    for s in ss5 ss20; do
        echo "set $s:"
        for f in "$m/$s"/*; do
            [ -e "$f" ] || { echo "  (empty)"; break; }
            echo "  $(basename "$f")  $(md5sum < "$f" | cut -c1-8)"
        done
    done
    exit 0
fi
if [ "$cur" = "$want" ]; then
    echo "$want is already live"
    exit 0
fi
# save the live files as the current machine's set
rm -f "$m/$cur"/*
for f in $live; do [ -e "$f" ] && cp "$f" "$m/$cur/"; done
# restore the wanted set, if it has been saved before
if ls "$m/$want"/* >/dev/null 2>&1; then
    for f in $live; do
        b=$(basename "$f")
        if [ -e "$m/$want/$b" ]; then cp "$m/$want/$b" "$f"; else rm -f "$f"; fi
    done
    echo "switched $cur -> $want (restored the $want set)"
else
    echo "switched $cur -> $want (no $want set yet: live files kept)"
fi
echo "$want" > "$m/current"
sync
EOF
