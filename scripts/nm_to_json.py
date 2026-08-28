#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""nm output -> JSON {symbol: address}.

    riscv64-unknown-elf-nm build/rob_stress.elf | py tools/robustness/nm_to_json.py > build/rob_stress.syms.json

Why: the board agent has to address `rob_params` / `rob_status` but has no RISC-V
toolchain. The symbol table is therefore frozen at build time.
"""
import json
import sys


def main() -> int:
    syms: dict[str, int] = {}
    for line in sys.stdin:
        parts = line.split()
        if len(parts) != 3:
            continue  # undefined symbols ("         U foo") have only 2 fields
        addr, _kind, name = parts
        try:
            syms[name] = int(addr, 16)
        except ValueError:
            continue
    json.dump(syms, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
