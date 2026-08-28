#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Turn the malloc demo's ACT-CAP records into a heap timeline, and judge it.

Input: the raw record dump of one core -- `rvmon run/drain --out0 core0.bin`
on the board (little-endian 32-bit words) or the e2e bench's
`rvcfi_e2e_malloc_core0.hex` (one word per line). Four words per record:
PC, tag, timestamp, {core, tstrb, tid} -- see rvmon.h. The tag layout is
md_cap.h's: [23]=ACT-CAP [22:21]=VALUE [20:18]=field [17:0]=value.

    python3 decode_malloc.py core0.bin --sym malloc_core0.sym [--mhz 75]

What is checked (a reader that only prints is not a verdict):
  * every MALLOC id is followed by SIZE, PTR, CALLER in that order;
  * pointers are 8-byte aligned (newlib's guarantee) and inside the heap
    window [_end, 0xD000) -- or 0, and then the size explains why;
  * no two live blocks overlap; a FREE names a block that is live;
  * the break only ever grows, and only while a malloc is in flight.
"""
import argparse
import struct
import sys

FIELDS = {0: "MALLOC", 1: "SIZE", 2: "PTR", 3: "CALLER", 4: "FREE",
          5: "FREE_PTR", 6: "FREE_CALLER", 7: "SBRK"}
HEAP_LIMIT = 0xD000


def read_words(path):
    if path.endswith(".hex"):
        return [int(l, 16) for l in open(path) if l.strip()]
    data = open(path, "rb").read()
    return list(struct.unpack("<%dI" % (len(data) // 4), data[: len(data) // 4 * 4]))


def read_syms(path):
    syms = []
    if not path:
        return syms
    for line in open(path):
        parts = line.split()
        if len(parts) == 3 and parts[1] in "tTwW":
            syms.append((int(parts[0], 16), parts[2]))
    return sorted(syms)


def symbolize(syms, addr):
    best = None
    for a, n in syms:
        if a <= addr:
            best = (a, n)
        else:
            break
    return "%s+0x%x" % (best[1], addr - best[0]) if best else "0x%08x" % addr


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dump")
    ap.add_argument("--sym", help="nm -n output of the image, for the caller column")
    ap.add_argument("--mhz", type=float, default=75.0, help="timestamp clock (default 75)")
    ap.add_argument("--end", type=lambda s: int(s, 0), default=None,
                    help="_end of the image (heap start); taken from --sym when absent")
    args = ap.parse_args()

    words = read_words(args.dump)
    syms = read_syms(args.sym)
    heap_lo = args.end
    if heap_lo is None and args.sym:
        for a, n in syms:
            pass
        for line in open(args.sym):
            p = line.split()
            if len(p) == 3 and p[2] == "_end":
                heap_lo = int(p[0], 16)

    recs = []
    for i in range(0, len(words) - 3, 4):
        pc, tag, ts, meta = words[i:i + 4]
        tid, tstrb, core = meta & 0xFF, (meta >> 8) & 0xFFF, (meta >> 20) & 0xF
        tag &= 0xFFFFFF
        if not (tag >> 23) & 1 or ((tag >> 21) & 3) != 3:
            recs.append(("OTHER", tag, pc, ts, tid, core))
            continue
        field = (tag >> 18) & 7
        value = tag & 0x3FFFF
        recs.append((FIELDS[field], value, pc, ts, tid, core))
    if not recs:
        print("no records"); return 1

    # unroll the 32-bit timestamp
    t0 = recs[0][3]
    prev, hi = t0, 0
    times = []
    for r in recs:
        ts = r[3]
        if ts < prev:
            hi += 1 << 32
        prev = ts
        times.append(ts + hi - t0)
    us = lambda c: c / args.mhz

    live = {}          # ptr -> (id, size)
    events, problems = [], []
    brk = None
    pending = None
    for (kind, value, pc, ts, tid, core), t in zip(recs, times):
        if kind == "MALLOC":
            if pending:
                problems.append("malloc id %d started before id %d completed" % (value, pending["id"]))
            pending = {"id": value, "t": t, "sbrk": []}
        elif kind == "SIZE":
            if not pending: problems.append("SIZE without MALLOC at t=%d" % t); continue
            pending["size"] = value
        elif kind == "SBRK":
            if brk is not None and value < brk:
                problems.append("break shrank 0x%x -> 0x%x" % (brk, value))
            if not pending:
                problems.append("SBRK outside a malloc at t=%d" % t)
            else:
                pending["sbrk"].append(value)
            brk = value
        elif kind == "PTR":
            if not pending: problems.append("PTR without MALLOC"); continue
            pending["ptr"] = value
        elif kind == "CALLER":
            if not pending: problems.append("CALLER without MALLOC"); continue
            p = pending; pending = None
            p["caller"] = value; p["t_end"] = t
            ptr, size = p.get("ptr", 0), p.get("size", 0)
            if ptr:
                if ptr & 7:
                    problems.append("id %d: pointer 0x%x not 8-byte aligned" % (p["id"], ptr))
                if heap_lo is not None and not (heap_lo <= ptr and ptr + size <= HEAP_LIMIT):
                    problems.append("id %d: block 0x%x+%d outside the heap window" % (p["id"], ptr, size))
                for q, (qid, qsize) in live.items():
                    if ptr < q + qsize and q < ptr + size:
                        problems.append("id %d overlaps live id %d" % (p["id"], qid))
                live[ptr] = (p["id"], size)
            events.append(("malloc", p))
        elif kind == "FREE":
            pending_free = {"id": value, "t": t}
        elif kind == "FREE_PTR":
            pending_free["ptr"] = value
        elif kind == "FREE_CALLER":
            f = pending_free; f["caller"] = value; f["t_end"] = t
            if f["ptr"] in live:
                if live[f["ptr"]][0] != f["id"]:
                    problems.append("free of 0x%x names id %d, block is id %d" % (f["ptr"], f["id"], live[f["ptr"]][0]))
                del live[f["ptr"]]
            else:
                problems.append("free of 0x%x which is not live" % f["ptr"])
            events.append(("free", f))
        else:
            problems.append("unexpected record %s tag=0x%06x pc=0x%x" % (kind, value, pc))

    print("%-4s %-7s %4s %6s %8s %-26s %9s %7s  %s" % ("#", "event", "id", "size", "ptr", "caller", "t[us]", "dur[us]", "heap"))
    peak = 0
    for n, (what, e) in enumerate(events, 1):
        caller = symbolize(syms, e.get("caller", 0)) if syms else "0x%08x" % e.get("caller", 0)
        if what == "malloc":
            grow = " brk->0x%x" % e["sbrk"][-1] if e["sbrk"] else ""
            ptr = "0x%04x" % e["ptr"] if e["ptr"] else "NULL"
            print("%-4d %-7s %4d %6d %8s %-26s %9.2f %7.2f %s" % (n, "malloc", e["id"], e["size"], ptr, caller, us(e["t"]), us(e["t_end"] - e["t"]), grow))
        else:
            print("%-4d %-7s %4d %6s %8s %-26s %9.2f %7.2f" % (n, "free", e["id"], "", "0x%04x" % e["ptr"], caller, us(e["t"]), us(e["t_end"] - e["t"])))
    if brk is not None and heap_lo is not None:
        peak = brk - heap_lo
    print()
    print("records: %d  events: %d  final break: %s  heap used at peak: %s  still live: %d"
          % (len(recs), len(events), "0x%x" % brk if brk is not None else "-",
             "%d B" % peak if heap_lo is not None else "-", len(live)))
    if problems:
        print("PROBLEMS (%d):" % len(problems))
        for p in problems: print("  " + p)
        return 1
    print("MALLOC_DEMO_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
