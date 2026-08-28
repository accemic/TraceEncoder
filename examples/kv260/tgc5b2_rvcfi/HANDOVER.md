<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

> **Handing this demo to someone who wants to trace their own software?**
> Read [HANDOVER_trace_your_own_software.md](HANDOVER_trace_your_own_software.md).
> This file is the development log: state snapshots, newest first.

# Handover — RV/CFI demo, state at 2026-08-26 17:10 WEDT (N3 DONE on silicon)

**N3 is measured on silicon — nothing is pending.** The board legs ran on a
SECOND, differently provisioned KV260 (the first is physically away): the
prebuilt fast path deployed there from zero (`--prebuilt`: manifest check,
75 MHz with readback, md5, MAGIC ok), the twin verdict table is green over
all 12 legs (`BOARD_VERDICTS_OK`, FIFO and DDR tables identical leg for
leg, drop delta 0/0 everywhere), the console echoed live, and the two
loss-freedom proofs landed: the exact run the FIFO path lost 59805/64982
records on is `RUN_OK` with ring drops 0/0, and a full-tilt run of ~1.14
million records per core (100000 iterations, pace 0) is also `RUN_OK` with
ring drops 0/0. The board was restored afterwards (app unloaded, dashboard
service active again — the state it was found in).

---

# Handover — RV/CFI demo, state at 2026-08-26 15:25 WEDT (superseded)

**N3 — the DDR fast lane — is built, simulated green, and waiting only for
the board.** Two 128-MiB record rings in the 256-MiB reserved window (core 0
at `0x5000_0000`, core 1 at `0x5800_0000`), one `ct_soc_ddr_sink` per core
on its own 32-bit PS HP port, a route mux per core (FIFO path stays the
bit-identical default; ring mode shows the shim an always-ready consumer),
register bank at CTRL `0x80`/`0xA0` with a WARL window guard. Tutorial
section 10c documents it; `rvmon run --route ddr` drives it (AFIFM width
handling for both ports included, ring extraction wrap/tear-proofed).

Measured: `VERDICTS_OK` over SEVEN sim legs (six original claims unchanged,
`ddr` leg record-equal to the AXIS reference: 684/696, 0 drops);
`tb_rvcfi_smoke` 52 checks incl. the WARL reject/exact-fit matrix; N3
bitstream `BITSTREAM_OK` WNS **+1.550 ns**, `MEMKIND_OK`; `fpga/prebuilt/`
carries the N3 app (manifest-verified; the board-verified pre-N3 app is one
git step back). **Pending: every silicon leg of N3** — the board went
offline as the build finished; next action when it returns is
`deploy.sh --prebuilt` and `run_board_verdicts.sh` (now a twin table:
six FIFO legs + six DDR legs).

Found on the way, worth keeping: a Tcl dict literal swallows `#` lines as
DATA (gen_ip config block — create died on "Missing name/value pair");
`base+size == window-end` is legal and the first smoke bench wrongly called
it illegal; the language guard walks TRACKED files only, so red-probe it
with a tracked file.

---

# Handover — RV/CFI demo, state at 2026-08-26 08:35 WEDT (superseded)

**DONE — measured on silicon.** `BOARD_VERDICTS_OK`: all six legs green on
the KV260 (m0 CLEAN, m1 10, m2 8, m3 exactly 1, m4 exactly 2, cap CLEAN),
0 dropped records in every paced leg, console proven live in both
directions on both cores, record counts equal to simulation to the record
(684/696 on m0). Bitstream with the console: `BITSTREAM_OK`, WNS
+2.217 ns, `MEMKIND_OK`. The tutorial's status banner carries both verdict
tables; the completion report lives in the internal archive repository.

Board notes that outlive this session: the second KV260 was re-imaged
(Ubuntu 24.04 -- previous ssh keys, gcc and the dashboard service are
gone); only the jump host's key opens it, so the deploy ran ON the jump host
with the versioned `--skip-package` mode (packaging with bootgen happens on
the build host). The router holds two DHCP leases for the board's name; it
came up under the newer one, so check the address before trusting the name.
The demo app is LEFT LOADED (MAGIC readable) so
the next person can start at `rvmon status`.

## What the silicon run found (all fixed, all committed)

Six real defects that only the first non-dry run could catch: `copy()`
passed the destination twice to scp; `rv_shared.h` staged where no
include path looked; no `set -e` (a red build sailed into the load
phase) plus exit-eating `| tail` pipes; the pl_clk setter was never
staged and was called positionally (show-only) and after loadapp —
against its own contract; `cap_every` was never published per run
(UltraRAM keeps stale values); drop counters are cumulative since load
and a clean leg failed on the previous run's totals — `rvmon run` now
judges the per-run DELTA.

