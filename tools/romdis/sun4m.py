"""sun4m machine knowledge for the ROM disassembler: ASI names, MMU and
MXCC register names, and the SS5 / SS20 physical address maps.

Physical addresses are 36 bits. With the MMU off (or through the MMU bypass
ASIs 0x20-0x2F) bits 35:32 of the physical address come from ASI[3:0], so
`sta %x, [0xf1400000] 0x2f` on an SS20 is physical 0xf_f140_0000.

Sources: Sun-4M System Architecture; microSPARC-II User's Manual;
SuperSPARC / MXCC documentation; the Linux sparc32 asi.h / mxcc.h; QEMU
hw/sparc/sun4m.c machine tables. Entries marked (?) are unverified and
should be checked against the scratch/ manuals before they are relied on.
Extend these tables as the ROM analysis finds more.
"""

# ---------------------------------------------------------------- ASIs ----
ASI_COMMON = {
    0x01: "ASI_PTE/unassigned",
    0x02: "ASI_MXCC (SuperSPARC MXCC regs) / control space",
    0x03: "ASI_FLUSH_PROBE",
    0x04: "ASI_MMUREGS",
    0x05: "ASI_TLBDIAG",
    0x06: "ASI_DIAGS (TLB/MMU diag)",
    0x07: "ASI_IODIAG",
    0x08: "ASI_USERTXT",
    0x09: "ASI_KERNELTXT",
    0x0a: "ASI_USERDATA",
    0x0b: "ASI_KERNELDATA",
    0x0c: "ASI_ICACHE_TAG",
    0x0d: "ASI_ICACHE_DATA",
    0x0e: "ASI_DCACHE_TAG",
    0x0f: "ASI_DCACHE_DATA",
    0x10: "ASI_FLUSH_PAGE",
    0x11: "ASI_FLUSH_SEG",
    0x12: "ASI_FLUSH_REGION",
    0x13: "ASI_FLUSH_CTX",
    0x14: "ASI_FLUSH_USER",
    0x17: "ASI_BCOPY",
    0x18: "ASI_IFLUSH_PAGE",
    0x19: "ASI_IFLUSH_SEG",
    0x1a: "ASI_IFLUSH_REGION",
    0x1b: "ASI_IFLUSH_CTX",
    0x1c: "ASI_IFLUSH_USER",
    0x1f: "ASI_BFILL",
    0x31: "ASI_FLUSH_IWHOLE",
    0x36: "ASI_IC_FLCLEAR (I-cache flash clear)",
    0x37: "ASI_DC_FLCLEAR (D-cache flash clear)",
    0x38: "ASI_MMU_BREAKPOINT_DIAG (?)",
    0x39: "ASI_DCDR (D-cache diag)",
    0x40: "ASI_VIKING_TMP1 / emulation temp (?)",
    0x41: "ASI_VIKING_TMP2 (?)",
    0x4c: "ASI_ACTION (Viking breakpoint action)",
}
for _a in range(0x20, 0x30):
    ASI_COMMON[_a] = f"ASI_BYPASS pa[35:32]=0x{_a & 0xf:x}"

# ASI 0x04 register offsets (SRMMU reference MMU)
MMUREGS = {
    0x000: "MMU control (PCR/MCNTL)",
    0x100: "context table pointer",
    0x200: "context",
    0x300: "sync fault status (SFSR)",
    0x400: "sync fault address (SFAR)",
    0x500: "async fault status (AFSR) (?)",
    0x600: "async fault address (AFAR) (?)",
    0x700: "reset / breakpoint (?)",
    0x1000: "MMU/cache control extension (?)",
}

# ASI 0x02 on SuperSPARC with MXCC (Linux asm/mxcc.h)
MXCC = {
    0x01c00000: "MXCC stream data",
    0x01c00100: "MXCC stream source",
    0x01c00200: "MXCC stream destination",
    0x01c00300: "MXCC reference/miss count",
    0x01c00a00: "MXCC control (hi)",
    0x01c00a04: "MXCC control register (CREG)",
    0x01c00b00: "MXCC status register (SREG)",
    0x01c00c00: "MXCC reset (hi)",
    0x01c00c04: "MXCC reset register (RREG)",
    0x01c00e00: "MXCC error register (EREG)",
    0x01c00f00: "MXCC port (hi)",
    0x01c00f04: "MXCC module port register (PREG)",
}

