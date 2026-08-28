#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Prepare the demo consoles from the board recordings (reproducibly).

    py make_demo_console.py            # writes demo/console_<scenario>.txt

Sources (real board captures, nothing is invented):

| Target                       | Source                                                      |
|------------------------------|-------------------------------------------------------------|
| demo/console_cva6_linux.txt  | demo/raw/con_cva6_linux.bin (RV32 boot, re-recorded 2026-08-19) |
| demo/console_rocket2.txt     | demo/raw/con_rocket2.bin (RV64 SMP boot, re-recorded 2026-08-19) |
| demo/console_rocket64.txt    | demo/raw/con_rocket64.bin (RV64 boot, a single hart) |
| demo/console_cva6_linux64.txt| demo/raw/con_cva6_linux64.bin (cv64a6, Sv39) |

The three raw files are uncut ring contents from the board; they live in
the repository, so that this script stays reproducible (the earlier sources
pointed into build directories that do not exist here).

Only CAPTURE artefacts are cleaned up, never content:

1. **Pairwise dedup:** earlycon and console write to the SAME UART, so every
   kernel line appears twice in the recording. Only IMMEDIATELY consecutive
   identical lines are collapsed, pairwise -- 2 becomes 1, 4 becomes 2 (the
   fourfold "can't open /dev/null" message really is
   four genuine messages from two consoles: two remain).
2. **Dot artefact (rocket2 only):** the capture path of that run appends a
   '.' to every line and prefixes some with one (a ring-chunk join).
   A single trailing dot is removed; '...' and the like remain.
3. **NUL bytes** at the end (unused ring space) are stripped.

The head of each target file does NOT name source and rules (the file is
reproduced 1:1) -- this script is the documented provenance.
"""
from __future__ import annotations

from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

JOBS = [
    (HERE / "demo/raw/con_cva6_linux.bin",
     HERE / "demo/console_cva6_linux.txt", False),
    # Recorded 2026-08-19 on kria-kv260 at pl_clk0 = 68.181818 MHz, straight
    # from the console ring (CON_BYTES words at 0xA030_0000) via the board
    # runners' `PHASE=con`. The raw ring dumps travel WITH the repository so
    # this script stays reproducible instead of pointing at a build tree that
    # no longer exists.
    (HERE / "demo/raw/con_rocket2.bin",
     HERE / "demo/console_rocket2.txt", False),
    (HERE / "demo/raw/con_rocket64.bin",
     HERE / "demo/console_rocket64.txt", False),
    (HERE / "demo/raw/con_cva6_linux64.bin",
     HERE / "demo/console_cva6_linux64.txt", False),
]


def pair_dedup(lines: list[str]) -> list[str]:
    out: list[str] = []
    i = 0
    while i < len(lines):
        if i + 1 < len(lines) and lines[i] == lines[i + 1] and lines[i].strip():
            out.append(lines[i])
            i += 2
        else:
            out.append(lines[i])
            i += 1
    return out


def strip_dot_artifact(line: str) -> str:
    if line.startswith(".") and not line.startswith(".."):
        line = line[1:]
    if line.endswith(".") and not line.endswith(".."):
        # Kernel lines practically never end on '.' in the original; the
        # rocket2 capture appends exactly ONE. Doubles stay in place.
        line = line[:-1]
    return line


def main() -> int:
    for src, dst, dots in JOBS:
        if not src.is_file():
            print("SKIP %s (source missing)" % src.name)
            continue
        raw = src.read_bytes().rstrip(bytes(1)).decode("utf-8", errors="replace")
        raw = raw.replace("\x00", "")
        lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        if dots:
            lines = [strip_dot_artifact(l) for l in lines]
        before = len(lines)
        lines = pair_dedup(lines)
        dst.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")
        print("%s -> %s  (%d -> %d lines, source %d B)"
              % (src.name, dst.name, before, len(lines), src.stat().st_size))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