---

# Handover — RV/CFI demo, state at 2026-08-26 06:55 WEDT (superseded)

Supersedes the 2026-08-25 state below (kept for history). Everything is
committed; the two long runners (final sim round, bitstream with the console)
report into `fpga/logs/bitstream.out` and the task log.

## What changed since the previous handover

* **The ACT-CAP doorbell defect is FOUND AND FIXED** (BVALID in the accept
  cycle — an AXI violation the TGC5B bus does not survive; one pending stage
  fixes it, read path too). 30 stores → 30 conversions → 0 drops.
* **Console per core (N1)**: `ct_soc_console` (TX+RX 2 KiB FIFOs), core side
  `0x4000_0100`, PS side CTRL bank `0x60`/`0x70`, `rvmon console` as the
  terminal. Proven end to end in simulation: greeting + PING echo, both
  directions, all modes.
* **AXIS overflow (N2)** was already built; now documented (tutorial §10b).
* **M3 verified**: lock-order instrumented (4 sites, static ids), 840
  records/core. Two roots fixed on the way: `tag_of` hardcoded lock 0 (one
  zero, two wrong verdicts), and the monitors track holding on `acq_ok`.
* **Runtime-preference rule**: acquires/releases also report their RUNTIME
  lock id via ACT-CAP; monitors ignore static sync tags whenever runtime ones
  are present. This closes M2 (`mon_lockset`) — final round pending.
* **`rvmon run` deadlock fixed**: the inherited code released the cores
  before opening the barrier and polled the mailbox while they ran — the
  exact shared-memory wedge the e2e bench had already found.

## Next steps (in order)

1. When the current sim round completes: `bash sw/build.sh` (regenerates
   programs WITH runtime sync tags + tables), then re-run the six legs, then
   `bash sim/run_verdicts.sh` — expected: `VERDICTS_OK` with m2 found by
   `mon_lockset` and m3 by `mon_order`.
2. Bitstream: judge `fpga/logs/bitstream.out` by `BITSTREAM_OK` + `MEMKIND_OK`
   markers, never by exit codes.
3. Board: `bash board/deploy.sh --board <ip>` (lease `trace-hw-kv260` first),
   then per mode `rvmon load/run`, `rvmon console --core N`, `run_verdicts`
   against the board captures. Restore via `--restore`.
4. Tutorial banner → measured verdicts; completion report in the internal
   archive (`docs/REPORT_*`, §17.12 shape).

Deferred by decision (planning note in the internal archive): DMA into a DDR4 ring
(~half a day, own package).

---

# Handover — RV/CFI demo, state at 2026-08-25 11:00 WEDT

Written because the machine is being shut down. Everything below is
committed; nothing needed to continue lives only in a shell.

---

## 1. Where things stand

**Green and measured** (every figure has a named artifact):

| Item | Verdict |
|---|---|
| Shared memory in UltraRAM | `PROBE_OK` — 16 URAM, 0 BRAM |
| Bitstream | `BITSTREAM_OK`, WNS **+2.188 ns**, `MEMKIND_OK` (BRAM 105.5 unchanged, URAM 48) |
| Unit testbenches | `tb_shared_mem` 846 · `tb_doorbell` 17 · `tb_actcap_adapter` 54 · `tb_rvcfi_smoke` 24 |
| Host analyser | `rvmon selftest` → `SELFTEST_PASS` (5 cases, incl. the red probe ST3) |
| Programs + tables | `GEN_OK` / `BUILD_OK` / `SITES_OK` — 1004 ACT-ST + 50 ACT-CAP sites per core |
| End-to-end simulation | all five modes ran, 600/600 records per core, **0 drops everywhere** |
| ACT-CAP software path | 30 doorbell stores → 30 conversions → 630 records, 0 drops |

**The five verdicts as measured** (simulation, `rvmon` on the sim dumps):

| Mode | Verdict | Assessment |
|---|---|---|
| `M0_SAFE` | **CLEAN — no findings** | correct, and the hardest one to earn |
| `M1_RACE_OPEN` | 13 findings (proto + lockset + hb), sites named | correct |
| `M2_RACE_WRONG_LOCK` | 8 findings, **only `mon_hb`** | detected, but not by the intended monitor — see §3 |
| `M3_LOCK_ORDER` | CLEAN | **was wrong**; the fix is committed but NOT yet re-run — see §2 |
| `M4_CFI_SKIP` | 2 findings, one per core, both at iteration 30 (= `iters/2`) | exactly as designed |

**Open:** the board run has not happened. Nothing in this demo has touched
hardware yet; all of the above is simulation plus the synthesis reports.

