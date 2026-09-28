#!/bin/sh
# Randomised test of the DDRAM arbiter (iverilog).
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/tb_ddram_arb.vvp
iverilog -g2012 -o "$out" "$here/../ddram_arb.sv" "$here/tb_ddram_arb.sv"
vvp -n "$out" | tail -3
