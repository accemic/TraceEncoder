#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Protocol-discovery drift guard: the two discovery mirrors stay hw-driven.

Since P9 the trace protocol is a synthesis parameter of the encoder
INSTANCE (ct_encoder EN_NTRACE / EN_ETRACE), and the two registers that
report it to software are read-only mirrors driven by hardware:

    trTeImpl.ProtocolMajor  0x004[19:16]   1 = N-Trace 1.x, 2 = E-Trace 2.x
    trTeProtocolSel.Protocol 0x030[0]      0 = N-Trace,     1 = E-Trace

The dangerous regression is silent: `rdl/ct_cs_cpuif.rdl` loses the
`sw = r; hw = w;` pair (a merge, a copy/paste, a profile `ifdef), somebody
regenerates the register block with scripts/gen_rdl.sh, and the fields are
software-WRITABLE constants again -- exactly the retired runtime select.
Nothing else in the suite fails: a single-protocol build reads the same
value either way, and only a mixed SoC (or a write) would expose it.

This guard therefore pins all four places the P9 change touched:

  1. rdl/ct_cs_cpuif.rdl          both fields declare `sw = r; hw = w;`
  2. rtl/pkg/ct_cs_cpuif_wb.sv    both hwif_in.*.next are driven from the
                                  EN_ETRACE parameter (not from a constant)
  3. rtl/pkg/ct_cs_cpuif.sv       the GENERATED block reads back from
                                  hwif_in, decodes 0x030 read-only and keeps
                                  no field storage for either field
  4. rtl/pkg/ct_cs_micro.sv       the hand-written CF-slim twin does the same

Exit 0 = OK, 1 = drift (with the offending file/expectation named).
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

failures = []


def fail(where: str, msg: str) -> None:
    failures.append(f"  [FAIL] {where}: {msg}")


def read(rel: str) -> str:
    p = REPO / rel
    if not p.is_file():
        fail(rel, "file not found")
        return ""
    return p.read_text(encoding="utf-8", errors="replace")


def check_rdl() -> None:
    rel = "rdl/ct_cs_cpuif.rdl"
    text = read(rel)
    if not text:
        return
    # field { <body> } <name>[<bits>] -- the body carries the access pair.
    for name, bits in (("ProtocolMajor", "19:16"), ("Protocol", "0:0")):
        pat = re.compile(r"field\s*\{([^{}]*)\}\s*" + name +
                         r"\s*\[" + re.escape(bits) + r"\]")
        m = pat.search(text)
        if not m:
            fail(rel, f"no `field {{...}} {name}[{bits}]` declaration found")
            continue
        body = m.group(1)
        if not re.search(r"\bsw\s*=\s*r\s*;", body):
            fail(rel, f"{name}[{bits}] is not declared `sw = r;` "
                      "(software must not be able to write the discovery)")
        if not re.search(r"\bhw\s*=\s*w\s*;", body):
            fail(rel, f"{name}[{bits}] is not declared `hw = w;` "
                      "(the value must come from the instance parameter)")


def check_cpuif_wb() -> None:
    rel = "rtl/pkg/ct_cs_cpuif_wb.sv"
    text = read(rel)
    if not text:
        return
    for expr, what in (
        (r"assign\s+hwif_in\.te\.trTeProtocolSel\.Protocol\.next\s*=\s*[^;]*EN_ETRACE",
         "trTeProtocolSel.Protocol driven from the EN_ETRACE parameter"),
        (r"assign\s+hwif_in\.te\.trTeImpl\.ProtocolMajor\.next\s*=\s*[^;]*EN_ETRACE",
         "trTeImpl.ProtocolMajor driven from the EN_ETRACE parameter"),
    ):
        if not re.search(expr, text):
            fail(rel, f"missing: {what}")
    if not re.search(r"\bbit\s+EN_ETRACE\s*=\s*ct_pkg::CT_EN_ETRACE", text):
        fail(rel, "parameter `EN_ETRACE = ct_pkg::CT_EN_ETRACE` is gone -- "
                  "the shim would fall back to a profile-wide constant")


def check_generated() -> None:
    rel = "rtl/pkg/ct_cs_cpuif.sv"
    text = read(rel)
    if not text:
        return
    for expr, what in (
        (r"readback_data_var\[19:16\]\s*=\s*hwif_in\.te\.trTeImpl\.ProtocolMajor\.next",
         "ProtocolMajor read back from hwif_in"),
        (r"readback_data_var\[0\]\s*=\s*hwif_in\.te\.trTeProtocolSel\.Protocol\.next",
         "trTeProtocolSel.Protocol read back from hwif_in"),
        (r"decoded_reg_strb\.te\.trTeProtocolSel\s*=[^;]*!cpuif_req_is_wr",
         "0x030 decoded for READS only (no write strobe)"),
    ):
        if not re.search(expr, text):
            fail(rel, f"missing: {what} -- regenerated from a writable RDL?")
    # A software-writable field gets storage + a next-value mux; a pure
    # hw=w mirror does not.
    for stray in (r"field_storage\.te\.trTeProtocolSel\.Protocol",
                  r"field_storage\.te\.trTeImpl\.ProtocolMajor",
                  r"hwif_out\.te\.trTeProtocolSel\.Protocol",
                  r"hwif_out\.te\.trTeImpl\.ProtocolMajor"):
        if re.search(stray, text):
            fail(rel, f"`{stray}` is back -- the field is software-writable "
                      "again (P9 made it a read-only hw mirror)")


def check_micro() -> None:
    rel = "rtl/pkg/ct_cs_micro.sv"
    text = read(rel)
    if not text:
        return
    for expr, what in (
        (r"15'h4:.*?hwif_in\.te\.trTeImpl\.ProtocolMajor\.next",
         "0x004 arm reads ProtocolMajor from hwif_in"),
        (r"15'h30:\s*(//[^\n]*\n\s*)?s_cpuif_rd_data\[0\]\s*=\s*"
         r"hwif_in\.te\.trTeProtocolSel\.Protocol\.next",
         "0x030 arm reads Protocol from hwif_in"),
    ):
        if not re.search(expr, text, re.S):
            fail(rel, f"missing: {what} -- the CF-slim CSR twin would report "
                      "a wrong or constant protocol")


def main() -> int:
    check_rdl()
    check_cpuif_wb()
    check_generated()
    check_micro()
    if failures:
        for f_ in failures:
            print(f_)
        print(f"[check_protocol_discovery] {len(failures)} failure(s)")
        return 1
    print("[check_protocol_discovery] OK: 2 discovery fields hw-driven "
          "(RDL sw=r/hw=w, wb shim from EN_ETRACE, generated block read-only "
          "from hwif_in, micro-CSR twin identical)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
