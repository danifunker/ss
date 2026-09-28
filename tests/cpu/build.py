#!/usr/bin/env python3
"""Build the CPU test suite PROM images.

    python3 tests/cpu/build.py [target ...] [-DNAME=VALUE ...]
                                                (default: all targets)
    e.g. -DDETAIL_LIMIT=1000 prints every failing check

Targets: ss5-qemu (link 0x70000000), ss5-core (0xf0000000), ss20 (0).
Output: tests/cpu/out/<target>/cputest.rom (+ .map, .lst). Toolchain:
LLVM's clang (--target=sparc, integrated assembler) and
tools/sparc_link.py; tools/romdis/sparcv8.py disassembles the result.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
LLVM = "/usr/lib/llvm-18/bin"
TARGETS = {
    "ss5-qemu": ("TARGET_SS5_QEMU", 0x70000000, 0x40000),
    "ss5-core": ("TARGET_SS5_CORE", 0xf0000000, 0x40000),
    "ss20": ("TARGET_SS20", 0x00000000, 0x40000),
}


def clang():
    for c in (os.path.join(LLVM, "clang"), "clang-18", "clang"):
        if os.path.exists(c) or subprocess.run(
                ["which", c], capture_output=True).returncode == 0:
            return c
    sys.exit("clang with the SPARC target is needed (LLVM 18)")


def build(name, extra=()):
    macro, base, size = TARGETS[name]
    out = os.path.join(HERE, "out", name)
    os.makedirs(out, exist_ok=True)
    obj = os.path.join(out, "cputest.o")
    rom = os.path.join(out, "cputest.rom")
    subprocess.run([clang(), "--target=sparc-unknown-elf", "-mcpu=v8",
                    "-x", "assembler-with-cpp", f"-D{macro}", "-I",
                    os.path.join(HERE, "src"), *extra, "-c",
                    os.path.join(HERE, "src", "main.S"), "-o", obj],
                   check=True)
    subprocess.run([sys.executable, os.path.join(REPO, "tools",
                                                 "sparc_link.py"), obj,
                    "-o", rom, "--base", hex(base), "--size", hex(size),
                    "--map", os.path.join(out, "cputest.map"),
                    "--order", ".text,.rodata,.testtab,.romend"],
                   check=True)
    print(f"{name}: {rom}")


def main():
    subprocess.run([sys.executable, os.path.join(HERE, "gen_alu.py")],
                   check=True)
    args = sys.argv[1:]
    extra = [a for a in args if a.startswith("-D")]
    for t in [a for a in args if not a.startswith("-D")] or TARGETS:
        build(t, extra)


if __name__ == "__main__":
    main()
