#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""gen_sites.py -- turn the site manifest + the built symbol map into the
encoder's watchpoint table and a human-readable site map.

    manifest (what a site MEANS)  +  symbols (where it IS)  ->  table + csv

WHY THE BIT LAYOUT IS PARSED, NOT COPIED
----------------------------------------
The tag format lives in `src/rv_tags.h`. This script could restate those
shifts and masks in Python -- and then they would be a MIRROR, which drifts
the first time someone widens a field. Nothing would fail: the encoder would
happily carry tags whose meaning the analyser reads slightly differently, and
the findings would quietly become fiction.

So the constants are read out of the header. If a field moves, this script
moves with it or fails loudly on a missing name; it cannot silently disagree.

THE TABLE'S PROGRAMMING RULES (from the encoder's RDL)
-----------------------------------------------------
  * fill ALL slots -- the search tree is a perfect binary tree, a hole is
    not a "don't care" but a wrong branch for every concurrent lookup
  * strictly ascending, unique keys
  * odd addresses for padding: instruction addresses are 4-byte aligned
    here (no C extension), so an odd key can never match a retired PC

Two tables are emitted per core:
  wp_table_coreN_full.txt  all 1000 sites -- full visibility, throttled runs
  wp_table_coreN_hot.txt   only the contended object and the locks -- a
                           twenty-fifth of the record rate, for full-speed
                           bursts. The table IS the rate control, and it
                           costs nothing.
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HDR = os.path.join(HERE, "src", "rv_tags.h")


def parse_defines(path):
    """Read the simple `#define NAME value` constants out of a C header."""
    consts = {}
    pat = re.compile(r"^#define\s+(RV_[A-Z0-9_]+)\s+(0x[0-9A-Fa-f]+|\d+)u?\s*(/\*.*)?$")
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = pat.match(line.strip())
            if m:
                consts[m.group(1)] = int(m.group(2), 0)
    return consts


C = parse_defines(HDR)
REQUIRED = [
    "RV_TAG_SRC_SHIFT", "RV_TAG_KIND_SHIFT", "RV_TAG_KIND_MASK",
    "RV_SRC_ACTST", "RV_KIND_DATA", "RV_KIND_SYNC", "RV_KIND_MARKER",
    "RV_DATA_RW_SHIFT", "RV_DATA_OBJ_SHIFT", "RV_DATA_OBJ_MASK",
    "RV_DATA_SITE_SHIFT", "RV_DATA_SITE_MASK", "RV_DATA_SIZE_MASK",
    "RV_SYNC_OP_SHIFT", "RV_SYNC_OP_MASK", "RV_SYNC_LOCK_SHIFT",
    "RV_SYNC_LOCK_MASK", "RV_SYNC_SITE_MASK",
    "RV_MARK_ID_SHIFT", "RV_MARK_ID_MASK", "RV_MARK_SITE_MASK",
    "RV_ACT_CMD_DAQ_PC_CURR", "RV_ACT_CMD_NONE", "RV_ACT_SINK_AXIS",
]
_missing = [n for n in REQUIRED if n not in C]
if _missing:
    print("ERROR: rv_tags.h does not define: %s" % ", ".join(_missing),
          file=sys.stderr)
    sys.exit(2)


def tag_of(site):
    """Build the 24-bit tag exactly as rv_tags.h's macros would."""
    src = C["RV_SRC_ACTST"]
    base = (src << C["RV_TAG_SRC_SHIFT"])
    if site["kind"] == "data":
        return (base
                | ((C["RV_KIND_DATA"] & C["RV_TAG_KIND_MASK"]) << C["RV_TAG_KIND_SHIFT"])
                | ((site["rw_id"] & 1) << C["RV_DATA_RW_SHIFT"])
                | ((site["obj_id"] & C["RV_DATA_OBJ_MASK"]) << C["RV_DATA_OBJ_SHIFT"])
                | ((site["kind_idx"] & C["RV_DATA_SITE_MASK"]) << C["RV_DATA_SITE_SHIFT"])
                | (site["size_log"] & C["RV_DATA_SIZE_MASK"]))
    if site["kind"] == "sync":
        # The lock id comes from the manifest. The first version hardcoded 0
        # here, and the consequence was instructive enough to write down: all
        # sync events looked like lock 0, so the order monitor never saw the
        # 2/3 pair at all, and the mis-labelled releases of "lock 0"
        # overwrote the other core's published vector clock in the
        # happens-before monitor -- which then reported phantom conflicts on
        # a correctly locked run. One hardcoded zero, two independent wrong
        # verdicts.
        return (base
                | ((C["RV_KIND_SYNC"] & C["RV_TAG_KIND_MASK"]) << C["RV_TAG_KIND_SHIFT"])
                | ((site["op_id"] & C["RV_SYNC_OP_MASK"]) << C["RV_SYNC_OP_SHIFT"])
                | ((int(site.get("lock_id", 0)) & C["RV_SYNC_LOCK_MASK"]) << C["RV_SYNC_LOCK_SHIFT"])
                | (site["kind_idx"] & C["RV_SYNC_SITE_MASK"]))
    if site["kind"] == "marker":
        return (base
                | ((C["RV_KIND_MARKER"] & C["RV_TAG_KIND_MASK"]) << C["RV_TAG_KIND_SHIFT"])
                | ((site["mark_id"] & C["RV_MARK_ID_MASK"]) << C["RV_MARK_ID_SHIFT"])
                | (site["kind_idx"] & C["RV_MARK_SITE_MASK"]))
    raise ValueError("kind %r has no ACT-ST tag (ACT-CAP tags are built at "
                     "run time by the program)" % site["kind"])


