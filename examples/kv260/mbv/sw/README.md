<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/mbv/sw — RV32 test programs (stimulus + static oracle)

Vivado-independent (GCC 10.1.0, `rv32im/ilp32`). `make` builds, per program, an
ELF + disassembly (`.dump`) + size report.

Migrated from an internal predecessor repository (2026-08-17)).

## Purpose

These programs run on the real MicroBlaze-V core (via [`../fpga/`](../fpga/)'s
Vivado flow) and generate the AMD `TRACE`-bus stimulus that
[`rtl/adapters/amd_microblaze_v/`](../../../../rtl/adapters/amd_microblaze_v/)
converts to a CTTE TIP stream. Usage:
- **Program flow:** `trace_test.S` / `branch_test.c` / `sijump_test.S` cover
  linear code, taken/not-taken branches, direct/indirect calls and returns,
  and sequentially-inferable-jump pairs.
- **Traps:** `trap_test.S` (ecall/ebreak), `illegal_test.S` (illegal
  instruction), `misaligned_test.S` (misaligned load/store) exercise the
  synchronous-exception path through the shared [`crt0.S`](crt0.S) handler.
- **Interrupts:** `interrupt_test.c` exercises the asynchronous-interrupt path.
- **Data trace (stimulus only, not a program-flow goal):** `data_trace_test.c`.
- **Robustness / overflow-recovery:** `jalr_storm_test.S` (a fixed
  uninferable-jump storm proving on-chip overflow->resync) and
  `rob_stress.S` (the same storm/calm shape, but fully parameterized via a
  RAM block the host overwrites before each run, for board hardening
  campaigns).
- **RVC raw-encoding measurement:** `rvc_test.S` (built separately with
  `rv32imc`; not part of the RV32-without-C baseline).

## Programs

| File | Sequence | `itype` classes covered |
|---|---|---|
| `trace_test.S` | linear - not-taken - taken - branch-dense loop | OTHER, NOT_TAKEN_BRANCH, TAKEN_BRANCH |
| `branch_test.c` | direct call - body - return - indirect call - indirect return | INFERRABLE_CALL, RETURN, UNINFERABLE_CALL, OTHER_INFERABLE_JUMP |
| `sijump_test.S` | adjacent auipc/lui+jalr pairs (inferable) + two non-adjacent negative cases | INFERRABLE_CALL/JUMP vs. UNINFERABLE_CALL |
| `trap_test.S` | ecall - handler - mret - ebreak | EXCEPTION_TRAP (ecall/ebreak) |
| `illegal_test.S` | illegal instruction (`.word 0x0`) -> fault - handler - mret | EXCEPTION_TRAP (cause 2) -- fault class |
| `misaligned_test.S` | misaligned load + store -> data-access faults - handler - mret | EXCEPTION_TRAP (cause 4 + 6) |
| `interrupt_test.c` | external interrupt - handler - mret | INTERRUPT |
| `data_trace_test.c` | load/store | data trace -- stimulus only |
| `jalr_storm_test.S` | fixed uninferable-jump storm/calm bursts | on-chip overflow -> resync recovery |
| `rob_stress.S` | parameterized storm/calm bursts (RAM-configurable) | robustness campaign sweep axis |
| `rvc_test.S` | mixed 16-/32-bit instructions (needs `C_USE_COMPRESSION=1`) | RVC raw-encoding measurement |

`crt0.S` supplies `_start` + a shared trap handler (mepc+=4 on a synchronous
trap; a weak `mei_handler` hook for interrupts). `link_mbv_rv32.ld` places
`_start` at ORIGIN(RAM) = the reset vector, matching the mbv example SoC's
128 KiB LMB BRAM (see [`../rtl/mbv_soc_top.sv`](../rtl/mbv_soc_top.sv)).

## Build

```bash
make            # elf + dump + size
make clean
# overrides:  make RISCV_BIN=... PYTHON=... MARCH=rv32im_zicsr
```

Output goes to `build/` (gitignored).

**Known gap:** the `oracle`, `memh`, `coe`, and `syms` Makefile targets call
three small Python helpers
(`objdump_to_oracle.py`, `bin_to_memh.py`, `robustness/nm_to_json.py`) that
still live only in the predecessor repository's `tools/` tree. This migration's scope
covers `examples/kv260/mbv/` only, so they were not vendored here; those four
targets fail with a "tool not found" error until a future step migrates
`tools/` (or the targets are pointed at a local override via
`ORACLE_TOOL=`/`MEMH_TOOL=`/`NM_TOOL=`, see the Makefile). `elf`, `dump`, and
`size` -- the targets this README documents -- do not depend on them and
build standalone.
