#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Gate H3 finding 7 (offline): block click -> CSR relevance, all scenarios.

Rule (2026-08-13): EVERY block of the architecture view shows all CSRs with a
relation when clicked -- including single-bit relevance; "No CSRs directly
attached" may only appear for genuine wiring blocks, and then with a sentence
saying WHERE the control lives.

This test mirrors the resolution of index.html (blockCsrEntry +
resolveBlockCsrs, including the soc.* filter against the CTRL map of the
scenario) and checks, for EVERY scenario of the catalogue and EVERY block
of its geometry:
  * that a mapping exists (mapping entry OR REG_HOME fallback),
  * that the result is never "empty without a note",
  * that all referenced fields exist in the register (typo guard),
  * that soc.* registers without a scenario offset are discarded (no
    plausible wrong numbers).

Since U2 (2026-08-14) also the DATA side of the array folding:
`group_rows()` is the mirror of `groupRegRows()` from index.html and is run
over the real `regmap.json` as well as over every scenario x every block --
parent node `name[min..max]`, complete expanded content, non-array registers
unchanged and flat. That the mirror matches the shipped JS is checked by
test_wp_view.py (the
original code against the same list).

Invocation:  py test_block_csrs.py
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FAILS = []
NCHECK = 0


def check(name, ok, info=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %s%s" % ("OK" if ok else "FAIL", name,
                           ("  " + info) if info else ""))
    if not ok:
        FAILS.append(name + ((" -- " + info) if info else ""))
    return ok


def reg_home(path):
    """Mirror of REG_HOME in index.html -- on drift the field existence check
    or the emptiness check fires."""
    p = path
    if p.startswith("soc."):
        if p in ("soc.TRACE_BEATS", "soc.TRACE_BYTES", "soc.TRACE_BUFSZ"):
            return "uram"
        if p == "soc.AXIS_BEATS":
            return "axis"
        if p.startswith("soc.DDR_") or p in ("soc.SINK_CTRL", "soc.SINK_STAT"):
            return "ddr"
        if p == "soc.PIB_DROPS":
            return "pib"
        if p == "soc.FUNNEL_CTRL":
            return "funnel"
        return "cpu"
    if ".trTeFilter[" in p:
        return "filters"
    if ".trTeComp[" in p:
        return "comps"
    if "trTs" in p:
        return "ts"
    if "TipFifo" in p:
        return "fifo"
    if ".atb." in p:
        return "atb"
    if ".pc." in p:
        return "pc"
    if "trWp" in p:
        return "wp"
    if "trDf" in p:
        return "df"
    if "InstFilters" in p or "DataFilters" in p:
        return "filters"
    return "te"


ARRIDX = re.compile(r"^(.*?)\[(\d+)\]")


def group_rows(labels):
    """Mirror of groupRegRows() from index.html (U2, 2026-08-14).

    Folds every run of identically named indexed instances (`name[0]`,
    `name[1]`, ...) into ONE parent node `name[min..max]`; everything else
    stays a flat row. Grouping starts at TWO different indices, gaps stay ONE
    node and are named in the header.

    The mirror is not a reconstruction on suspicion: test_wp_view.py cuts
    groupRegRows() out of index.html, runs it against the same register list
    and compares the result with group_summary() below. If the JS drifts, the
    comparison goes red there -- rather than this test here going silently
    wrong.

    Returns: a list of
      {"kind": "leaf",  "label": str}
      {"kind": "group", "label": str, "prefix": str, "gaps": [int],
       "insts": {idx: [label, ...]}, "n": int}
    """
    seq, by_prefix = [], {}
    for lb in labels:
        m = ARRIDX.match(lb)
        if not m:
            seq.append({"kind": "leaf", "label": lb})
            continue
        prefix, idx = m.group(1), int(m.group(2))
        g = by_prefix.get(prefix)
        if g is None:
            g = {"kind": "group", "prefix": prefix, "idxs": [], "insts": {},
                 "n": 0}
            by_prefix[prefix] = g
            seq.append(g)
        if idx not in g["insts"]:
            g["insts"][idx] = []
            g["idxs"].append(idx)
        g["insts"][idx].append(lb)
        g["n"] += 1
    out = []
    for e in seq:
        if e["kind"] == "leaf":
            out.append(e)
            continue
        if len(e["idxs"]) < 2:          # one instance = a click without gain
            for idx in e["idxs"]:
                for lb in e["insts"][idx]:
                    out.append({"kind": "leaf", "label": lb})
            continue
        e["idxs"].sort()
        lo, hi = e["idxs"][0], e["idxs"][-1]
        e["label"] = "%s[%d..%d]" % (e["prefix"], lo, hi)
        e["gaps"] = [i for i in range(lo, hi + 1) if i not in e["insts"]]
        out.append(e)
    return out


