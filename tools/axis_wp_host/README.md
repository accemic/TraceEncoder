<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# `tools/axis_wp_host` — AXIS watchpoint host reader

Host-side (Python) consumer of the encoder's AXIS watchpoint/DAQ stream.
It turns the raw bytes coming off an `axi_fifo_mm_s` (PG080) FIFO — or a
raw dump file of the same wire format — into checked, structured
watchpoint records, and it drives the indirect watchpoint-table load
protocol used to program the encoder's search tree.

No external dependencies; standard library only.

## Modules

- **`wp_records.py`** — parser/decoder for the 4-word watchpoint record
  (`W0` PC, `W1` DirectData, `W2` Timestamp, `W3` Meta: `tid`/`tstrb`/
  `core_id`). Validates reserved bits and `tstrb` plausibility per
  record, flags malformed stream remainders, and splits a stream by
  `core_id` — without ever raising on garbage input (the reader counts,
  it does not die).
- **`fifo_mm_s.py`** — RX backend for the AMD `axi_fifo_mm_s` (PG080)
  IP: a `/dev/mem`-backed `DevMemBus` plus the `FifoMmS` packet read
  loop (`RDFO` → `RLR` → `RDFD`), including a non-destructive default
  init, an explicit destructive RX reset, and a poll-based continuous
  drain (`drain_poll`) for long-running captures.
- **`wp_load_indirect.py`** — the indirect watchpoint-table load path
  (`trWpIndex`/`trWpDataLow`/`trWpDataHigh`/`trWpReadLow`/`trWpReadHigh`/
  `trWpCap`, see `docs/SPEC_axis_wp_memory_map.md` §7): loads the full
  search-tree table, proves the autoincrement/wrap contract, and spot
  checks individual slots via the serial-readback registers.
- **`checks.py`** — stream-level checks: per-core timestamp
  monotonicity (with a documented 32-bit wrap heuristic, a strict mode,
  and an off mode), PC membership against an expected address set,
  a drop-tolerant subsequence check against an expected hit sequence
  (optionally periodic, for endless-walk captures), and a multi-core
  stream merge by unrolled timestamp.
- **`read_wp_stream.py`** — the CLI that ties the above together:
  reads from a file or live from a FIFO (one-shot or continuous poll),
  runs the enabled checks, and exits non-zero on the first failing one.
- **`test_axis_wp_host.py`** — the self-test (see below).

## Consumer

The dashboard's watchpoint view, `examples/dashboard/wp_view.py`,
imports `axis_wp_host.fifo_mm_s.FifoMmS`/`DrainStats` and
`axis_wp_host.wp_records.Record` directly — it **consumes** this
library, it does not copy or reimplement it. It resolves the import
either from a board-deployed `axis_wp_host/` folder next to `wp_view.py`
or, in the repo layout, from `tools/axis_wp_host` at the repo root (this
directory). If the library cannot be found, the dashboard degrades
gracefully: `AXIS_WP_HOST_AVAILABLE` is set to `False` and the
watchpoint view becomes a documented no-op instead of taking the whole
server down.

## Running the self-test

```
py tools/axis_wp_host/test_axis_wp_host.py
```

No pytest required (plain asserts, each `test_*` function called
directly). Expected last two lines:

```
tests=42 records-layout=D0(W0 PC/W1 direct/W2 ts/W3 meta)
F0_ALL_PASS
```

`wp_load_indirect.py` also carries its own offline self-test (a
reference-model check of the indirect load protocol, independent of the
FakeBus used above):

```
py tools/axis_wp_host/wp_load_indirect.py
```
