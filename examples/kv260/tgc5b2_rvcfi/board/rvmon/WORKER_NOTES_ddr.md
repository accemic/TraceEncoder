<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# WORKER_NOTES_ddr — DDR ring read path in rvmon

Worker notes, incremental (newest at the bottom). Scope: `rvmon.c`, `rvmon.h`
only. Coordinator builds the RTL/deploy side in parallel.

## 2026-08-26 13:2x — state survey (read-only)

* Scope clean: `git status --porcelain examples/kv260/tgc5b2_rvcfi/board/rvmon/`
  is empty. Foreign in-flight change OUTSIDE my scope:
  `rtl/tgc5b2_rvcfi_soc_top.sv` modified (the coordinator's N3 ring bank) —
  read-only consulted, not touched.
* Coordinator's in-flight RTL header matches the brief's register contract
  word for word (bank 0x80/0xA0, stride 0x20, RING_CTRL/BASE/SIZE/WPTR/STAT/
  DROPS/BEATS, clear pulse resets BEATS + cfg_rej_sticky, WPTR total bytes).
* Committed CTRL decode answers EVERY read (default arms -> 0 /
  `sinks_rd_data`), so a new rvmon against an OLD bitstream reads 0 at
  0x80.. instead of hanging; readback checks can catch that case cleanly.

### AFIFM research (task 7) — pattern FOUND

* Established shell pattern `afifm_width()` (read-modify-write of bits [1:0]
  = FABRIC_WIDTH, code 0=128/1=64/2=32, at base+0x0 RDCTRL and +0x14 WRCTRL):
  * `examples/dashboard/boot/cva6_linux64_run.sh:274-280` (definition, with
    the RMW rationale: reset 0x3B0 carries reserved-but-RW bits, a full write
    would clear them),
  * same helper in `examples/dashboard/boot/rocket_linux64_run.sh:265`,
    `examples/dashboard/boot/rocket2_linux_run.sh:320`,
    `examples/kv260/cva6_linux/board/cva6_linux_boot_trace.sh:197`,
    `examples/kv260/cva6_2/board/cva6_2_run.sh:128-131`.
* Documented defect history: `examples/kv260/SPEC_board_memory_map.md` §4
  ("psu_init does not run for a DFX app", ports reset to 128 bit; the
  128-vs-32 failure is SILENT: one word lands per 16-byte slot, all counters
  healthy — `cva6_2_run.sh:86-131`).
* rvcfi's own board scripts have NO AFIFM handling yet (grep over `board/`,
  `deploy.sh`, `run_board_verdicts.sh`: zero hits) -> rvmon `--route ddr`
  replicates the pattern in C before enable, for AFIFM2 (saxigp2, 0xFD38_0000)
  AND AFIFM3 (saxigp3, 0xFD39_0000), both to width code 2 (32 bit — the ring
  sinks are 32-bit write masters, `hp0_wdata[31:0]` in the KV260 top).

### Collisions found while reading rvmon.c (completeness pass)

1. `status` reads no legacy sink-bank registers (0x18–0x38) — nothing to
   relabel there; only new ring lines to add.
2. Usage text must gain `--route` on both `run` and `drain`.
3. `records ... rec/s` print divides by the drain window; a post-mortem
   `drain --route ddr` has a ~0 s window -> would print inf. Branch the print.
4. A crashed ddr run would leave `route_ddr=1`; a later plain (fifo) run
   would then capture NOTHING silently. Fix in scope: fifo-route `run`
   checks both ring banks and restores route_ddr=0 with a notice (cores are
   verified stopped at that point anyway).
5. End of a ddr run: brief says "en=0". Leaving route_ddr=1 would reproduce
   collision 4 by design, so the run teardown restores route_ddr=0 as well
   (ANNAHME, documented in the final report).
6. syntaxcheck.sh compiles the devmem half with stub headers that declare
   only `mmap` — new code therefore uses NO new libc symbols (no munmap, no
   usleep; time-based poll loops via the existing `now_s()`).

## 2026-08-26 13:4x — implementation + verification

### Changes

* `rvmon.h` (+40 lines, after the RUN-bit defines): ring bank constants
  (`RVM_CTRL_RING0/1` 0x80/0xA0, `RVM_RING_STRIDE`, register offsets
  CTRL/BASE/SIZE/WPTR/STAT/DROPS/BEATS, CTRL bits EN/CLEAR/CIRC/ROUTE_DDR,
  STAT bits FULL/AXIERR/WRAP/CFGREJ) + AFIFM constants (`RVM_AFIFM2_BASE`
  0xFD380000, `RVM_AFIFM3_BASE` 0xFD390000, RDCTRL +0x0, WRCTRL +0x14,
  `RVM_AFIFM_W32` = 2).
