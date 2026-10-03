#!/bin/sh
# Benches for the chipset (GHDL):
#   tb_kbd.vhd   the keyboard translator: PS/2 bytes in, Sun codes out
#                (L-keys, AltGraph, Pause, Print Screen, the reset reply)
set -e
here=$(cd "$(dirname "$0")" && pwd)
rtl=$here/../..
w=${TMPDIR:-/tmp}/tb_sun4m.$$
mkdir -p "$w"
trap 'rm -rf "$w"' EXIT
o="--std=93c -frelaxed -fsynopsys -Wno-hide -Wno-shared --workdir=$w"
cd "$w"
ghdl -a $o "$rtl/plomb/base_pack.vhd" "$rtl/plomb/plomb_pack.vhd" \
    "$rtl/sun4m/ts_pack.vhd" "$rtl/peri/ps2.vhd" "$rtl/sun4m/ts_sunkb.vhd" \
    "$rtl/sun4m/ts_ps2sun.vhd" "$here/tb_kbd.vhd"
ghdl -e $o tb_kbd
echo "== tb_kbd"
ghdl -r $o tb_kbd 2>&1 | sed -n 's/.*(report \(note\|error\)): //p'