# ------------------------------------------------------- address maps ----
# (start, end_exclusive, name). 36-bit physical addresses.
SS5_MAP = [
    (0x0_00000000, 0x0_10000000, "RAM"),
    (0x0_10000000, 0x0_10001000, "IOMMU"),
    (0x0_10001000, 0x0_10002000, "SBus controller (?)"),
    (0x0_20000000, 0x0_30000000, "SBus slot 0 (?)"),
    (0x0_30000000, 0x0_40000000, "SBus slot 1 (?)"),
    (0x0_40000000, 0x0_50000000, "SBus slot 2 (?)"),
    (0x0_50000000, 0x0_60000000, "TCX (SBus slot 3)"),
    (0x0_6a000000, 0x0_6a100000, "APC power/audio DMA"),
    (0x0_6c000000, 0x0_6c100000, "CS4231 audio codec"),
    (0x0_6e000000, 0x0_6e100000, "AFX (?)"),
    (0x0_70000000, 0x0_71000000, "boot PROM"),
    (0x0_71000000, 0x0_71100000, "ESCC0 keyboard/mouse (Z85C30)"),
    (0x0_71100000, 0x0_71200000, "ESCC1 serial A/B (Z85C30)"),
    (0x0_71200000, 0x0_71300000, "NVRAM/TOD (MK48T08)"),
    (0x0_71400000, 0x0_71500000, "floppy (82077)"),
    (0x0_71900000, 0x0_71910000, "aux1 (LED/floppy aux)"),
    (0x0_71910000, 0x0_71920000, "aux2 (power/modem)"),
    (0x0_71d00000, 0x0_71e00000, "counter/timers"),
    (0x0_71e00000, 0x0_71f00000, "interrupt controller"),
    (0x0_71f00000, 0x0_72000000, "system control/status (?)"),
    (0x0_78000000, 0x0_78400000, "ID register / onboard (?)"),
    (0x0_78400000, 0x0_78800000, "DMA2 (ESP/LANCE DMA)"),
    (0x0_78800000, 0x0_78c00000, "ESP 53C9x SCSI"),
    (0x0_78c00000, 0x0_79000000, "LANCE Am7990 Ethernet"),
    (0x0_7c000000, 0x0_80000000, "parallel / other onboard (?)"),
]

SS20_MAP = [
    (0x0_00000000, 0x0_f0000000, "RAM"),
    (0xe_00000000, 0xe_10000000, "SBus slot 0"),
    (0xe_10000000, 0xe_20000000, "SBus slot 1"),
    (0xe_20000000, 0xe_30000000, "SBus slot 2"),
    (0xe_30000000, 0xe_40000000, "SBus slot 3"),
    (0xe_e0000000, 0xe_f0000000, "SBus slot 14 onboard (DBRI audio)"),
    (0xe_f0000000, 0xe_f0400000, "SBus slot 15 onboard / ID (?)"),
    (0xe_f0400000, 0xe_f0800000, "DMA2 (ESP/LANCE DMA)"),
    (0xe_f0800000, 0xe_f0c00000, "ESP 53C9x SCSI"),
    (0xe_f0c00000, 0xe_f1000000, "LANCE Am7990 Ethernet"),
    (0xe_f4800000, 0xe_f4900000, "parallel port BPP"),
    (0xe_fa000000, 0xe_fa100000, "APC (?)"),
    (0xf_00000000, 0xf_10000000, "EMC ECC memory controller"),
    (0xf_80000000, 0xf_c0000000, "SX graphics / VSIMM (?)"),
    (0xf_e0000000, 0xf_e0001000, "IOMMU"),
    (0xf_e0001000, 0xf_e0002000, "SBI SBus interface"),
    (0xf_f0000000, 0xf_f1000000, "boot PROM (BootBus)"),
    (0xf_f1000000, 0xf_f1100000, "ESCC0 keyboard/mouse (Z85C30)"),
    (0xf_f1100000, 0xf_f1200000, "ESCC1 serial A/B (Z85C30)"),
    (0xf_f1200000, 0xf_f1300000, "NVRAM/TOD (MK48T08)"),
    (0xf_f1300000, 0xf_f1400000, "counter/timers"),
    (0xf_f1400000, 0xf_f1500000, "interrupt controller"),
    (0xf_f1700000, 0xf_f1800000, "floppy (82077)"),
    (0xf_f1800000, 0xf_f1900000, "aux1 (LED/floppy aux)"),
    (0xf_f1a00000, 0xf_f1b00000, "aux2 (power) (?)"),
    (0xf_f1f00000, 0xf_f2000000, "system control/status (?)"),
]

PROFILES = {
    "ss5": {"map": SS5_MAP, "cpu": "microSPARC-II (Swift, MB86904)"},
    "ss20": {"map": SS20_MAP, "cpu": "SuperSPARC (Viking) +/- MXCC, HyperSPARC"},
}


def device(profile, pa):
    for lo, hi, name in PROFILES[profile]["map"]:
        if lo <= pa < hi:
            return name, pa - lo
    return None, None


def asi_name(asi):
    return ASI_COMMON.get(asi, f"ASI 0x{asi:02x}")


def describe_asi_access(profile, asi, ea):
    """One-line description of an alternate-space access to effective
    address ea (None when unknown)."""
    name = asi_name(asi)
    if ea is None:
        return name
    if 0x20 <= asi <= 0x2f:
        pa = ((asi & 0xf) << 32) | ea
        dev, off = device(profile, pa)
        if dev:
            return f"pa 0x{pa:09x} {dev} +0x{off:x}"
        return f"pa 0x{pa:09x}"
    if asi == 0x04:
        reg = MMUREGS.get(ea & 0xffff if ea < 0x10000 else ea)
        return f"{name} {reg or hex(ea)}"
    if asi == 0x02 and ea in MXCC:
        return f"{name}: {MXCC[ea]}"
    return f"{name} [0x{ea:08x}]"
