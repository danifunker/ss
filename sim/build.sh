#!/usr/bin/env bash
#
# build.sh 5|20 [--trace] - build the Verilator model of one revision.
#
# Regenerates sim/generated/ss_core_ss<REV>.v when any RTL file is newer,
# then verilates sim_top.sv + ddram_arb.sv + the generated core with the
# harness into sim/obj_ss<REV>/Vsim_top (sim/obj_ss<REV>_trace/ with
# --trace, which adds VCD waveform support and costs build time).

set -euo pipefail

REV="${1:-5}"
shift || true
TRACE=0
for a in "$@"; do
    case "$a" in
        --trace) TRACE=1 ;;
        *) echo "unknown argument $a" >&2; exit 2 ;;
    esac
done
case "$REV" in
    5)  SYSFREQ=65000000 ;;
    20) SYSFREQ=50000000 ;;
    *)  echo "usage: $0 5|20 [--trace]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/sim/generated/ss_core_ss$REV.v"
OBJ="$ROOT/sim/obj_ss$REV"
[ "$TRACE" = 1 ] && OBJ="${OBJ}_trace"
# SIM_OBJ=dir builds elsewhere, e.g. while a run still uses the usual model
[ -n "${SIM_OBJ:-}" ] && OBJ="$ROOT/sim/$SIM_OBJ"

# Regenerate when an RTL file, the file list or the generator is newer.
stale=0
[ -f "$GEN" ] || stale=1
if [ "$stale" = 0 ]; then
    newer=$(find "$ROOT/rtl" "$ROOT/files.qip" "$ROOT/sim/gen_verilog.sh" "$ROOT/sim/pll_sim.vhd" \
                 -name '*.vhd' -newer "$GEN" -o -name files.qip -newer "$GEN" \
                 -o -name gen_verilog.sh -newer "$GEN" | head -1)
    [ -n "$newer" ] && stale=1
fi
[ "$stale" = 1 ] && "$ROOT/sim/gen_verilog.sh" "$REV"

VFLAGS=(
    --cc --exe --build -j "$(nproc)"
    --top-module sim_top
    -O3 --x-assign fast --x-initial fast --noassert
    +1364-2005ext+v
    -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-SYMRSVDWORD
    -CFLAGS "-O2 -DSIM_SYSFREQ=$SYSFREQ"
    -MAKEFLAGS "OPT_FAST=-O2 OPT_SLOW=-O1"
    -Mdir "$OBJ"
)
[ "$TRACE" = 1 ] && VFLAGS+=(--trace)

cd "$ROOT"
time verilator "${VFLAGS[@]}" \
    "$GEN" "$ROOT/rtl/mister/ddram_arb.sv" "$ROOT/sim/sim_top.sv" "$ROOT/sim/sim_main.cpp"
echo "built $OBJ/Vsim_top"