* `rvmon.c`:
  * new board-only section "DDR record rings (N3)" (`ring_bank()`,
    `afifm_narrow32()` — exact C replica of the shell `afifm_width()`
    read-modify-write, with source pointers in the comment —,
    `ring_extract()` with tear/wrap/cap handling, every cut REPORTED),
  * `status`: two lines per core (route/en/circ/base/size, then
    wptr/drops/beats/stat bits); reads 0 -> inert print on a pre-N3
    bitstream (committed CTRL decode answers unmapped reads with 0),
  * `run`/`drain`: `--route fifo|ddr` (default fifo, bit-identical
    behavior; verified: fifo path takes only the pre-existing code paths,
    plus ONE addition: a leftover route_ddr=1 from a crashed ddr run is
    restored to fifo with a printed note, cores verified stopped first),
  * ddr run order STRICT per contract: cores-stopped check (pre-existing
    die) -> AFIFM2+AFIFM3 to 32 bit -> per bank route_ddr at en=0 ->
    clear pulse -> en=1 (readback checks: EN sets, WPTR==0 -- catches a
    bitstream without the bank) -> drop-base snapshot -> unchanged
    publish/barrier/release -> end detection = WPTR standstill of BOTH
    rings for 0.4 s (time-based, budget still caps) -> stop cores
    (pre-existing way) -> WPTR rest-settle (50 ms stable, 0.3 s cap) ->
    ring_extract into b0/b1 (same buffers/files/analyze path) -> ring
    verdict -> en=0 + route restore,
  * `drain --route ddr`: post-mortem read, mutates NOTHING (no clear, no
    en change); drops reported as cumulative-since-clear,
  * verdict: shim delta (must be 0 in ddr route — extra hardware-contract
    message if not) OR ring-drop delta OR axi_err/cfg_rej_sticky =>
    `RUN_WITH_DROPS`/exit 3; each stat bit gets its own clear-text stderr
    line.

### Verification (all run by this worker, verbatim output)

1. Host build + selftest (msys64 ucrt64 gcc, exactly the brief's command):
   `gcc -O2 -std=c99 -Wall -Wextra -Wno-unused-parameter -I. -I../../sw/src
   -o /c/tmp/rvmon_worker.exe rvmon.c monitors.c` -> no warnings, then
   `SELFTEST_PASS` (ST1..ST5 all OK).
2. Board-half syntax on the host (syntaxcheck.sh recipe + the missing
   `-I. -I../../sw/src`): `SYNTAXCHECK_OK (board-only code compiles,
   include path added)`.
3. Linux build on the jump host (gcc 10.5, x86_64, devmem half REALLY compiled,
   `-Wall -Wextra` clean): `SELFTEST_PASS` (ST1..ST5 all OK).
   /tmp/rvmon_ddr_check removed afterwards.
4. Ring-extraction math probe (scratchpad `ring_math_test.c`, the same
   formulas against a software ring with known ground truth):
   `linear, no tear OK / wrapped OK / torn tail discarded OK /
   wrapped + torn OK / host cap keeps last OK / red probe (bad start)
   OK (mismatch detected)` -> `RING_MATH_PASS`.
5. `scripts/check_language.py`: zero findings in rvmon files; overall
   exit 1 is PRE-EXISTING (4 findings in `fpga/prebuilt/**/ctrace_resmem.dtso`
   comment blocks, identical on the committed state).

### Open points

* **Board leg not run** — kv260b is offline per the brief; nothing was
  tested against real /dev/mem. The ddr sequence, the AFIFM writes and the
  WPTR quiescence timing are board-verified only when the coordinator's
  bitstream exists.
* `syntaxcheck.sh` is BROKEN pre-existing (also on the committed state):
  it lacks `-I. -I../../sw/src`, so `#include "rv_shared.h"` fails before
  any checking happens. One-line fix in the script (out of my scope;
  coordinator owns board/ scripts).
* MAGIC (0x5C) does not version the register map: a NEW rvmon `--route ddr`
  against an OLD bitstream is caught by the EN/WPTR readback checks (reads
  0), but `status` simply shows an inert ring — consider a version field if
  the map keeps growing.
* WPTR is 32-bit total-bytes; after ~4 GiB written (>= ~9 min at full
  double-core rate) it wraps. The modulo math stays correct for the
  power-of-two default size; a NON-power-of-two WARL size plus a wrapped
  WPTR would mis-seam. Not handled host-side (no wrap indicator beyond
  32 bit exists in the contract).
* Record-rate print for a ddr RUN measures records against the run window
  (extraction happens after t1) — that is the production rate, not a drain
  rate; the drain-ddr case prints no rate at all.

### ANNAHMEN (deviations from the letter of the brief, each one line)

1. Teardown restores `route_ddr=0` in addition to the demanded `en=0`:
   leaving the mux on a disabled ring would silently blackhole the NEXT
   plain run's records (collision 4); reversal = drop two lines.
2. AFIFM: brief says "replicate for saxigp3"; implemented for saxigp2 AND
   saxigp3 (both ring write ports; the demo's board scripts configure
   neither today, and the RMW write is idempotent).
3. `cfg_rej_sticky`/`axi_err` map onto the existing `RUN_WITH_DROPS`
   marker (exit 3) instead of a new marker, so the coordinator's verdict
   script keeps a two-state contract; the stderr text names the real cause.
4. No row added to `the predecessor repository/docs/TASK_STATE.md`: that file is the
   archived CTTE-program state (repo is EVIDENZ-ARCHIV); this notes file
   is the package handoff per the brief.

## 2026-08-26 13:5x — late addition + final re-verification

* Added a warning to `drain --route ddr` when a core is still RUNNING
  (post-mortem read races the sink across the wrap seam).
* Full chain re-run on the FINAL state: host build no warnings +
  `SELFTEST_PASS`; board-half `SYNTAXCHECK_OK`; jump-host Linux build no
  warnings + `SELFTEST_PASS` (temp dir removed).
* An Edit-tool notice ("file modified on disk") was investigated: the
  residual diff scan showed ONLY my own change set (blank lines + one
  re-indent) — cause was the stash pop's on-disk rewrite, no foreign edit.

### Lesson (for the coordinator)

The two language-guard/syntaxcheck comparisons against the committed state
were done with `git stash`; the FIRST was pathspec-limited (safe), the
SECOND was repo-wide `--include-untracked` while the coordinator had
in-flight edits — it popped cleanly, but a coordinator write landing inside
that window would have collided. Repo-wide stashes in a shared checkout
with a live parallel worker are a mistake; compare against `git show
HEAD:file` copies in a scratch dir instead.

