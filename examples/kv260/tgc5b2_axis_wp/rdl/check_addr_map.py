#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""The device RDL and the board tooling must name the same addresses.

`ct_tgc5b2_kv260.rdl` is hand-written: the CTRL, WPCTRL and router blocks are
hand-implemented RTL, so nothing generates the map and nothing would notice it
going stale. A register map that has drifted from the design is worse than no
map -- a reader who trusts it poke at the wrong address and gets a bus hang,
not an error message.

So this compares the elaborated RDL against the constants the board tooling
actually drives:

  board/wp_board.py   CTRL_BASE, ENC_BASE[], RAM_BASE[], WPCTRL_BASE, MAGIC_EXP
  board/run_a.sh      the two --base arguments of the FIFO reader

Both sides are independent of each other and both are exercised on hardware,
which is what makes the comparison worth anything.

Not covered, so the hole is visible: the register OFFSETS inside CTRL and
WPCTRL are transcribed from the RTL headers by hand. Only the block base
addresses and the magic value are cross-checked here. The encoder CSR offsets
need no check -- they come from rdl/ct_cs_cpuif.rdl, the same source the RTL
is generated from.

Exit 0 = agree, 1 = mismatch, 3 = cannot check (systemrdl-compiler missing).
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
EX = HERE.parent
REPO = EX.parent.parent.parent
RDL = HERE / "ct_tgc5b2_kv260.rdl"


def main() -> int:
    try:
        from systemrdl import RDLCompiler
    except ImportError:
        print("[check_addr_map] systemrdl-compiler not installed -- not checkable here")
        return 3

    c = RDLCompiler()
    c.compile_file(str(RDL), incl_search_paths=[str(REPO / "rdl"), str(HERE)])
    top = c.elaborate(top_def_name="tgc5b2_kv260_top").top
    at = lambda path: top.find_by_path(path).absolute_address

    board = (EX / "board" / "wp_board.py").read_text(encoding="utf-8")

    def const(name: str) -> str:
        m = re.search(rf"^{name}\s*=\s*(.+)$", board, re.M)
        if not m:
            raise SystemExit(f"[check_addr_map] {name} not found in wp_board.py")
        return m.group(1).split("#")[0].strip()

    def listed(name: str) -> list:
        return [x.strip() for x in const(name).strip("[]").split(",") if x.strip()]

    bad = []

    def chk(what: str, tooling: str, rdl_addr: int) -> None:
        got = int(tooling, 0)
        if got != rdl_addr:
            bad.append(f"{what}: tooling {got:#x} != RDL {rdl_addr:#x}")

    chk("CTRL_BASE", const("CTRL_BASE"), at("soc.ctrl"))
    enc = listed("ENC_BASE")
    chk("ENC_BASE[0]", enc[0], at("soc.enc0"))
    chk("ENC_BASE[1]", enc[1], at("soc.enc1"))
    ram = listed("RAM_BASE")
    chk("RAM_BASE[0]", ram[0], at("soc.ram0"))
    chk("RAM_BASE[1]", ram[1], at("soc.ram1"))
    chk("WPCTRL_BASE", const("WPCTRL_BASE"), at("wpctrl"))

    magic = list(top.find_by_path("wpctrl.magic").fields())[0].get_property("reset")
    chk("MAGIC", const("MAGIC_EXP"), magic)

    run_a = (EX / "board" / "run_a.sh").read_text(encoding="utf-8")
    fifos = sorted(set(re.findall(r"--base (0x[0-9A-Fa-f]+)", run_a)))
    if len(fifos) != 2:
        bad.append(f"run_a.sh names {len(fifos)} FIFO base(s), expected 2")
    for i, f in enumerate(fifos[:2]):
        chk(f"FIFO{i}", f, at(f"fifo{i}"))

    if bad:
        print("[check_addr_map] FAIL -- the device RDL disagrees with the board tooling:")
        for b in bad:
            print(f"    {b}")
        return 1

    nregs = sum(1 for n in top.descendants() if n.__class__.__name__ == "RegNode")
    print(f"[check_addr_map] OK: 9 base address(es) + MAGIC agree; "
          f"{nregs} registers in the device map")
    return 0


if __name__ == "__main__":
    sys.exit(main())
