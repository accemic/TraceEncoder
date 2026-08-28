<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# axis_wp_demo -- deterministic TGC5B demo program + WP set + oracle (E0)

Bare-metal RV32I program for the AXIS watchpoint testbed (package C1 of the
the predecessor repository consolidation plan; migrated into this repository as
`examples/kv260/tgc5b2_axis_wp/`), after the pattern of
`examples/kv260/common/tgc5b/prog/` (CLINT @ 0x1000_0000, RAM 64 KiB @ 0x0, machine
mode).

## Determinism contract (CFI pre-stage)

- The timer IRQ is ONLY a pacer (`g_tick++`), it never calls a walk function.
- `main` runs EXACTLY ONE phase per tick -- the sequence of function entries
  does not depend on IRQ timing.
- Only deterministically executed addresses go into the WP set:
  `entry:` (leaves f000..f299 + run_phase_00..63), `call:` (direct calls in
  the runners), `body:` (follow-on addresses of the straight-line leaves).
  Excluded: `_start`/`halt`/`main` (spin loops), the IRQ path.

## Pipeline (order is binding)

```sh
py gen_program.py        # -> src/funcs.c src/walk.h expected_walk.txt (seed-fixed)
bash build.sh            # -> axis_wp_demo.elf/.dis/.hex   (BUILD_OK)
py gen_wp_set.py         # -> wp_set.txt (exactly 1023, hard-fails on fewer)
py check_consistency.py  # -> expected_hits.txt + E0_ALL_PASS (the gate)
```

Every generated artifact is committed -- sim/board runs need no toolchain and
no Python. `.pcinfo` (CEDARtools.TraceDecoder / historically "NexRv") arrives
with the decoder-attachment package.

## Runtime switches

- Default: `WALK_TOTAL_PHASES` (= 64) phases, then a halt loop (stable PC
  for the simulation).
- Board, endless variant 1: write a non-zero word to **0x0000E800**
  (`WALK_CTRL`) before releasing the core (devmem; the cell sits outside
  image/.bss, 2 KiB below the stack top 0xF000).
- Board, endless variant 2: `ENDLESS=1 bash build.sh` (`-DWALK_ENDLESS=1`).
- Progress: `SCRATCH[0]`=phase+1 @0xE000, `SCRATCH[1]`=g_acc,
  `SCRATCH[2]`=0x0E0DDA7A after the last walk.

## Toolchain

`build.sh` probes: `riscv32-unknown-elf-` (PATH) -> `riscv64-unknown-elf-`
(PATH) -> `C:/SysGCC/risc-v/bin/riscv64-unknown-elf-` (GCC 10.1.0), and
`-march=rv32i_zicsr` -> `rv32i` (GCC 10 does not know the `_zicsr` suffix but
implicitly includes Zicsr; `--no-warn-rwx-segments` is probed, only present
since binutils 2.39). Override with `CROSS=... MARCH=... PY=... bash build.sh`.

## Migration note

Migrated 2026-08 from an internal predecessor repository; already
self-contained and English at the source (ISC-licensed, no German comments) --
this migration copied the tree as-is and translated only this README (the
source repository's version was German) and re-ran the full pipeline above
in the new location to verify the committed generated artifacts
(`.dis`/`.hex`/`.pcinfo`/`wp_set.txt`/`expected_hits.txt`) are reproducible
byte-for-byte from `src/` in this repository.