def cmd_word(tag):
    return ((C["RV_ACT_CMD_DAQ_PC_CURR"] & 0x3F)
            | ((C["RV_ACT_SINK_AXIS"] & 0x3) << 6)
            | ((tag & 0xFFFFFF) << 8))


def read_symbols(path):
    """`nm -n` output -> {name: address}."""
    syms = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 3 and parts[2].startswith("rvs_"):
                syms[parts[2]] = int(parts[0], 16)
    return syms


HOT_OBJECTS = {"balance", "count", "checksum"}


def build(core, slots, outdir):
    meta = json.load(open(os.path.join(HERE, "sites_meta_core%d.json" % core),
                          encoding="utf-8"))
    syms = read_symbols(os.path.join(HERE, "rvcfi_core%d.sym" % core))

    rows, missing = [], []
    for s in meta["sites"]:
        if s["src"] != "actst":
            continue                      # ACT-CAP sites are instructions, not slots
        name = "rvs_%d" % s["id"]
        if name not in syms:
            missing.append(name)
            continue
        rows.append(dict(addr=syms[name], tag=tag_of(s), site=s))

    if missing:
        print("ERROR: %d site labels are missing from the binary: %s%s"
              % (len(missing), ", ".join(missing[:8]),
                 " ..." if len(missing) > 8 else ""), file=sys.stderr)
        return None

    rows.sort(key=lambda r: r["addr"])
    addrs = [r["addr"] for r in rows]
    if len(set(addrs)) != len(addrs):
        print("ERROR: duplicate site addresses -- two labels landed on one "
              "instruction, so one of them can never be attributed",
              file=sys.stderr)
        return None

    n_real = len(rows)
    if n_real > slots:
        print("ERROR: %d sites do not fit %d slots" % (n_real, slots),
              file=sys.stderr)
        return None

    # Padding: odd keys above the last real one, strictly ascending.
    pad_start = (max(addrs) | 1) + 2
    pad = [pad_start + 2 * i for i in range(slots - n_real)]

    def write_table(path, sel):
        sel_rows = [r for r in rows if sel(r)]
        n = len(sel_rows)
        pad_here = [(max(addrs) | 1) + 2 + 2 * i for i in range(slots - n)]
        with open(path, "w", newline="\n") as f:
            f.write("# addr cmd   (%d real + %d padding = %d slots)\n"
                    % (n, len(pad_here), slots))
            for r in sel_rows:
                f.write("%08X %08X\n" % (r["addr"], cmd_word(r["tag"])))
            for a in pad_here:
                f.write("%08X %08X\n" % (a, C["RV_ACT_CMD_NONE"]))
        return n

    full_path = os.path.join(outdir, "wp_table_core%d_full.txt" % core)
    hot_path = os.path.join(outdir, "wp_table_core%d_hot.txt" % core)
    n_full = write_table(full_path, lambda r: True)
    # The hot table is the rate control: every site left out is a record the
    # cores never generate. Keep the account object and its locks, and only
    # from every eighth transaction -- enough to show a race at full core
    # speed, roughly a twentieth of the full table's record rate.
    n_hot = write_table(
        hot_path,
        lambda r: (r["site"]["kind_idx"] % 8 == 0
                   and (r["site"]["kind"] == "sync"
                        or (r["site"]["kind"] == "data"
                            and r["site"].get("obj") in HOT_OBJECTS))))

    csv_path = os.path.join(outdir, "sites_core%d.csv" % core)
    with open(csv_path, "w", newline="\n") as f:
        f.write("addr,site_id,src,kind,kind_idx,object,rw,lock,marker,func,note\n")
        for s in meta["sites"]:
            name = "rvs_%d" % s["id"]
            if name not in syms:
                continue
            f.write("%08X,%d,%s,%s,%d,%s,%s,%s,%s,%s,%s\n"
                    % (syms[name], s["id"], s["src"], s["kind"], s["kind_idx"],
                       s.get("obj", ""), s.get("rw", ""), s.get("lock", ""),
                       s.get("mark", ""), s["func"], s["note"].replace(",", ";")))

    print("core %d: %d real ACT-ST sites -> full table (%d slots), "
          "hot table %d real; %d ACT-CAP sites in sites_core%d.csv"
          % (core, n_full, slots, n_hot,
             sum(1 for s in meta["sites"] if s["src"] == "actcap"), core))
    return dict(full=n_full, hot=n_hot)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--slots", type=int, default=1023,
                    help="watchpoint table capacity (trWpCap.Entries)")
    ap.add_argument("--out", default=HERE)
    args = ap.parse_args()

    ok = True
    for core in (0, 1):
        if build(core, args.slots, args.out) is None:
            ok = False
    if not ok:
        return 1
    print("SITES_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
