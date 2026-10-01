#!/usr/bin/env bash
# kbtype.sh TEXT... - type on the core's keyboard from this machine.
#
# Each argument is typed, then Enter. Keys go through mrext's virtual
# keyboard on the MiSTer (POST /api/controls/keyboard-raw/<Linux key
# code>), so they reach the core as PS/2 like a real keyboard: this is how
# to drive the Sun OBP's "ok" prompt, whose console is the screen and the
# keyboard. No Shift: only [a-z0-9], space and - . / , are typed.
#   scripts/kbtype.sh "setenv diag-device disk" boot
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
declare -A K=( [q]=16 [w]=17 [e]=18 [r]=19 [t]=20 [y]=21 [u]=22 [i]=23 [o]=24
    [p]=25 [a]=30 [s]=31 [d]=32 [f]=33 [g]=34 [h]=35 [j]=36 [k]=37 [l]=38
    [z]=44 [x]=45 [c]=46 [v]=47 [b]=48 [n]=49 [m]=50 [1]=2 [2]=3 [3]=4 [4]=5
    [5]=6 [6]=7 [7]=8 [8]=9 [9]=10 [0]=11 [-]=12 [.]=52 [/]=53 [,]=51
    [" "]=57 )
key() { curl -s -m 5 -o /dev/null -X POST "http://$MISTER_HOST:8182/api/controls/keyboard-raw/$1"; }
for s in "$@"; do
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        [ -n "${K[$c]:-}" ] || { log "kbtype: no key for '$c'"; exit 1; }
        key "${K[$c]}"
        sleep 0.15
    done
    key 28          # Enter
    sleep 1
done
