#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Gate G5: is the CTTD-decoded PC sequence == the actually retiring PC sequence?

Compares CTTD's `-pcout` (reconstructed from the ATB byte stream) against the record of
the really retiring PCs (`mbv_ctte_env`, RETIRED_PCS_PATH). This is the acceptance
rule for the adapter <-> CTTE integration: "PC sequence == reference, no gaps".

ALIGNMENT (the actual crux):
    The trace does not begin at program start. Tracing is enabled by CSR only after
    reset, and the encoder anchors the sequence with its first sync message
    (ProgTraceSync). The reference, in contrast, starts at the very first retire. The
    comparison therefore looks for the starting point: the offset in the reference at
    which the decoded sequence begins.

    That offset is NOT chosen freely: it must cover the decoded sequence WITHOUT GAPS
    and in order. Ambiguity is real (loops repeat PCs) -> ALL candidate offsets are
    checked and the result is accepted only if at least one matches exactly. There is
    no "roughly fits".

Usage:
    py scripts/check_pcout_vs_retired.py <decoded.pcout> <retired.pcs> [--label <name>]
Exit: 0 = PASS, 1 = FAIL (with a diagnosis of the first divergence).
"""
import argparse
import re
import sys
from pathlib import Path

PC_RE = re.compile(r"0x([0-9a-fA-F]+)")


def read_pcs(path: Path, first_field_only: bool = True) -> list[int]:
    """Read PC lists. CTTD pcout: '0x00000144,L4' -> only the first field counts."""
    out: list[int] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        field = line.split(",")[0] if first_field_only else line
        m = PC_RE.search(field)
        if m:
            out.append(int(m.group(1), 16))
    return out


def find_alignments(decoded: list[int], retired: list[int]) -> list[int]:
    """All offsets at which `decoded` sits in `retired` as a contiguous subsequence."""
    if not decoded or len(decoded) > len(retired):
        return []
    hits = []
    first = decoded[0]
    for i in range(len(retired) - len(decoded) + 1):
        if retired[i] != first:
            continue
        if retired[i:i + len(decoded)] == decoded:
            hits.append(i)
    return hits


def first_mismatch(decoded: list[int], retired: list[int], off: int) -> tuple[int, int, int] | None:
    for k, pc in enumerate(decoded):
        if off + k >= len(retired):
            return (k, pc, -1)
        if retired[off + k] != pc:
            return (k, pc, retired[off + k])
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcout", type=Path, help="CTTD -pcout (decoded)")
    ap.add_argument("retired", type=Path, help="really retiring PCs (mbv_ctte_env)")
    ap.add_argument("--label", default="G5", help="label for the output")
    ap.add_argument("--ref-prefix-ok", action="store_true",
                    help="PASS if the REFERENCE is contained in full as a prefix of the "
                         "decoded sequence (board run longer than the simulation "
                         "reference; the one-shot ring holds the start of the stream)")
    ap.add_argument("--min-pcs", type=int, default=20,
                    help="minimum length of the decoded sequence (default 20) - keeps an "
                         "almost empty trace from 'matching' trivially")
    args = ap.parse_args()

    for p in (args.pcout, args.retired):
        if not p.is_file():
            print(f"[{args.label}] FAIL: file missing: {p}")
            return 1

    decoded = read_pcs(args.pcout)
    retired = read_pcs(args.retired)

    print(f"[{args.label}] decoded   : {len(decoded)} PCs from {args.pcout.name}")
    print(f"[{args.label}] reference : {len(retired)} PCs from {args.retired.name}")

    if not decoded:
        print(f"[{args.label}] FAIL: no decoded PCs - encoder/decoder delivered nothing")
        return 1
    if not retired:
        print(f"[{args.label}] FAIL: no reference PCs - the core retired nothing")
        return 1
    if len(decoded) < args.min_pcs:
        print(f"[{args.label}] FAIL: only {len(decoded)} decoded PCs (< {args.min_pcs}) - too few "
              f"to prove anything")
        return 1

    # Board mode: the reference is the (shorter) simulation prefix -- PASS if the
    # decoded sequence begins with the COMPLETE reference.
    if args.ref_prefix_ok and len(decoded) >= len(retired) \
            and decoded[:len(retired)] == retired:
        print(f"[{args.label}] PASS - reference ({len(retired)} PCs) contained IN FULL as "
              f"a prefix of the decoded sequence ({len(decoded)} PCs)")
        return 0

    hits = find_alignments(decoded, retired)
    if hits:
        off = hits[0]
        print(f"[{args.label}] alignment: decoded sequence begins at reference index {off} "
              f"(PC 0x{retired[off]:08x})"
              + (f"; {len(hits)} possible offsets (loop) - all congruent" if len(hits) > 1 else ""))
        print(f"[{args.label}] PASS - {len(decoded)}/{len(decoded)} PCs identical, no gaps, in order")
        return 0

    # --- FAIL: show the best candidate, so that the diagnosis need not guess ---
    print(f"[{args.label}] FAIL: decoded sequence is NOT a gapless subsequence of the reference")
    cands = [i for i, pc in enumerate(retired) if pc == decoded[0]]
    if not cands:
        print(f"[{args.label}]   The first decoded PC 0x{decoded[0]:08x} does not occur in the reference at all.")
        print(f"[{args.label}]   reference begins with: " + " ".join(f"0x{p:08x}" for p in retired[:6]))
        return 1
    best = None
    for off in cands:
        mm = first_mismatch(decoded, retired, off)
        depth = mm[0] if mm else len(decoded)
        if best is None or depth > best[0]:
            best = (depth, off, mm)
    depth, off, mm = best
    print(f"[{args.label}]   best starting point: reference index {off}; matches up to PC #{depth}, then:")
    if mm and mm[2] == -1:
        print(f"[{args.label}]   decoded[{mm[0]}]=0x{mm[1]:08x}, reference exhausted (trace longer than the run?)")
    elif mm:
        print(f"[{args.label}]   decoded[{mm[0]}]=0x{mm[1]:08x}  !=  reference[{off+mm[0]}]=0x{mm[2]:08x}")
        lo = max(0, mm[0] - 3)
        print(f"[{args.label}]   context decoded  : " + " ".join(f"0x{p:08x}" for p in decoded[lo:mm[0] + 4]))
        print(f"[{args.label}]   context reference: " + " ".join(f"0x{p:08x}" for p in retired[off + lo:off + mm[0] + 4]))
    return 1


if __name__ == "__main__":
    sys.exit(main())