---

## 2. Do this first after the restart

The lock-order fix is **committed but unverified**. `main.c` now calls an
instrumented `rv_lock_order()` (four sync sites, static lock ids 2/3) instead
of writing the lock flags directly. The programs and tables have been rebuilt
(1004 sites), but the M3 leg has not been re-run.

```bash
cd /d/shared/engineering/C-Trace

# 1. re-run the lock-order mode
(. ./scripts/ct_env.sh && ct_need_abc && cd bld && \
  abc -sim ../examples/kv260/tgc5b2_rvcfi/sim/tb_rvcfi_e2e_m3.abc) | \
  grep -E "TB_PASS|%Fatal"

# 2. judge it
R=examples/kv260/tgc5b2_rvcfi/board/rvmon/rvmon
M=examples/kv260/tgc5b2_rvcfi/sw
D=bld/tb_rvcfi_e2e_m3.vsim
./$R analyze --in0 $D/rvcfi_e2e_m3_core0.hex --in1 $D/rvcfi_e2e_m3_core1.hex \
             --map0 $M/sites_core0.csv --map1 $M/sites_core1.csv --seed 0x1234
```

**Expected:** `mon_order` reports a lock-order inversion between locks 2 and
3. If it still says CLEAN, check that the sync records for locks 2/3 are in
the stream at all — a monitor cannot find what the trace does not contain,
and that was exactly the original defect.

Then re-run the other four modes, because the rebuild moved every address:
`tb_rvcfi_e2e_m0/m1/m2/m4` plus `tb_rvcfi_e2e_cap` (the ACT-CAP leg).

> **The trap that cost the most time last night:** a rebuild shifts the code,
> and a stale watchpoint table shifts every tag by one site. The result is
> not an error — it is a well-formed record stream that means something else,
> and a correctly locked run produced 13 fictional findings. `build.sh` now
> regenerates the tables itself, so simply always build through `build.sh`.

---

## 3. The two known gaps, with their causes

**M2 — `mon_lockset` is silent although this is *the* lockset case.**
The lock identity in that scenario is chosen at **run time**
(`lk = (mode == WRONG_LOCK) ? core : 0`), while an ACT-ST tag is fixed when
the table is **loaded**. `gen_sites.py` therefore writes the static lock id,
both cores look as if they held the same lock, and the intersection never
empties. `mon_hb` finds the defect anyway.

This is a real limitation of hardware watchpoints, not a bug, and it is
precisely what ACT-CAP exists for. The fix — now that the doorbell works —
is to emit the *actual* lock mask as a runtime ACT-CAP tag at each acquire
and let `mon_lockset` prefer it when present. That is a good next work item
and it demonstrates why the demo carries both instrumentation paths.

**ACT-CAP defect — found and fixed.** `ct_soc_doorbell` asserted `BVALID` in
the same cycle as `AWREADY`/`WREADY`, i.e. before the write transfer
completed. AXI forbids it and the TGC5B data bus wedges on the second
doorbell store of a pair. A pending stage fixes it (the shared memory next
door always had one, which is why it never showed the problem). The read path
had the same defect and was staged too. Verified: 30/30 conversions, 0 drops.

---

## 4. What is not written yet

* **Board run.** `board/deploy.sh` exists (`--dry-run` prints every command
  it would issue) but has never talked to a board. `rvmon status` verifies
  the load by reading the design's own MAGIC, which is the only evidence
  worth having.
* **Tutorial banner.** `TUTORIAL_runtime_verification.md` still marks §8/§9
  as "not yet measured". Four of the five verdicts are now measured in
  simulation and belong in there, clearly labelled as simulation rather than
  board.
* **Completion report** in the internal archive (`docs/REPORT_*`),
  following the §17.12 shape.

---

## 5. Where everything is

```
D:\shared\engineering\C-Trace\examples\kv260\tgc5b2_rvcfi\
  rtl/        shared memory (URAM), ACT-CAP doorbell, adapter, demux, SoC top
  sim/        unit TBs + tb_rvcfi_e2e (five mode legs, plus _cap and _nocap)
  sw/         generators, both programs, watchpoint tables, site maps
  board/      deploy.sh + rvmon/ (host analyser, five monitors)
  fpga/       Vivado project, bitstream driver, probe_shared_mem.tcl
  TUTORIAL_runtime_verification.md
```

Planning and findings live in the archive repo:
the internal archive repository (planning and findings notes).

The checkout of this branch is **shared** —
commit with an explicit pathspec, never `git add .`, and note that two files
under `examples/kv260/common/` carried someone else's uncommitted changes
throughout this work and were never touched.
