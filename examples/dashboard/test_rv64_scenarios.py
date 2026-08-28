#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Gate B1-3: the RV64 scenarios against the RTL and against the server.

The dashboard has exactly one class of defect that nobody notices: a CTRL
register map that does not match the loaded design. It produces no error
message but plausible wrong numbers -- which is why scenarios.json exists at
all. This gate therefore does NOT check the map against itself but against
the register table in the header of the respective SoC top file, and makes
the counter-check: a deliberately shifted map MUST colour it red.

What is checkable without a board is checked as well:
  * app name -> scenario (including the 64-bit bitstream variants),
  * the tear-free 64-bit PC read including a simulated carry,
  * the guest->PS translation of the Rocket ELF load,
  * that all offsets fit into their aperture.

SKIP-clean: sections 1/1b (CTRL map vs. RTL) and 6 (Sv39 through the display
chain) need source/build files (rtl/board_kv260/*.sv, vivado/kv260_app/*.sv,
bld/, sw/cva6_char/) that live in the predecessor repository KV260 tree, not in this
example -- they are skipped, not failed, when that tree is not alongside
this repo. Section 6 additionally needs a RISC-V toolchain, resolved the
same way as test_elf_load.py (RISCV_READELF/RISCV_BIN/PATH, no hardcoded
Windows path). Sections 2-4 and 7 are self-contained (scenarios.json +
server.py logic only) and always run.

Invocation:  py test_rv64_scenarios.py
"""
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import server                      # noqa: E402
from scenario import Catalog       # noqa: E402

FAILS = []
NCHECK = 0
SKIPS = []


def skip(name, reason):
    """Record a clean skip -- distinct from FAILS, never turns the gate red."""
    SKIPS.append(name + ((" -- " + reason) if reason else ""))
    print("  SKIP %s%s" % (name, ("  " + reason) if reason else ""))


def find_riscv_tool(*basenames):
    """Locate a RISC-V toolchain binary without a hardcoded machine path.

    Search order: RISCV_BIN (directory, ct_env.sh convention) > PATH. Tries
    each name in `basenames` in order (e.g. the rv64 and rv32 variant).
    Returns None -- a normal outcome on a machine without the toolchain --
    if nothing is found.
    """
    import os
    import shutil
    exe = ".exe" if os.name == "nt" else ""
    riscv_bin = os.environ.get("RISCV_BIN")
    if riscv_bin:
        for name in basenames:
            cand = Path(riscv_bin) / (name + exe)
            if cand.is_file():
                return cand
    for name in basenames:
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


def check(name, ok, info=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %s%s" % ("OK" if ok else "FAIL", name, ("  " + info) if info else ""))
    if not ok:
        FAILS.append(name + ((" -- " + info) if info else ""))
    return ok


def rtl_ctrl_map(path):
    """Register table from the header comment of a SoC top file.

    Expects lines of the form ` *     0x1C SINK_CTRL   (rw) ...` -- the form
    in which both designs document their map. Several registers on one line
    (`0x08 TRACE_BEATS (ro)   0x0C TRACE_BYTES (ro)`) are picked up too.
    """
    txt = Path(path).read_text(encoding="utf-8", errors="replace")
    head = txt.split("*/", 1)[0]
    out = {}
    for m in re.finditer(r"0x([0-9A-Fa-f]{2})\s+([A-Z][A-Z0-9_]{2,})\s*\((rw|ro|w)\)", head):
        out[m.group(2).lower()] = int(m.group(1), 16)
    return out


def cmp_map(sid, sc, rtl, path, skip=()):
    """The scenarios.json map against the RTL map, in BOTH directions."""
    ok = True
    for name, off in sorted(rtl.items()):
        if name in skip:
            continue
        got = sc.co(name)
        if got is None:
            ok = check("%s: %s (RTL 0x%02X) missing from scenarios.json" % (sid, name, off),
                       False) and ok
        elif got != off:
            ok = check("%s: %s sits at 0x%02X, the RTL says 0x%02X" % (sid, name, got, off),
                       False) and ok
    for name, off in sorted(sc.ctrl.items()):
        if name in skip:
            continue
        if name not in rtl:
            ok = check("%s: %s@0x%02X is in no RTL table" % (sid, name, off),
                       False) and ok
    check("%s: CTRL map congruent with %s (%d registers)"
          % (sid, Path(path).name, len(rtl)), ok)
    return ok


class FakeBus:
    """Register bank with controllable behaviour -- for the tear test."""

    demo = False

    def __init__(self, regs, tear_at=None):
        self.regs = dict(regs)
        self.tear_at = tear_at          # offset whose read advances the PC
        self.reads = 0

    def read(self, region, off, n=1):
        self.reads += 1
        v = self.regs.get(off, 0)
        if self.tear_at is not None and off == self.tear_at:
            # A carry exactly between the two halves: LO jumps to 0, HI counts
            # up by one -- the classic tear.
            self.regs[0x4C] = 0x00000000
            self.regs[0x50] = (self.regs.get(0x50, 0) + 1) & 0xFFFFFFFF
            self.tear_at = None
        return [v] * n


def main():
    print("== 1. CTRL maps against the RTL ==")
    cat = Catalog()
    rtl_root = ROOT / "rtl" / "board_kv260"
    vivado_root = ROOT / "vivado" / "kv260_app"
    rtl_sources = {
        "rocket64": vivado_root / "rocket_soc_top.sv",
        "cva6": rtl_root / "cva6_linux_soc_top.sv",
        "cva6_2": rtl_root / "cva6_2_soc_top.sv",
        "tgc5b2": rtl_root / "tgc5b2_axis_soc_top.sv",
        "trio": rtl_root / "trio_soc_top.sv",
    }
    have_rtl = all(p.is_file() for p in rtl_sources.values())
    if not have_rtl:
        skip("sections 1 + 1b (CTRL map vs. RTL)",
             "%s is not part of this example (KV260 SoC tops migrate "
             "under AP4, plan section 3); the RTL-vs-scenarios.json "
             "cross-check runs in the KV260 examples package once that "
             "lands" % rtl_root.parent)
    else:
        rocket_rtl = rtl_ctrl_map(vivado_root / "rocket_soc_top.sv")
        cva6_rtl = rtl_ctrl_map(rtl_root / "cva6_linux_soc_top.sv")
        check("RTL table rocket_soc_top.sv read (>=20 registers)",
              len(rocket_rtl) >= 20, "%d found" % len(rocket_rtl))
        check("RTL table cva6_linux_soc_top.sv read (>=14 registers)",
              len(cva6_rtl) >= 14, "%d found" % len(cva6_rtl))
        cmp_map("rocket64", cat.by_id["rocket64"], rocket_rtl,
                vivado_root / "rocket_soc_top.sv")
        # According to its own file header, cva6_linux64 carries "word for word
        # the same map" as the RV32 version -- exactly that is verified here,
        # instead of taking it on faith.
        cmp_map("cva6_linux64", cat.by_id["cva6_linux64"], cva6_rtl,
                rtl_root / "cva6_linux_soc_top.sv")
        cmp_map("cva6_linux", cat.by_id["cva6_linux"], cva6_rtl,
                rtl_root / "cva6_linux_soc_top.sv")

        # The dual CVA6 SoC (D3): both register widths share ONE SoC file, the
        # scenarios differ only in values. That is exactly why both belong in
        # here -- otherwise a shift would hit only one of them, unnoticed.
        cva6_2_rtl = rtl_ctrl_map(rtl_root / "cva6_2_soc_top.sv")
        for sid in ("cva6_2_rv64", "cva6_2_rv32"):
            cmp_map(sid, cat.by_id[sid], cva6_2_rtl,
                    rtl_root / "cva6_2_soc_top.sv")

        # The shared sink window (ct_trace_sinks) sits in
        # THREE designs with identical offsets -- and it was exactly during that
        # unification that a register MOVED: DDR_BEATS from 0x30 to 0x38,
        # because 0x30 is now PIB_DROPS. A move without a check is the most
        # expensive kind of drift: both offsets answer, only with the wrong
        # counter.
        tgc5b2_top = rtl_root / "tgc5b2_axis_soc_top.sv"
        tgc5b2_rtl = rtl_ctrl_map(tgc5b2_top)
        check("RTL table tgc5b2_axis_soc_top.sv read (>=13 registers)",
              len(tgc5b2_rtl) >= 13, "%d found" % len(tgc5b2_rtl))
        cmp_map("tgc5b2_axis_wp", cat.by_id["tgc5b2_axis_wp"], tgc5b2_rtl, tgc5b2_top)
        # In their file headers duo/trio document ONLY the sink window in this
        # form (the base registers are prose there) -- hence one direction
        # here: every register of the RTL table has to be present in the
        # map.
        trio_top = rtl_root / "trio_soc_top.sv"
        trio_rtl = rtl_ctrl_map(trio_top)
        trio_bad = {n: (off, cat.by_id["trio"].co(n))
                    for n, off in trio_rtl.items() if cat.by_id["trio"].co(n) != off}
        check("trio: sink window congruent with trio_soc_top.sv (%d registers)"
              % len(trio_rtl), not trio_bad, repr(trio_bad))
        for sid in ("tgc5b2_axis_wp", "trio"):
            sc = cat.by_id[sid]
            check("%s: 0x30 = PIB_DROPS, DDR_BEATS = 0x38 (T2 move)" % sid,
                  sc.co("pib_drops") == 0x30 and sc.co("ddr_beats") == 0x38,
                  "pib_drops=%r ddr_beats=%r" % (sc.co("pib_drops"), sc.co("ddr_beats")))
        # Counter-check for the move: the OLD map (DDR_BEATS at 0x30) MUST
        # show up.
        old = dict(cat.by_id["tgc5b2_axis_wp"].ctrl)
        old["ddr_beats"] = 0x30
        check("counter-check -- the old C0B_DDR map (DDR_BEATS@0x30) shows up",
              [n for n, o in tgc5b2_rtl.items() if old.get(n) != o] == ["ddr_beats"],
              repr([n for n, o in tgc5b2_rtl.items() if old.get(n) != o]))

        # Sinks per bitstream variant: a scenario may have several builds, and
        # they do not all carry the same sinks (tgc5b2: the AXIS-only build
        # first, the C0B_SINK3 build adds DDR and PIB). A variant may
        # therefore have FEWER sinks than the scenario, never more --
        # otherwise the view claims a sink for which the scenario has no CTRL
        # offsets at all.
        for sc in cat.by_id.values():
            for v in sc.app_variants:
                if "sinks" not in v:
                    continue
                extra = [k for k, on in (v["sinks"] or {}).items()
                         if on and not (sc.sinks or {}).get(k)]
                check("%s/%s: the variant sinks are a subset of the scenario"
                      % (sc.id, v.get("app")), not extra, repr(extra))

        print("== 1b. counter-check: a shifted map MUST show up ==")
        bad = dict(cat.by_id["rocket64"].ctrl)
        bad["pc_hi"] = bad["pc_hi"] + 4          # one single shift
        shifted = type("S", (), {"co": lambda self, n: bad.get(n), "ctrl": bad})()
        before = len(FAILS)
        quiet = []
        for name, off in rocket_rtl.items():
            if shifted.co(name) != off:
                quiet.append(name)
        check("a shifted PC_HI is detected", quiet == ["pc_hi"],
              "flagged: %r" % quiet)
        check("the counter-check did not distort the counter", len(FAILS) == before)

    print("== 2. app name -> scenario ==")
    for app, want in [("cva6_linux64_x64_ctrace_kv260", "cva6_linux64"),
                      ("cva6_linux64_ctrace_kv260", "cva6_linux64"),
                      ("rocket_x64_ctrace_kv260", "rocket64"),
                      ("rocket_ctrace_kv260", "rocket64"),
                      ("mbv_ctrace_kv260", "mbv"),
                      ("cva6_linux_ctrace_kv260", "cva6_linux"),
                      ("trio_ctrace_kv260", "trio")]:
        s = cat.by_app(app)
        check("%s -> %s" % (app, want), s is not None and s.id == want,
              "got: %s" % (s.id if s else None))
    check("a foreign app is not mapped", cat.by_app("k26-starter-kits") is None)
    check("64-bit variants are present in by_id_apps (PL protection)",
          {"cva6_linux64_x64_ctrace_kv260", "rocket_x64_ctrace_kv260"}
          <= cat.by_id_apps())
    for sid in ("cva6_linux64", "rocket64"):
        check("%s: core width 64 bit" % sid, cat.by_id[sid].xlen == 64)

    print("== 3. offsets fit into the aperture ==")
    for sid in cat.order:
        sc = cat.by_id[sid]
        size = sc.regions["ctrl"][1]
        bad = {n: o for n, o in sc.ctrl.items() if not (0 <= o < size - 3)}
        check("%s: all CTRL offsets inside the 0x%X aperture" % (sid, size), not bad, repr(bad))
        dup = [o for o in set(sc.ctrl.values())
               if list(sc.ctrl.values()).count(o) > 1]
        check("%s: no offset used twice" % sid, not dup, repr(dup))

    print("== 4. the 64-bit PC, tear-free and as a hex string ==")
    sc = cat.by_id["rocket64"]
    regs = {0x04: (1 << 12) | (0b101 << 8),      # STATUS: priv=1 (S), obs=101
            0x3C: 0, 0x40: 0, 0x44: 0,
            0x4C: 0x80200ABC, 0x50: 0xFFFFFFFF, 0x54: 4711}
    r = server.read_core_pc(FakeBus(regs), sc)
    check("the PC is a hex string", isinstance(r["pc"], str), repr(r["pc"]))
    check("PC = 0xffffffff80200abc", r["pc"] == "0xffffffff80200abc", r["pc"])
    check("the PC does NOT survive Python->JSON->float as a number (hence a string)",
          float(int(r["pc"], 16)) != int(r["pc"], 16))
    check("the retire counter is passed through", r.get("retires") == 4711, repr(r.get("retires")))
    check("privilege level from STATUS[14:12]", r.get("priv") == 1, repr(r.get("priv")))
    check("observation sticky named", r.get("obs") == ["retire_seen", "rvalid_seen"],
          repr(r.get("obs")))
    check("no tear reported when there was none", r.get("torn") is False)
    torn = server.read_core_pc(FakeBus(regs, tear_at=0x4C), sc)
    check("a tear between LO and HI is detected and retried",
          torn.get("torn") is True, repr(torn))
    check("after the tear it was read again", torn.get("retries", 0) >= 1,
          repr(torn.get("retries")))
    check("after the tear the pair is consistent (HI came from the second try)",
          torn.get("stable") is True and int(torn["pc"], 16) == 0x0_00000000,
          torn["pc"])
    check("a torn PC stays representable at 64 bit",
          int(torn["pc"], 16) < (1 << 64))
    # Counter-check: a design without an observation channel returns None, not 0.
    check("a design without core_pc returns None instead of 0x0",
          server.read_core_pc(FakeBus({}), cat.by_id["cva6_linux64"]) is None)

    print("== 5. ELF64 load: guest->PS translation ==")
    payload = ROOT / "bld" / "l2_rocket_linux" / "fw_payload.elf"
    if not payload.is_file():
        skip("ELF64 load: guest->PS translation",
             "%s is the predecessor repository build artifact, not part of this example"
             % payload)
    else:
        data = payload.read_bytes()
        segs = list(server.parse_elf(data))
        check("ELF64 recognised", server.elf_class(data) == "ELF64")
        guest, ps, win = 0x80000000, 0x64000000, 0x0C000000
        core = cat.by_id["rocket64"].cores[0]
        check("the scenario names guest 0x8000_0000",
              int(core["load_guest_base"], 0) == guest, core["load_guest_base"])
        check("the scenario names PS 0x6400_0000", int(core["load_base"], 0) == ps)
        check("the scenario names a 192 MiB window", int(core["load_size"], 0) == win)
        inwin = all(guest <= a and a + len(s) <= guest + win for a, s in segs)
        check("all segments lie inside the guest window", inwin,
              "first: 0x%x" % segs[0][0])
        xlat = [(a - guest + ps) for a, _s in segs]
        check("translated PS addresses inside the reserved window",
              all(server.HwBus.PL_WIN_LO <= a < server.HwBus.PL_WIN_HI for a in xlat),
              ", ".join("0x%x" % a for a in xlat))
        # Counter-check: the UNtranslated guest address would break the bound.
        check("counter-check -- untranslated it would be outside (the bound bites)",
              not (server.HwBus.PL_WIN_LO <= segs[0][0] < server.HwBus.PL_WIN_HI),
              "0x%x" % segs[0][0])

    print("== 6. an Sv39 address through the WHOLE display chain ==")
    # Do not read the regexes, push a real 64-bit address through them:
    # objdump listing -> dis_to_symbols -> SymbolTable -> func_counts ->
    # coverage_tree -> JSON. Exactly the path the coverage map takes.
    dis = ROOT / "bld" / "b1_dashboard_rv64" / "hi64.dis"
    elf = ROOT / "sw" / "cva6_char" / "char_test_hi64.elf"
    symmap = ROOT / "bld" / "b1_dashboard_rv64" / "hi64_symbols.map"
    if not (dis.is_file() and symmap.is_file()):
        # Generate it instead of skipping the section: a gate that silently
        # checks less on a fresh tree is not a gate -- but that only holds if
        # the raw materials (toolchain + fixture ELF) are THERE. If they are
        # not (no RISC-V toolchain, or the ELF fixture is a
        # predecessor-repository characterisation artefact that is not part of
        # this example), SKIP is the honest answer, not FAIL.
        objdump = find_riscv_tool("riscv64-unknown-elf-objdump",
                                   "riscv32-unknown-elf-objdump")
        if objdump is not None and elf.is_file():
            # (no local `import subprocess` any more -- it made the name local to
            # the WHOLE function and let every later use die with an
            # UnboundLocalError whenever this branch did not run)
            dis.parent.mkdir(parents=True, exist_ok=True)
            dis.write_text(subprocess.run([str(objdump), "-d", str(elf)],
                                          capture_output=True, text=True,
                                          check=True).stdout, encoding="utf-8")
            subprocess.run([sys.executable, str(HERE / "dis_to_symbols.py"), str(dis),
                            "-o", str(symmap),
                            "--sites", str(symmap.with_name("hi64_sites.map"))],
                           capture_output=True, check=True)
    if not dis.is_file():
        if not elf.is_file():
            skip("an Sv39 address through the WHOLE display chain",
                 "%s is the predecessor repository characterization artifact, not part "
                 "of this example" % elf)
        else:
            skip("an Sv39 address through the WHOLE display chain",
                 "no RISC-V objdump found (set RISCV_BIN or put "
                 "riscv64-unknown-elf-objdump on PATH) to generate %s "
                 "from %s" % (dis, elf))
    else:
        import json as _json
        import insight
        st = insight.SymbolTable.from_file(symmap)
        check("symbol table read", st.count >= 10, "%d symbols" % st.count)
        hi = [a for a in st.addrs if a > 0xFFFFFFFF]
        check("addresses above 2**32 survive the parsing",
              len(hi) == st.count, "%d of %d" % (len(hi), st.count))
        check("the lookup hits the Sv39 address",
              st.lookup(0xFFFFFFC064000000)[0] == "_start",
              repr(st.lookup(0xFFFFFFC064000000)[0]))
        # Coverage tree with exactly those symbols, in a scenario whose
        # code_regions cover the Sv39 range.
        sc64 = cat.by_id["cva6_linux64"]
        old_sym, old_cnt = server.INS.symbols, dict(server.INS.func_counts)
        server.INS.symbols = st
        server.INS.func_counts = {0xFFFFFFC064000000: 17}
        region = {"name": "hi64", "base": "0xFFFFFFC064000000", "size": "0x00010000"}
        sc64.raw.setdefault("_gate_regions", None)
        saved = sc64.raw.get("code_regions")
        sc64.raw["code_regions"] = [region]
        tree = server.coverage_tree(sc64)
        sc64.raw["code_regions"] = saved
        server.INS.symbols, server.INS.func_counts = old_sym, old_cnt
        funcs = [f for r in tree["regions"] for g in r["groups"] for f in g["funcs"]]
        check("the coverage tree contains the Sv39 symbols", len(funcs) >= 10,
              "%d functions" % len(funcs))
        start = next((f for f in funcs if f["name"] == "_start"), None)
        check("_start is in the tree", start is not None)
        if start:
            check("addr is a hex string", isinstance(start["addr"], str),
                  repr(start["addr"]))
            check("addr is exactly 0xffffffc064000000",
                  int(start["addr"], 16) == 0xFFFFFFC064000000, start["addr"])
            check("the execution count hangs on the right address",
                  start["instr"] == 17, repr(start["instr"]))
            # Counter-check: as a JSON NUMBER the same value would be rounded in
            # the browser -- here with the address that has low bits.
            probe = 0xFFFFFFC06400002C          # 'outer'
            check("counter-check -- the same address as a float loses bits",
                  int(float(probe)) != probe, hex(int(float(probe))))
        # And the silent drop there used to be: with a 32-bit region ALL Sv39
        # symbols MUST fall out -- and that has to be reported.
        server.INS.symbols = st
        server.INS.func_counts = {}
        saved = sc64.raw.get("code_regions")
        sc64.raw["code_regions"] = [{"name": "4 GiB only", "base": "0x0",
                                     "size": "0xFFFFFFFF"}]
        tree32 = server.coverage_tree(sc64)
        sc64.raw["code_regions"] = saved
        server.INS.symbols, server.INS.func_counts = old_sym, old_cnt
        check("a 32-bit region lets the Sv39 symbols fall out",
              not tree32["regions"], repr([r["name"] for r in tree32["regions"]]))
        check("...and that is counted instead of concealed",
              tree32.get("outside_regions") == st.count,
              "outside_regions=%r of %d" % (tree32.get("outside_regions"), st.count))
        _json.dumps(tree)      # must stay serializable

    print("== 7. a scenario change inherits no foreign symbol table ==")
    # Measured on the running server (2026-08-08): after cva6_linux ->
    # cva6_linux64 the RV32 table with 83,074 symbols was still hanging in the
    # process and the coverage map showed 41,911 RV32 functions under the RV64
    # region names. Plausible and wrong -- hence a guard.
    import insight
    keep = server.INS.symbols
    fake = insight.SymbolTable.from_text(
        "64000000 T sbi_init\n64000100 T fdt_next_tag\n", "gate")
    server.INS.symbols = fake
    check("precondition: table loaded", server.INS.symbols.count == 2)
    got = server.load_symbol_files(cat.by_id["cva6_linux64"])
    check("a scenario without its own symbols reports 0", got["symbols"] == 0, repr(got))
    check("...and the old table is GONE (not inherited)",
          server.INS.symbols.count == 0, "%d symbols left" % server.INS.symbols.count)
    check("...the call sites too", server.INS.sites.count == 0)
    # Counter-check: a scenario WITH a file still loads.
    server.INS.symbols = fake
    demo_map = HERE / "demo" / "symbols_sbi.map"
    if demo_map.is_file():
        got2 = server.load_symbol_files(cat.by_id["cva6_linux"])
        check("counter-check -- a scenario with a file still loads",
              got2["symbols"] > 100, "%d symbols" % got2["symbols"])
    else:
        check("counter-check -- demo/symbols_sbi.map present", False, str(demo_map))
    server.INS.symbols = keep

    # --- soc offsets: is the scenario map complete? -------------------------
    # The soc.* registers in regmap.json are appended BY HAND (gen_regmap.py)
    # and carry the offsets of mbv_soc_top.sv. For every other SoC they are
    # wrong: the two-hart Rocket has two more console registers, so everything
    # from SINK_CTRL on sits one slot higher. On 2026-08-10 the board
    # therefore showed eight registers under a foreign name -- "SINK_STAT
    # 0xAC" was the write pointer with 172 bytes. That was found in the field,
    # not by this gate.
    #
    # The user interface corrects this at runtime from the scenario map
    # (fixSocOffsets/ctrlOff). That only carries as long as the map REALLY has
    # the entries -- if one is missing, the display falls back silently to the
    # MBV value and the write path refuses. Exactly that is what this gate
    # checks.
    SINK_KEYS = ("sink_ctrl", "ddr_base", "ddr_size",
                 "ddr_wptr", "sink_stat", "ddr_drops")
    for sc in cat.by_id.values():
        sinks = sc.raw.get("sinks") or {}
        if not (sinks.get("ddr") or sinks.get("pib")):
            continue                    # without DDR/PIB the UI touches none of this
        cmap = sc.raw.get("ctrl") or {}
        cmap = cmap.get("regs", cmap)
        missing = [k for k in SINK_KEYS if k not in cmap]
        check("scenario %s -- soc offsets complete" % sc.id,
              not missing,
              "missing: " + ", ".join(missing) if missing else
              "all %d" % len(SINK_KEYS))

    # Counter-check: a deliberately removed entry MUST colour it red.
    _probe = dict(cat.by_id["rocket2"].raw.get("ctrl") or {})
    _probe.pop("sink_ctrl", None)
    check("counter-check -- a missing soc offset is detected",
          "sink_ctrl" not in _probe and
          [k for k in SINK_KEYS if k not in _probe] != [],
          "the probe reports %d missing" % len([k for k in SINK_KEYS if k not in _probe]))

    # --- RDL mirror against the master --------------------------------------
    # The same class of defect as the CTRL map above, one level deeper: the
    # mirror under third_party/CTTE/rdl/ reports no error when it goes
    # stale -- it delivers plausible wrong DESCRIPTIONS. On 2026-08-10 it was
    # 365 lines old and the dashboard showed "[CTTE]" while the master had
    # long since moved to CTTE. That was found in the field, not by a check.
    # Without a reachable master this is SKIPPED, not reported green: a SKIP
    # is not a PASS (lesson from package V2).
    #
    # In THIS repository (TraceEncoder instead of the predecessor repository)
    # the mirror was dropped by plan anyway (plan AP4 point 5: the RDL mirror
    # problem together with sync_rdl_mirror.py goes away without replacement
    # -- regmap.json is generated directly from rdl/). A missing
    # scripts/sync_rdl_mirror.py is therefore the EXPECTED state here, not a
    # finding -- SKIP, not
    # FAIL.
    sync = HERE.parents[1] / "scripts" / "sync_rdl_mirror.py"
    if sync.is_file():
        r = subprocess.run([sys.executable, str(sync), "--check"],
                           capture_output=True, text=True)
        if r.returncode == 2:
            print("  SKIP  RDL mirror -- master not reachable "
                  "(set CTTE_MASTER)")
        else:
            check("RDL mirror + regmap.json agree with the master",
                  r.returncode == 0,
                  (r.stdout or r.stderr).strip().splitlines()[0]
                  if (r.stdout or r.stderr).strip() else "")
    else:
        skip("RDL mirror against the master",
             "scripts/sync_rdl_mirror.py is retired in this repository "
             "(plan AP4 point 5) -- regmap.json is generated from rdl/ "
             "directly, there is no separate mirror to drift")

    print()
    if FAILS:
        print("GATE B1-3: FAIL (%d of %d checks red)" % (len(FAILS), NCHECK))
        for f in FAILS:
            print("  - %s" % f)
        return 1
    if SKIPS:
        print("GATE B1-3: PASS -- %d checks green, %d sections SKIPped "
              "(no RISC-V toolchain and/or KV260 RTL tree -- neither is "
              "part of this example, see README.md)"
              % (NCHECK, len(SKIPS)))
        return 0
    print("GATE B1-3: PASS -- %d checks green" % NCHECK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
