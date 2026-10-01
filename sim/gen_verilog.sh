#!/usr/bin/env bash
#
# gen_verilog.sh 5|20 - lower ss_core (the whole machine, VHDL) to Verilog
# for Verilator, with GHDL 6's synthesis backend.
#
# Quartus compiles the VHDL directly; this is a simulation-only step and its
# output (sim/generated/) is never committed. The sources are copied and
# adjusted so that GHDL sees what Quartus synthesises:
#
#   - "--pragma synthesis_off" ... "synthesis_on" regions are removed, as
#     Quartus removes them. Upstream's simulation-only code in them uses
#     packages that were never published (fpu_sim_pack).
#   - "VARIABLE x : line;" declarations are dropped. Their only uses are in
#     those regions; Quartus ignores an unused access variable, GHDL's
#     synthesis refuses one.
#   - sim/pll_sim.vhd replaces the framework PLL.
#
# and the Verilog is post-processed:
#
#   - it is parsed as Verilog-2005 (+1364-2005ext+v): VHDL names such as
#     "int" and "cross" are SystemVerilog keywords;
#   - assertions are not synthesised (--no-formal): GHDL emits them as
#     $fatal, which Verilog-2005 does not have;
#   - 'Z' literals become '0'. They are record fields the RTL leaves
#     undriven (MCU tag requests) and the unused Direct-SD pins; Quartus
#     treats an internal Z as a don't-care, Verilator rejects it.
#
# The build-time generics match SunSparcStation.sv, plus SIMU=1, which skips
# the 512 MB DRAM clear after the ROM download (the simulated DDR starts
# zeroed).
#
#   sim/gen_verilog.sh 5      -> sim/generated/ss_core_ss5.v
#   sim/gen_verilog.sh 20     -> sim/generated/ss_core_ss20.v

set -euo pipefail

REV="${1:-5}"
case "$REV" in
    5)  GENERICS=(-gSYSFREQ=60000000 -gSS20=0 -gNCPUS=1) ;;
    20) GENERICS=(-gSYSFREQ=55000000 -gSS20=1 -gNCPUS=3) ;;
    *)  echo "usage: $0 5|20" >&2; exit 2 ;;
esac
GENERICS+=(-gTRACE=1 -gFPU_MULTI=0 -gTCX_ACCEL=1 -gSIMU=1)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/sim/generated"
WORK="$OUT/.ghdl-ss$REV"
SRC="$WORK/src"

command -v ghdl >/dev/null || { echo "error: ghdl not found (see sim/README.md)" >&2; exit 1; }
# A ghdl that is on PATH but cannot run fails late and quietly (the old
# output stays in place); check that it runs.
ghdl --version >/dev/null 2>&1 || { echo "error: ghdl is on PATH but does not run: ghdl --version" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$SRC" "$WORK/work" "$OUT"

# Every VHDL file Quartus compiles, in files.qip order.
mapfile -t FILES < <(awk '$3 == "VHDL_FILE" {print $4}' "$ROOT/files.qip")
[ "${#FILES[@]}" -gt 0 ] || { echo "error: no VHDL_FILE in files.qip" >&2; exit 1; }

for f in "${FILES[@]}"; do
    perl -ne '
        if (/--\s*(pragma\s+)?(synthesis|translate)[_ ]off/i) { $s = 1; next }
        if (/--\s*(pragma\s+)?(synthesis|translate)[_ ]on/i)  { $s = 0; next }
        next if $s;
        next if /^\s*VARIABLE\s+\w+\s*:\s*line\s*;\s*$/i;
        print;
    ' "$ROOT/$f" > "$SRC/$(basename "$f")"
done
cp "$ROOT/sim/pll_sim.vhd" "$SRC/"

# GHDL runs in the work directory: elaboration opens files the RTL declares
# (iu_pipe5.vhd creates Trace_pipe5.log).
cd "$WORK"
GHDL_OPTS=(--std=93c -frelaxed -fsynopsys -Wno-hide -Wno-shared --workdir="$WORK/work")

ghdl -i "${GHDL_OPTS[@]}" "$SRC"/*.vhd
ghdl -m "${GHDL_OPTS[@]}" ss_core
ghdl synth "${GHDL_OPTS[@]}" --no-formal "${GENERICS[@]}" --out=verilog ss_core \
    > "$WORK/ss_core.v" 2> "$WORK/synth.log" || { cat "$WORK/synth.log" >&2; exit 1; }

perl -pi -e "s/(\\d+'b)([01xXzZ]+)/\$1 . (\$2 =~ tr\/zZ\/00\/r)/ge" "$WORK/ss_core.v"
if grep -q -E "'b[01xX]*[zZ]" "$WORK/ss_core.v"; then
    echo "error: Z literals left after the rewrite" >&2; exit 1
fi

mv "$WORK/ss_core.v" "$OUT/ss_core_ss$REV.v"
rm -rf "$WORK"
echo "generated $OUT/ss_core_ss$REV.v ($(wc -l < "$OUT/ss_core_ss$REV.v") lines)"
