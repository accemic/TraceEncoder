#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Check a decoded PC sequence against the expected one: loss tolerant, but
transition exact.

    python3 check_transitions.py <pcout> <expected.pcs> [<deco.log>]

Why not simply trust "Decoded OK": in the recovery-anchor variant the decode
reports OK and still returns WRONG PCs -- after the FIFO_OVERRUN anchor the
decoder takes a branch that was never taken, and the reference diverges on
every comparison. A gate that only looks at "Decoded OK" greenwashes that.

The check: every ADJACENT transition (a -> b) of the decoded sequence must
occur as an adjacent transition in the expectation. Segment boundaries (sync
re-anchors) are exempt -- there the sequence may jump, because trace was lost
to an overflow. The boundaries come from the `SYNC PC:` markers of the NexRv
-deco log; without a deco.log every unexpected transition is counted, which is
stricter.

Exit 0 = every transition legal; exit 1 = illegal transition(s) found.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

_SYNC_LINE = re.compile(r"^SYNC PC: 0x([0-9a-fA-F]+)")
_PC_LINE = re.compile(r"^(\d+) PC: 0x([0-9a-fA-F]+)")


def read_pcs(path: Path) -> list[int]:
    out = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        tok = line.split(",")[0].strip()
        if not tok:
            continue
        try:
            out.append(int(tok, 16))
        except ValueError:
            continue
    return out


def seg_starts(deco_log: Path) -> set[int]:
    marks: set[int] = set()
    pending = False
    for line in deco_log.read_text(encoding="utf-8", errors="replace").splitlines():
        if _SYNC_LINE.match(line):
            pending = True
            continue
        if pending:
            m = _PC_LINE.match(line)
            if m:
                marks.add(int(m.group(1)))
                pending = False
    return marks


def main() -> int:
    argv = [a for a in sys.argv[1:] if a != "--exact"]
    exact = "--exact" in sys.argv
    if len(argv) < 2:
        print(__doc__)
        return 2
    decoded = read_pcs(Path(argv[0]))
    expected = read_pcs(Path(argv[1]))
    marks = seg_starts(Path(argv[2])) if len(argv) > 2 else set()
    if exact:
        # Lossless legs (no overflow): the decoded sequence must match the
        # expectation EXACTLY. Ghost PCs (an untraced tail inside the resume
        # sync) and swallowed edge PCs show up here even when every
        # individual transition would be legal.
        if decoded == expected:
            print(f"CHECK OK (exact): {len(decoded)} PCs identical")
            return 0
        n = min(len(decoded), len(expected))
        div = next((i for i in range(n) if decoded[i] != expected[i]), n)
        print(f"CHECK FAIL (exact): decoded={len(decoded)} expected={len(expected)} "
              f"first divergence at index {div}")
        for i in range(max(0, div - 3), min(n, div + 4)):
            mark = "<-- HERE" if i == div else ""
            print(f"  [{i}] dec=0x{decoded[i]:08x} exp=0x{expected[i]:08x} {mark}")
        return 1
    if not decoded or not expected:
        print(f"CHECK FAIL: empty input (decoded={len(decoded)}, expected={len(expected)})")
        return 1
    legal = set(zip(expected, expected[1:]))
    bad = []
    for i in range(len(decoded) - 1):
        if (i + 1) in marks:
            continue                     # segment boundary: jump allowed
        pair = (decoded[i], decoded[i + 1])
        if pair not in legal:
            bad.append((i, pair))
    if bad:
        print(f"CHECK FAIL: {len(bad)} illegal transition(s) out of {len(decoded) - 1} "
              f"({len(marks)} segment boundaries excluded)")
        for i, (a, b) in bad[:8]:
            print(f"  dec[{i}] 0x{a:08x} -> 0x{b:08x}  (does not occur in the expectation)")
        return 1
    print(f"CHECK OK: {len(decoded) - 1} transitions legal "
          f"({len(marks)} segment boundaries, {len(expected)} expected PCs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
