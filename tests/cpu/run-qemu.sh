#!/bin/sh
# Run the CPU test suite under qemu-system-sparc as the boot PROM.
#   tests/cpu/run-qemu.sh [ss5|ss20] [--no-build]
# Prints the serial log and compares it with expected/<target>-qemu.log:
# QEMU 8.2 has three known deviations from the V8 manual (README.md), so
# the reference is not all-PASS. Exit 0 when the log matches.
set -e
here=$(cd "$(dirname "$0")" && pwd)
m=${1:-ss5}
case "$m" in
  ss5)  target=ss5-qemu; machine=SS-5;  mem=64 ;;
  ss20) target=ss20;     machine=SS-20; mem=128 ;;
  *) echo "usage: $0 [ss5|ss20] [--no-build]" >&2; exit 2 ;;
esac
[ "$2" = "--no-build" ] || python3 "$here/build.py" "$target" >/dev/null
mkdir -p "$here/out/$target"
log="$here/out/$target/qemu.log"
timeout 60 qemu-system-sparc -M "$machine" -m "$mem" \
    -bios "$here/out/$target/cputest.rom" -nographic -serial mon:stdio \
    -monitor none -display none </dev/null 2>/dev/null \
  | tr -d '\r' | sed -u '/CPUTEST DONE/q' > "$log" || true
cat "$log"
ref="$here/expected/$target-qemu.log"
[ "$target" = ss5-qemu ] && ref="$here/expected/ss5-qemu.log"
[ "$target" = ss20 ] && ref="$here/expected/ss20-qemu.log"
if diff -u "$ref" "$log"; then
  echo "run-qemu: matches $(basename "$ref")"
else
  echo "run-qemu: DIFFERS from $(basename "$ref")" >&2
  exit 1
fi