def group_summary(labels):
    """Normal form for the JS comparison in test_wp_view.py."""
    out = []
    for e in group_rows(labels):
        if e["kind"] == "leaf":
            out.append({"kind": "leaf", "label": e["label"]})
        else:
            out.append({"kind": "group", "label": e["label"],
                        "prefix": e["prefix"], "insts": len(e["insts"]),
                        "n": e["n"], "gaps": e["gaps"]})
    return out


def group_labels(nodes):
    """All rows a node tree actually carries (the expanded content)."""
    out = []
    for e in nodes:
        if e["kind"] == "leaf":
            out.append(e["label"])
        else:
            for idx in sorted(e["insts"]):
                out.extend(e["insts"][idx])
    return out


def resolve(bc, regs, sid, block, sc_ctrl):
    ent_g = (bc.get("blocks") or {}).get(block)
    ent_s = ((bc.get("scenarios") or {}).get(sid) or {}).get(block)
    if not ent_g and not ent_s:
        return None
    note = (ent_s or {}).get("note", (ent_g or {}).get("note", ""))
    csrs = list((ent_g or {}).get("csrs", [])) + \
        list((ent_s or {}).get("csrs", []))
    out, seen = [], set()
    for e in csrs:
        if "home" in e:
            hit = [r for r in regs if reg_home(r["path"]) == e["home"]]
        else:
            hit = [r for r in regs if e["path"] in r["path"]]
        for r in hit:
            if r["path"].startswith("soc.") and \
                    r["path"][4:].lower() not in sc_ctrl:
                continue
            k = (r["region"], r["offset"])
            if k in seen:
                continue
            seen.add(k)
            out.append((r, e.get("fields")))
    return {"note": note, "rows": out}


