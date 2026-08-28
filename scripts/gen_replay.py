#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""gen_replay.py -- oracle PC sequence + pcinfo -> cpu_model replay task (replay_seq.svh).

    python3 gen_replay.py <oracle.u32> <prog.pcinfo> -o replay_seq.svh \
        [--start N] [--count N] [--task-name replay_board_seq]

From an oracle PC sequence (little-endian u32) and the NexRv pcinfo
(`ADDR,TYPE SIZE[,TARGET]`) this generates a SystemVerilog task that drives the
EXACT instruction sequence through `env.cpu` -- including the real
branch-outcome history, and therefore the real predictor training, which
synthetic rings cannot reproduce.

pcinfo type -> cpu_model mapping:
    L   sequential             -> run(<bytes>) (consecutive runs merged)
    BD  cond. direct branch    -> branch_taken/branch_not_taken(.target(T))
    JD  direct jump (jal x0)   -> jump_to(.target(T))
    CD  direct call (jal ra)   -> call_to(.target(T))
    JI  indirect jump (jalr x0)-> uninferable_jump(.target(<next PC>))
    R   return (jalr x0,(ra))  -> ret()  (the cpu_model stack has to stay
                                          consistent -- the real sequence
                                          guarantees it)

Unknown types, or gaps in the sequence (a PC jump with no control-flow type),
abort LOUDLY rather than being dropped silently. The task is split into blocks
of 1500 statements to stay within the xvlog limit.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


def read_u32(path: Path) -> list[int]:
    raw = path.read_bytes()
    return list(struct.unpack(f"<{len(raw) // 4}I", raw[: len(raw) // 4 * 4]))


def read_pcinfo(path: Path) -> dict[int, tuple[str, int, int | None]]:
    info: dict[int, tuple[str, int, int | None]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2 or not parts[0].startswith("0x"):
            continue
        addr = int(parts[0], 16)
        t = parts[1]
        kind, size = t[:-1], int(t[-1])
        target = int(parts[2], 16) if len(parts) > 2 and parts[2] else None
        info[addr] = (kind, size, target)
    return info


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("oracle", type=Path)
    ap.add_argument("pcinfo", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--start", type=int, default=0, help="start index in the oracle sequence")
    ap.add_argument("--count", type=int, default=2500, help="number of instructions")
    ap.add_argument("--task-name", default="replay_board_seq")
    ap.add_argument("--chunk", type=int, default=1500)
    # Width of the generated address literals. It has to match the encoder
    # build (ct_pkg::CT_XLEN): a 32'h literal fed to a 64-bit tip_iaddr_t
    # port zero-extends, which is fine for a low address and silently wrong
    # for anything above 4 GiB. Default 32 keeps every already generated
    # replay file reproducible byte for byte.
    ap.add_argument("--xlen", type=int, choices=(32, 64), default=32,
                    help="address literal width of the generated task (default 32)")
    args = ap.parse_args()
    lit_w, lit_d = (args.xlen, args.xlen // 4)

    def addr(v: int) -> str:
        return f"{lit_w}'h{v:0{lit_d}x}"

    pcs = read_u32(args.oracle)[args.start: args.start + args.count]
    info = read_pcinfo(args.pcinfo)
    if not pcs:
        print("### empty sequence", file=sys.stderr)
        return 2

    stmts: list[str] = []
    run_bytes = 0

    def flush_run():
        nonlocal run_bytes
        if run_bytes:
            stmts.append(f"env.cpu.run({run_bytes});")
            run_bytes = 0

    for i, pc in enumerate(pcs):
        kind, size, target = info.get(pc, (None, 4, None))
        if kind is None:
            print(f"### PC 0x{pc:x} not in pcinfo (index {args.start + i})", file=sys.stderr)
            return 3
        nxt = pcs[i + 1] if i + 1 < len(pcs) else None
        seq = pc + size
        if kind == "L":
            if nxt is not None and nxt != seq:
                print(f"### sequence gap at L instruction 0x{pc:x} -> 0x{nxt:x} "
                      f"(index {args.start + i}) -- type missing in pcinfo?", file=sys.stderr)
                return 3
            run_bytes += size
            continue
        flush_run()
        if kind == "BD":
            assert target is not None, hex(pc)
            if nxt is None or nxt == seq:
                stmts.append(f"env.cpu.branch_not_taken(.target({addr(target)}));")
            elif nxt == target:
                stmts.append(f"env.cpu.branch_taken(.target({addr(target)}));")
            else:
                print(f"### BD 0x{pc:x}: successor 0x{nxt:x} is neither seq nor target 0x{target:x}",
                      file=sys.stderr)
                return 3
        elif kind == "JD":
            stmts.append(f"env.cpu.jump_to(.target({addr(target)}));")
        elif kind == "CD":
            stmts.append(f"env.cpu.call_to(.target({addr(target)}));")
        elif kind == "JI":
            if nxt is None:
                break
            stmts.append(f"env.cpu.uninferable_jump(.target({addr(nxt)}));")
        elif kind == "R":
            stmts.append("env.cpu.ret();")
        else:
            print(f"### unhandled pcinfo type {kind!r} at 0x{pc:x}", file=sys.stderr)
            return 3
    flush_run()

    chunks = [stmts[i:i + args.chunk] for i in range(0, len(stmts), args.chunk)]
    out: list[str] = []
    out.append(f"// AUTO-GENERATED by scripts/gen_replay.py -- {args.oracle.name} "
               f"[{args.start}:{args.start + len(pcs)}] ({len(pcs)} instructions from "
               f"PC 0x{pcs[0]:08x})")
    for ci, chunk in enumerate(chunks):
        out.append(f"task automatic {args.task_name}_c{ci}();")
        for s in chunk:
            out.append(f"\t{s}")
        out.append("endtask")
    out.append(f"task automatic {args.task_name}();")
    out.append(f"\tenv.cpu.enter(.start_pc({addr(pcs[0])}));")
    for ci in range(len(chunks)):
        out.append(f"\t{args.task_name}_c{ci}();")
    out.append("endtask")
    args.out.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"# {len(pcs)} instructions -> {len(stmts)} statements in {len(chunks)} chunks: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
