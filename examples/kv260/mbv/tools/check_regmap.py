#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""D2 gate 2: does the header comment of mbv_soc_top.sv match what the RTL decodes?

Mechanical comparison (no eyeballing) of three independent sources:

  1. the doxygen header of examples/kv260/mbv/rtl/mbv_soc_top.sv
     -- segment list (0xNN_0000 NAME) and CTRL register list (0xNN NAME (rw|ro))
  2. the RTL of the same file
     -- function seg_of() and the two `case (a[wr]addr_q[6:2])` decoders
  3. examples/kv260/common/ct_trace_sinks.sv
     -- the IX_* localparams of the delegated sink window and which of them
        the module actually accepts writes for

Exit 0 = every entry of each source has its counterpart in the others.
Usage: py check_regmap_mbv.py <repo-root>
"""
import re
import sys
from pathlib import Path

ACC_RW, ACC_RO = "rw", "ro"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def header_block(src: str) -> str:
    m = re.search(r"/\*\*(.*?)\*/\s*\n(?://[^\n]*\n|\s*\n)*module\s+mbv_soc_top", src, re.S)
    if not m:
        sys.exit("FATAL: doxygen header before `module mbv_soc_top` not found")
    return m.group(1)


def parse_header_segments(hdr: str):
    # "*     0x30_0000  AXIS   captured AXIS ..."
    out = {}
    for off, name in re.findall(r"0x([0-9A-Fa-f]{2})_0000\s+([A-Z][A-Z0-9_]*)\s", hdr):
        out[int(off, 16) << 16] = name
    return out


def parse_header_regs(hdr: str):
    # "0x08 TRACE_BEATS (ro, monotonic)" -- two of them may share one line
    out = {}
    for off, name, acc in re.findall(r"0x([0-9A-Fa-f]{2})\s+([A-Z][A-Z0-9_]*)\s*\((rw|ro)", hdr):
        out[int(off, 16)] = (name, acc)
    return out


def parse_seg_of(src: str):
    m = re.search(r"function automatic seg_e seg_of.*?endfunction", src, re.S)
    if not m:
        sys.exit("FATAL: function seg_of not found")
    body = m.group(0)
    # a[21] && a[20] -> AXIS ; a[21] -> TRACE ; a[20] -> RAM ; a[16] -> ENC ; else CTRL
    out = {}
    for cond, seg in re.findall(r"(?:if|else if)\s*\(([^)]*)\)\s*seg_of\s*=\s*SEG_(\w+)", body):
        bits = [int(b) for b in re.findall(r"a\[(\d+)\]", cond)]
        out[sum(1 << b for b in bits)] = seg
    if re.search(r"else\s+seg_of\s*=\s*SEG_CTRL", body):
        out[0] = "CTRL"
    return out


def parse_case(src: str, which: str):
    """which = 'aw' (write decoder) or 'ar' (read decoder) -> {offset: (name, index)}"""
    m = re.search(r"case\s*\(%saddr_q\[6:2\]\)(.*?)\n\s*endcase" % which, src, re.S)
    if not m:
        sys.exit("FATAL: `case (%saddr_q[6:2])` not found" % which)
    body = m.group(1)
    out = {}
    for line in body.splitlines():
        mm = re.match(r"\s*5'd(\d+)\s*:", line)
        if not mm:
            continue
        ix = int(mm.group(1))
        cm = re.search(r"//\s*0x([0-9A-Fa-f]{2})\s+([A-Z][A-Z0-9_]*)", line)
        if not cm:
            out[ix * 4] = (None, ix)          # decoded but not annotated
            continue
        off, name = int(cm.group(1), 16), cm.group(2)
        if off != ix * 4:
            print("FAIL  %s decoder: 5'd%d annotates 0x%02X, index means 0x%02X"
                  % (which, ix, off, ix * 4))
        out[ix * 4] = (name, ix)
    return out


def parse_sinks(path: Path):
    src = read(path)
    ix = {}
    for name, val in re.findall(r"localparam logic \[3:0\] IX_(\w+)\s*=\s*4'd(\d+);", src):
        ix[int(val) * 4] = name
    # A sink register counts as WRITABLE only if a write to its index actually
    # stores the bus data (`<sig> <= reg_wr_data_i` inside the guarded block).
    # DDR_BASE/DDR_SIZE are compared against reg_wr_ix_i too, but only to latch
    # the U9-1 rejection flag ddr_cfg_rej -- they stay read-only in hardware.
    writable = set()
    for m in re.finditer(r"reg_wr_ix_i\s*==\s*IX_(\w+)", src):
        window = src[m.end():m.end() + 400]
        if re.search(r"<=\s*reg_wr_data_i", window):
            writable.add(m.group(1))
    return ix, writable


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    top = root / "examples/kv260/mbv/rtl/mbv_soc_top.sv"
    sinks = root / "examples/kv260/common/ct_trace_sinks.sv"
    src = read(top)
    hdr = header_block(src)

    hseg = parse_header_segments(hdr)
    cseg = parse_seg_of(src)
    hreg = parse_header_regs(hdr)
    wr = parse_case(src, "aw")
    rd = parse_case(src, "ar")
    six, swritable = parse_sinks(sinks)

    bad = 0

    print("== segments (header <-> seg_of) ==")
    for off in sorted(set(hseg) | set(cseg)):
        h, c = hseg.get(off), cseg.get(off)
        ok = h == c
        bad += not ok
        print("  0x%02X_0000  header=%-6s rtl=%-6s  %s"
              % (off >> 16, h, c, "ok" if ok else "MISMATCH"))

    print("== CTRL registers (header <-> decoders <-> ct_trace_sinks) ==")
    offs = sorted(set(hreg) | set(wr) | set(rd) | set(six))
    for off in offs:
        hname, hacc = hreg.get(off, (None, None))
        wname = wr[off][0] if off in wr else None
        rname = rd[off][0] if off in rd else None
        sname = six.get(off)
        where = []
        if sname:
            where.append("sinks")
        if off in wr:
            where.append("wr")
        if off in rd:
            where.append("rd")
        # expected name from the RTL side
        rtlname = sname or rname or wname
        acc = ACC_RW if (off in wr or (sname and sname in swritable)) else ACC_RO
        msgs = []
        if hname is None:
            msgs.append("not in header")
        elif rtlname is None:
            msgs.append("header only, nothing decodes it")
        elif hname != rtlname:
            msgs.append("name header=%s rtl=%s" % (hname, rtlname))
        if hacc and hacc != acc:
            msgs.append("access header=%s rtl=%s" % (hacc, acc))
        if sname and (off in wr or off in rd):
            msgs.append("decoded BOTH in the top and in ct_trace_sinks")
        if (not sname) and off in wr and off not in rd:
            msgs.append("writable but not readable")
        bad += bool(msgs)
        print("  0x%02X  header=%-11s rtl=%-11s acc=%-2s via=%-12s %s"
              % (off, hname, rtlname, acc, ",".join(where) or "-",
                 "ok" if not msgs else "MISMATCH: " + "; ".join(msgs)))

    print("== result ==")
    print("REGMAP %s (%d mismatch(es))" % ("PASS" if bad == 0 else "FAIL", bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