def main():
    bc = json.loads((HERE / "block_csrs.json").read_text(encoding="utf-8"))
    rm = json.loads((HERE / "regmap.json").read_text(encoding="utf-8"))
    cat = json.loads((HERE / "scenarios.json").read_text(encoding="utf-8"))
    idx = (HERE / "index.html").read_text(encoding="utf-8")
    m = re.search(r"const ARCH_BY_SCEN=(\{.*?\});\n", idx, re.S)
    geo = json.loads(m.group(1)) if m else {}
    regs = rm["regs"]

    print("== mapping hygiene (typo guard) ==")
    by_path = {}
    for r in regs:
        by_path.setdefault(r["path"], r)
    for block, ent in sorted((bc.get("blocks") or {}).items()):
        for e in ent.get("csrs", []):
            if "home" in e:
                hit = [r for r in regs if reg_home(r["path"]) == e["home"]]
                check("blocks.%s home=%s hits registers" % (block, e["home"]),
                      bool(hit), "0 hits")
                continue
            hit = [r for r in regs if e["path"] in r["path"]]
            check("blocks.%s path=%r hits registers" % (block, e["path"]),
                  bool(hit), "0 hits")
            if e.get("fields") and hit:
                names = {f["name"] for r in hit for f in r["fields"]}
                bad = [f for f in e["fields"] if f not in names]
                check("blocks.%s %r: all fields exist"
                      % (block, e["path"]), not bad, "missing: %s" % bad)

    print("== resolution per scenario x geometry block ==")
    for sc in cat["scenarios"]:
        sid = sc["id"]
        sc_ctrl = {k.lower() for k in (sc.get("ctrl") or {})}
        g = geo.get(sid)
        if not check("%s: geometry present" % sid, bool(g)):
            continue
        bases = sorted({re.sub(r"\d+$", "", n["id"]) for n in g["nodes"]})
        for b in bases:
            res = resolve(bc, regs, sid, b, sc_ctrl)
            if res is None:
                # Fallback = the old REG_HOME mapping (chip groups).
                hit = [r for r in regs if reg_home(r["path"]) == b]
                check("%s/%s: REG_HOME fallback not empty" % (sid, b),
                      bool(hit), "no mapping AND no fallback register")
                continue
            ok = bool(res["rows"]) or bool(res["note"])
            check("%s/%s: %d registers%s" % (sid, b, len(res["rows"]),
                  " + note" if res["note"] else ""), ok,
                  "empty WITHOUT a note -- would show 'No CSRs'")
            for r, fields in res["rows"]:
                if r["path"].startswith("soc."):
                    check("%s/%s: %s has a scenario offset" %
                          (sid, b, r["path"]),
                          r["path"][4:].lower() in sc_ctrl)

    print("== spot checks ==")
    sc0 = cat["scenarios"][0]
    ctrl0 = {k.lower() for k in (sc0.get("ctrl") or {})}
    pre = resolve(bc, regs, sc0["id"], "preproc", ctrl0)
    paths = {r["path"] for r, _ in pre["rows"]}
    check("preproc: filters + comparators + DF + WP present",
          any(".trTeFilter[" in p for p in paths)
          and any(".trTeComp[" in p for p in paths)
          and any("trDf" in p for p in paths)
          and any("trWp" in p for p in paths))
    check("preproc: trTeControl bits as single-bit relevance",
          any(f for r, f in pre["rows"]
              if r["path"].endswith("trTeControl") and f))
    fifo = resolve(bc, regs, sc0["id"], "fifo", ctrl0)
    check("FIFO: FifoHist + Overflow-Status",
          any("TipFifoHist" in r["path"] for r, _ in fifo["rows"])
          and any("TipFifoStatus" in r["path"] for r, _ in fifo["rows"]))
    nx = resolve(bc, regs, sc0["id"], "nexusfmt", ctrl0)
    check("NexusFmt: SrcID/SrcBits/InhibitSrc",
          any(f and "SrcID" in f for _, f in nx["rows"])
          and any(f and "InhibitSrc" in f for _, f in nx["rows"]))
    tgc = next(s for s in cat["scenarios"] if s["id"] == "tgc5b2_axis_wp")
    ctrlt = {k.lower() for k in (tgc.get("ctrl") or {})}
    fun = resolve(bc, regs, "tgc5b2_axis_wp", "funnel", ctrlt)
    check("tgc5b2/funnel: FUNNEL_CTRL correctly DISCARDED (SoC without reg), "
          "ATB stays",
          not any(r["path"] == "soc.FUNNEL_CTRL" for r, _ in fun["rows"])
          and any(".atb." in r["path"] for r, _ in fun["rows"]))
    wpf = resolve(bc, regs, "tgc5b2_axis_wp", "wpfifo", ctrlt)
    check("tgc5b2/WP-FIFO: a note instead of registers (destructive RDFD)",
          not wpf["rows"] and "destructive" in wpf["note"].lower()
          .replace("destruktiv", "destructive"))
    cpu_t = resolve(bc, regs, "tgc5b2_axis_wp", "cpu", ctrlt)
    # U4/U1: since the per-core rework the sentence is no longer true ("b0
    # holds BOTH cores") -- it now has to say the three things an operator
    # needs: a bit of its own per core, b0 stays the collective bit, and that
    # an access to the window of a RUNNING core hangs the AXI transaction
    # (the actual danger, SPEC §10 point 2).
    check("tgc5b2/cpu: the scenario note names the per-core bits b8/b9",
          "b8" in cpu_t["note"] and "b9" in cpu_t["note"], cpu_t["note"][:60])
    check("tgc5b2/cpu: the scenario note still names b0 as the collective bit",
          "collective" in cpu_t["note"])
    check("tgc5b2/cpu: the scenario note warns about the hanging window",
          "HANG" in cpu_t["note"] and "409" in cpu_t["note"])
    check("tgc5b2/cpu: the new CONTROL bits are listed as relevant",
          {"core0_run", "core1_run"} <=
          {f for r, fs in cpu_t["rows"] for f in (fs or [])
           if r["path"] == "soc.CONTROL"},
          str(sorted({f for r, fs in cpu_t["rows"] for f in (fs or [])
                      if r["path"] == "soc.CONTROL"})))
    check("tgc5b2/cpu: STATUS carries the mirror bits core0/1_running",
          {"core0_running", "core1_running"} <=
          {f["name"] for r, _ in cpu_t["rows"] if r["path"] == "soc.STATUS"
           for f in r["fields"]})

    # U7: the TE enable switch on the encoder card needs its counterpart in
    # the control panel. Whoever reads the badge "TE ENABLED" has to find the
    # bit as well; and the sentence at the TIP block must no longer name
    # InstTracing alone as the main switch -- that is exactly what "encoder
    # trace off" clears, while Enable stays and keeps blocking (U5 §6,
    # measured on the board; RDL: effective = Enable AND InstTracing).
    tip_t = resolve(bc, regs, "tgc5b2_axis_wp", "tip", ctrlt)
    tip_f = {f for r, fs in tip_t["rows"] for f in (fs or [])
             if r["path"].endswith("trTeControl")}
    check("tgc5b2/tip: Enable is listed as a relevant bit (the switch "
          "writes exactly this one)", "Enable" in tip_f, str(sorted(tip_f)))
    check("tgc5b2/tip: the note names the EFFECTIVE condition (Enable AND "
          "InstTracing)", "Enable AND InstTracing" in tip_t["note"],
          tip_t["note"][-120:])
    check("tgc5b2/tip: the note names Enable as the write interlock (swwel)",
          "swwel" in tip_t["note"])
    check("tgc5b2/tip: the note names the operating path AND the trap next to it",
          "'TE enabled' switch" in tip_t["note"]
          and "clears InstTracing only" in tip_t["note"])

    # T4: the three sink blocks of the architecture view. They have been
    # clickable since T4, so the rule applies to them in full -- ALL CSRs
    # with a relation, including the single bits of SINK_CTRL/SINK_STAT. The
    # target sets come from docs/SPEC_axis_wp_memory_map.md §9 and from the
    # header of rtl/board_kv260/ct_trace_sinks.sv.
    SINK_WANT = {
        "uram": ({"soc.TRACE_BEATS", "soc.TRACE_BYTES", "soc.TRACE_BUFSZ",
                  "soc.CONTROL", "soc.STATUS", "soc.SINK_CTRL",
                  "soc.SINK_STAT"},
                 {"uram_oneshot", "uram_stopped", "trace_clear"}),
        # U8: ddr_cfg_rej belongs in the same list as the other status bits.
        # It is the only bit of this sink that acknowledges an OPERATOR
        # ACTION -- if it is missing from the block, the operator looks for
        # the reason for his rejected value in the register tab.
        "ddr": ({"soc.SINK_CTRL", "soc.SINK_STAT", "soc.DDR_BASE",
                 "soc.DDR_SIZE", "soc.DDR_WPTR", "soc.DDR_DROPS",
                 "soc.DDR_BEATS"},
                {"ddr_en", "ddr_clear", "ddr_circ", "ddr_full",
                 "ddr_axi_err", "ddr_wrapped", "ddr_cfg_rej"}),
        "pib": ({"soc.SINK_CTRL", "soc.PIB_DROPS"},
                {"pib_en", "pib_clear", "pib_calib", "pib_div",
                 "pib_pattern"}),
    }
    for blk, (want_paths, want_fields) in sorted(SINK_WANT.items()):
        res = resolve(bc, regs, "tgc5b2_axis_wp", blk, ctrlt)
        got = {r["path"] for r, _ in res["rows"]}
        check("tgc5b2/%s: all registers of SPEC §9" % blk,
              want_paths <= got, "missing: %s" % sorted(want_paths - got))
        shown = {f for _, fs in res["rows"] for f in (fs or [])}
        check("tgc5b2/%s: single bits highlighted" % blk,
              want_fields <= shown, "missing: %s" % sorted(want_fields - shown))
        # A sink block without a sentence is a register list without context:
        # the reader sees DDR_BEATS and does not know that 0x30 is PIB_DROPS
        # here (the move from §9 otherwise costs a wrong measurement).
        check("tgc5b2/%s: scenario note present" % blk,
              bool(res["note"]) and len(res["note"]) > 40)
    ddr_note = resolve(bc, regs, "tgc5b2_axis_wp", "ddr", ctrlt)["note"]
    check("tgc5b2/ddr: the note names the offset move 0x30 -> 0x38",
          "0x38" in ddr_note and "0x30" in ddr_note)
    # U8: the sentence at the block is the only place where the window
    # appears IN THE CONTEXT of this bitstream. If 64 MiB stayed there, the
    # register tab would be right (it computes from the register) and the
    # text beside it wrong -- the most awkward combination, because it
    # devalues both.
    check("tgc5b2/ddr: the note names the U6 window (0x5000_0000 / 256 MiB)",
          "0x5000_0000 / DDR_SIZE 256 MiB" in ddr_note
          and "0x6000_0000 / DDR_SIZE 64 MiB" not in ddr_note,
          ddr_note[-200:])
    # U9: the sentence has to name the POLICY, no longer the old operating
    # rule "only write while ddr_en = 0". That rule was precisely the error:
    # it sounds like a protection and is the instruction for bypassing the U6
    # interlock (which is exactly what happened on the board on 2026-08-16,
    # DDR_BASE 0x8000_0000).
    check("tgc5b2/ddr: the note names the U9 policy (read-only + 403)",
          "READ-ONLY in this dashboard" in ddr_note and "403" in ddr_note,
          ddr_note[-260:])
    check("tgc5b2/ddr: the note still names the status bit of the hardware "
          "interlock (it remains the second line of defence)",
          "ddr_cfg_rej" in ddr_note and "U6 interlock" in ddr_note)
    check("tgc5b2/ddr: the note says what the hardware does at ddr_en = 0 "
          "(otherwise the interlock reads like full protection)",
          "at ddr_en = 0 it takes any value" in ddr_note)
    check("tgc5b2/ddr: the old operating instruction is NOT there any more",
          "writable ONLY while ddr_en = 0" not in ddr_note)
    check("tgc5b2/ddr: the note says what STAYS operable (a lock without any "
          "remaining control reads like a failure)",
          "ddr_clear and ddr_en stay writable" in ddr_note)
    # Counter-check for the note requirement: a block WITHOUT a sentence of
    # its own shows up here (msggen has none) -- so the check really measures
    # the note and not the mere existence of an entry.
    mg = resolve(bc, regs, "tgc5b2_axis_wp", "msggen", ctrlt)
    check("counter-check: msggen has NO scenario note (the check bites)",
          not (mg or {}).get("note"))

    # ---- U2: indexed instances under ONE parent node ---------------------
    # requirement 2026-08-14: te.trTeFilter[0].Control through te.trTeFilter[15].Control
    # -- can you set up a parent tab te.trTeFilter[0..15] here that expands
    # and only then shows the individual instances?" Both things are checked:
    # that the folding happens AND that it loses nothing -- a grouping that
    # swallows a row would be worse than the long list, because the missing
    # register looks like a missing FIELD.
    print("== U2: array instances -> parent node (register tab) ==")
    all_paths = [r["path"] for r in regs]
    nodes = group_rows(all_paths)
    by_label = {n["label"]: n for n in nodes if n["kind"] == "group"}
    for want, n_inst, n_reg in (("ct_cs_cpuif.te.trTeFilter[0..15]", 16, 112),
                                ("ct_cs_cpuif.te.trTeComp[0..7]", 8, 56),
                                ("ct_cs_cpuif.pc.trTePerfCntIFetchRange[0..2]",
                                 3, 6),
                                ("ct_cs_cpuif.pc.trTePerfCntDataRdThRange[0..2]",
                                 3, 6),
                                ("ct_cs_cpuif.pc.trTePerfCntDataRdRange[0..6]",
                                 7, 14),
                                ("ct_cs_cpuif.pc.trTePerfCntDataWrRange[0..6]",
                                 7, 14)):
        g = by_label.get(want)
        check("parent node %s" % want, bool(g),
              "not formed; present: %s" % sorted(by_label))
        if g:
            check("%s: %d instances / %d registers" % (want, n_inst, n_reg),
                  len(g["insts"]) == n_inst and g["n"] == n_reg,
                  "is %d/%d" % (len(g["insts"]), g["n"]))
            check("%s: index sequence without a gap" % want, not g["gaps"],
                  "missing: %s" % g["gaps"])
    check("expanded content complete (no register lost)",
          group_labels(nodes) == all_paths,
          "%d of %d rows" % (len(group_labels(nodes)), len(all_paths)))
    flat = [p for p in all_paths if "[" not in p]
    leaves = [n["label"] for n in nodes if n["kind"] == "leaf"]
    check("non-array registers stay flat (%d rows, order)"
          % len(flat), leaves == flat,
          "%d leaves" % len(leaves))
    check("register tab: %d parent nodes instead of %d rows"
          % (len(nodes), len(all_paths)), len(nodes) == len(flat) + 6)

    print("== U2: the same folding in the block panel, all scenarios ==")
    # The panel shows the paths WITHOUT `ct_cs_cpuif.` (regRow shortens them);
    # the grouping therefore sees different labels than the register tab and
    # still has to form the same nodes.
    def short(p):
        return p[len("ct_cs_cpuif."):] if p.startswith("ct_cs_cpuif.") else p

    worst = ("", 0, 0)
    for sc in cat["scenarios"]:
        sid = sc["id"]
        sc_ctrl = {k.lower() for k in (sc.get("ctrl") or {})}
        g = geo.get(sid)
        if not g:
            continue
        for b in sorted({re.sub(r"\d+$", "", n["id"]) for n in g["nodes"]}):
            res = resolve(bc, regs, sid, b, sc_ctrl)
            rows = ([r["path"] for r, _ in res["rows"]] if res
                    else [r["path"] for r in regs if reg_home(r["path"]) == b])
            lbl = [short(p) for p in rows]
            nd = group_rows(lbl)
            check("%s/%s: the folding loses nothing (%d rows -> %d nodes)"
                  % (sid, b, len(lbl), len(nd)),
                  group_labels(nd) == lbl)
            if len(lbl) - len(nd) > worst[2] - worst[1]:
                worst = (sid + "/" + b, len(nd), len(lbl))
    check("biggest gain: %s %d rows -> %d nodes"
          % (worst[0], worst[2], worst[1]), worst[2] > worst[1])
    fil = group_rows([short(r["path"]) for r in regs
                      if reg_home(r["path"]) == "filters"])
    fg = [n for n in fil if n["kind"] == "group"]
    check("panel filters: ONE parent node te.trTeFilter[0..15] + 2 flat rows",
          len(fg) == 1 and fg[0]["label"] == "te.trTeFilter[0..15]"
          and len(fil) == 3,
          "%d nodes: %s" % (len(fil), [n["label"] for n in fil]))

    print("== U2: synthetic cases (gaps, single instance, counter-check) ==")
    syn = ["te.trTeControl"] + ["te.trTeFilter[%d].Control" % i
                                for i in range(16)] + ["te.trTeInstFeatures"]
    sn = group_rows(syn)
    check("synthetic: 16 instances -> 1 parent node + 2 flat rows",
          len(sn) == 3 and sn[1]["kind"] == "group"
          and sn[1]["label"] == "te.trTeFilter[0..15]",
          str([n["label"] for n in sn]))
    check("synthetic: the parent node carries all 16 instances",
          sn[1]["kind"] == "group" and len(sn[1]["insts"]) == 16
          and group_labels(sn) == syn)
    gap = group_rows(["f[0].A", "f[1].A", "f[5].A", "f[5].B"])
    check("gap: ONE node f[0..5] instead of sub-ranges",
          len(gap) == 1 and gap[0]["label"] == "f[0..5]",
          str([n["label"] for n in gap]))
    check("the gap is named (missing 2,3,4)",
          gap[0].get("gaps") == [2, 3, 4], str(gap[0].get("gaps")))
    one = group_rows(["x[0].A", "x[0].B", "y"])
    check("a single instance stays FLAT (no click without gain)",
          all(n["kind"] == "leaf" for n in one) and len(one) == 3)
    ordr = group_rows(["a", "q[1].A", "b", "q[2].A", "c"])
    check("the group sits at the position of its first member",
          [n["label"] for n in ordr] == ["a", "q[1..2]", "b", "c"],
          str([n["label"] for n in ordr]))
    check("counter-check: a list without indices produces NO parent node",
          not [n for n in group_rows(["a.b", "c.d"]) if n["kind"] == "group"])

    print()
    if FAILS:
        print("H3_BLOCKCSR_FAIL  %d/%d red:" % (len(FAILS), NCHECK))
        for f in FAILS:
            print("  - " + f)
        return 1
    print("H3_BLOCKCSR_ALL_PASS  (%d checks)" % NCHECK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
