<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Tutorial — runtime verification and CFI checking on two RISC-V cores

> Everything in this tutorial is **measured**, in simulation and on
> KV260 silicon. The status table and both verdict tables are in §16.

This demo runs two RISC-V programs on two TGC5B cores that share memory,
instruments **every** shared access in hardware, and lets a program on the
board's Linux side decide whether the two cores got along.

It finds data races, unprotected accesses, lock-order inversions and
control-flow-integrity violations — and, just as importantly, it stays
**quiet** when the software is correct.

You do not need to have built any of it to follow along. Sections 1–4 are
reading; section 5 is the first thing you type.

> **Want to run your own program on this setup?** Read
> [HANDOVER_trace_your_own_software.md](HANDOVER_trace_your_own_software.md),
> the operational guide: build your program, set watchpoints on your
> functions, read the raw records. This tutorial is the demo's story: what
> the five modes plant, and which monitor catches which.

---

## 1. What you are going to see

Five runs of the same binary, differing only by a mode word the host writes
into shared memory before releasing the cores:

| Mode | What the programs do | What `rvmon` must say |
|---|---|---|
| `M0_SAFE` | every account update inside a correct Peterson lock | **nothing** — the detector must not cry wolf |
| `M1_RACE_OPEN` | the lock around the account update is skipped | a data race, both sites named — **and the account is measurably wrong at the end** |
| `M2_RACE_WRONG_LOCK` | both cores lock, but each takes a *different* lock | a lockset finding, even though the accesses never had to overlap in time |
| `M3_LOCK_ORDER` | two locks, taken in opposite order by the two cores | a lock-order inversion — for a deadlock that **did not happen** in this run |
| `M4_CFI_SKIP` | one dispatch index is corrupted | a forward-edge CFI violation, found before any data is damaged |

The interesting part is not that findings appear. It is *which* monitor
finds *which* mode. `M2` is the case a "did they happen close together?"
heuristic cannot see, and `M3` is a defect that the run itself never
exhibited.

---

## 2. How it works, in one page

Each core has its own trace encoder (CTTE). Inside each encoder sits a table
of **1023 watchpoint slots** — addresses of instructions; the demo fills 1000
of them with real sites. When the core retires an
instruction whose address is in the table, the encoder emits one 96-bit
record **without the core doing anything at all**: no instrumentation code,
no cycles, no probe effect.

```
TGC5B-0 --retire--> CTTE0 --ACT-ST (1023 slots)--> shim0 --> FIFO0 --+
   |                                                       0xA041_0000  |
   +-- port A --+                                                       +--> rvmon
                +-- shared memory, 256 KiB UltraRAM                     |    (PS Linux)
   +-- port B --+                                                       |
   |                                                       0xA042_0000  |
TGC5B-1 --retire--> CTTE1 --ACT-ST (1023 slots)--> shim1 --> FIFO1 --+
                                     |
                        one shared fabric counter -> timestamp in BOTH encoders
```

Each record carries four 32-bit words: the **PC**, a **24-bit tag** that says
what that site means, a **timestamp**, and metadata including which core it
came from. The timestamp is what makes the whole thing work: both encoders
are fed by *one* free-running counter, so equal timestamps mean genuine
simultaneity across the two cores.

There is a second, software-side instrumentation path: **50 ACT-CAP sites**
per core. Those are single store instructions, and unlike a watchpoint they
can carry a value computed at run time — a ring index, an account value, the
lock mask actually held. Eight of them are deliberate twins of watchpoint
sites, so two independent mechanisms report the same event and can be
compared.

> **Why the two paths differ.** A watchpoint costs nothing and carries a tag
> fixed when the table was loaded. An ACT-CAP site costs one instruction and
> carries a tag computed at run time. The demo uses both, on the same
> program, so you can see the trade-off rather than read about it.

---

## 3. What you need

* A **KV260** with the PS running Ubuntu, reachable over SSH.
* For rebuilding the bitstream: **Vivado 2026.1**. Not needed if you use the
  packaged app. A 2024.2 build of the pre-N3 design was also verified on the board.
* For rebuilding the programs: a **RISC-V GCC** (`riscv32-` or `riscv64-`
  unknown-elf). Not needed to run — every generated artifact is committed.
* `py` (Windows) or `python3` (Linux) for the generators. Not needed to run.
* On the board: a C compiler for `rvmon`. Ubuntu's `build-essential` is
  enough; there are no libraries to install.

Nothing here needs a trace decoder. The AXIS records are uncompressed, which
is one of the reasons this demo is a good first contact with the encoder.

---

## 4. The files, and which one is the source of truth

```
examples/kv260/tgc5b2_rvcfi/
  rtl/          the SoC: shared memory, ACT-CAP doorbell, adapter, SoC top
  sim/          unit and integration testbenches
  sw/           the two RISC-V programs, the generators, the tables
  board/rvmon/  the host analyser (C, no dependencies)
  fpga/         Vivado project, bitstream driver, the memory-kind probe
```

Two contracts are shared by more than one program and are therefore
single-sourced. Read these before changing anything:

* `sw/src/rv_shared.h` — the layout of the shared memory block. Read by both
  RISC-V programs *and* by `rvmon`. It carries a compile-time layout guard:
  move a field and the **build** breaks, not the analysis.
* `sw/src/rv_tags.h` — the 24-bit tag format. Read by the programs, by the
  table generator and by `rvmon`. `gen_sites.py` *parses* the constants out
  of this header rather than restating them, so the two cannot drift apart
  silently.

---

## 5. Run it without building anything

```bash
# on your workstation: check the analyser works at all
cd examples/kv260/tgc5b2_rvcfi/board/rvmon
make && ./rvmon selftest
```

Expected, and this is a real gate rather than a smoke test:

```
ST1 malformed record rejected     : OK
ST2 correct locking -> no findings : OK
ST3 unlocked race reported        : OK
ST4 lock-order inversion found    : OK
ST5 timestamp wrap unrolled       : OK

SELFTEST_PASS
```

**Why ST3 matters more than ST2.** ST2 shows the monitors are quiet on
correct code. On its own that proves nothing — a monitor that never reports
anything also passes it. ST3 feeds the *same accesses without the locks* and
requires that lockset, protocol **and** happens-before all speak up. Together
they show the monitors can tell the two apart.

`rvmon selftest` and `rvmon analyze` work with no hardware at all. That is
deliberate: you can develop a new monitor on your laptop and only go near the
board when you want to see it fire on silicon.

---

## 6. Build the programs

```bash
cd examples/kv260/tgc5b2_rvcfi/sw
py gen_program.py        # -> src/rv_funcs_core{0,1}.c, src/rv_funcs.h, manifests
bash build.sh            # -> rvcfi_core{0,1}.{elf,dis,hex,sym}
py gen_sites.py          # -> wp_table_core{0,1}_{full,hot}.txt, sites_core{0,1}.csv
```

Expected:

```
core 0: 100 functions, 1000 ACT-ST sites, 50 ACT-CAP sites
core 1: 100 functions, 1000 ACT-ST sites, 50 ACT-CAP sites
GEN_OK: 1000 ACT-ST + 50 ACT-CAP sites per core

[build] CROSS=riscv64-unknown-elf-  MARCH=rv32i
[build] core 0
[build]   20472 B / 65536 B  (5118 words)
[build] core 1
[build]   21432 B / 65536 B  (5358 words)
BUILD_OK

core 0: 1000 real ACT-ST sites -> full table (1023 slots), hot table 67 real; 50 ACT-CAP sites in sites_core0.csv
core 1: 1000 real ACT-ST sites -> full table (1023 slots), hot table 67 real; 50 ACT-CAP sites in sites_core1.csv
SITES_OK
```

**Why the programs are generated.** A hand-written critical section has about
twenty memory accesses; the table holds 1023. The point is not the number —
it is that every site is a *different* place in the program, so a finding can
say **where**, not just **that**.

**Why the instrumentation is inline assembly.** A label written next to a C
access lands wherever the compiler starts the sequence — quite possibly on an
address computation that got hoisted out of a loop. The watchpoint would then
fire once instead of once per access; nothing would fail, and the analysis
would be built on the wrong events. `RV_LD`/`RV_ST` emit the label and the
access as *one instruction*, so the mapping is exact by construction and
checkable against the disassembly.

---

## 7. Build the bitstream

**You do not have to.** The repository carries the packaged, board-verified
app under `fpga/prebuilt/tgc5b2_rvcfi/` (see the `README.md` next to it for
provenance — it is the exact build the silicon table in §16
was measured with). The fast path is one flag on the deploy:

```bash
bash board/deploy.sh --board <board-ip> --prebuilt
```

That verifies the app against its `MANIFEST.sha256` and skips both Vivado
and bootgen entirely. Build it yourself when you changed the RTL, want to
reproduce the flow, or do not want to trust a committed binary — that is
what the rest of this section documents:

```bash
cd /path/to/C-Trace
export PATH="/c/Xilinx/2026.1/Vivado/bin:$PATH"     # vivado is NOT on PATH by default
vivado -mode batch -notrace -source examples/kv260/tgc5b2_rvcfi/fpga/create_project.tcl
bash examples/kv260/tgc5b2_rvcfi/fpga/run_bits_detached.sh
```

The second step takes roughly 50 minutes. Watch
`fpga/logs/bitstream.out`, and judge it by its markers, never by the exit
code:

```
### BITSTREAM_OK: .../impl_1/tgc5b2_rvcfi_kv260_top.bit
### TIMING WNS: 2.188 ns
BITSTREAM_RC=0
```

Then run the memory gate — this one exists because the failure it catches is
completely silent:

```bash
py examples/kv260/tgc5b2_rvcfi/fpga/check_memory_kind.py \
   examples/kv260/tgc5b2_rvcfi/fpga/reports/tgc5b2_rvcfi_utilization.rpt
```

```
BRAM tiles: 105.5   URAM blocks: 48.0
MEMKIND_OK: shared memory is UltraRAM, BRAM budget untouched
```

**Read section 14.2 before you change the shared memory.** `ram_style =
"ultra"` is a request, not a contract, and when Vivado declines it says so in
one line among ten thousand.

---

## 8. Deploy and run

```bash
# stage and load the app (use whatever hardware lease your site uses first)
bash board/deploy.sh --board <board-ip>

# on the board
sudo ./rvmon status
```

**If your workstation cannot ssh to the board directly** (typical lab
layout: only a jump host's key is in the board's `authorized_keys`), run
the packaging where Vivado lives and the rest where the ssh access lives:

```bash
# on the build host (has bootgen):
py ../common/board/package_kv260_app.py \
   --bit fpga/proj/tgc5b2_rvcfi.runs/impl_1/tgc5b2_rvcfi_kv260_top.bit \
   --app tgc5b2_rvcfi --out fpga/pkg
# copy the example directory (with fpga/pkg) to the jump host, then there:
bash board/deploy.sh --board <board-ip> --skip-package
```

This is not a degraded mode — the silicon table in §16 was
produced exactly this way. The board needs `gcc`, `make` and
`device-tree-compiler` (one `apt-get install` on a fresh Kria Ubuntu
image); everything else travels with the staging directory.

With the committed prebuilt app (section 7), `--prebuilt` replaces the
packaging step everywhere — on the workstation and on the jump host alike,
since it implies `--skip-package` and needs no Vivado on either machine.

**The six verdicts as one command** (the silicon twin of
`sim/run_verdicts.sh`, staged by the deploy):

```bash
# on the board
cd /tmp/rvcfi && sudo bash run_board_verdicts.sh    # expect BOARD_VERDICTS_OK
```

`status` is the first thing to run, always, because it answers "is the right
bitstream even loaded" before anything else can mislead you:

```
magic        : 0x52564349 (ok)
shared size  : 262144 B
cores running: core0=0 core1=0
doorbell     : core0 hits=0 last=0x00000000 | core1 hits=0 last=0x00000000
act-cap conv : core0=0 core1=0
shim drops   : core0=0 core1=0
fifo occupancy: core0=0 core1=0 words
ddr ring 0   : route=fifo en=0 circ=1 base=0x50000000 size=134217728 B
               wptr=0 B drops=0 beats=0 stat=[]
ddr ring 1   : route=fifo en=0 circ=1 base=0x58000000 size=134217728 B
               wptr=0 B drops=0 beats=0 stat=[]
console      : core0 tx=0 rx_free=2048 | core1 tx=0 rx_free=2048
timestamp    : core0=NOT armed core1=NOT armed (trTsControl 8000/8000)
```

The last line is fine before a load: `rvmon load` arms both timestamp
units and reads them back (since 2026-08-27 — the first silicon run had
forgotten it and carried ts = 0 in every record).

Then a full run:

```bash
sudo ./rvmon load --mode 1 \
     --hex0 rvcfi_core0.hex --hex1 rvcfi_core1.hex \
     --wp0 wp_table_core0_full.txt --wp1 wp_table_core1_full.txt
sudo ./rvmon run --seconds 5
sudo ./rvmon analyze --in0 core0.bin --in1 core1.bin \
     --map0 sites_core0.csv --map1 sites_core1.csv --json findings.json
```

`load` refuses to touch a running core's RAM, and it verifies the watchpoint
table by reading it back — a table that loaded wrong produces
plausible-looking records for the wrong sites, which is the worst failure
this demo could have.

---

## 9. Reading the verdict

For `M0_SAFE`:

```
=== rvmon verdict ===
records analysed : 61240
VERDICT: CLEAN -- no findings
```

For `M1_RACE_OPEN`:

```
VERDICT: 3 finding(s)

[mon_lockset] data-race
  object 'balance' is written from both cores and NO lock is held
  consistently across all of its accesses (lockset empty); first core-0
  access at rv_t017, first core-1 access at rv_t042
  A: core 0 pc 0x000012C4 t=48211
  B: core 1 pc 0x00001B08 t=48213
```

And a verdict you should hope to see rather than fear, because it means the
tool refused to guess:

```
VERDICT: INCONCLUSIVE -- a shim dropped records -- the stream is incomplete
(no finding list is printed: a monitor that reports "nothing" on a stream it
cannot trust is worse than one that reports nothing at all, because the first
is believed)
```

---

## 10. Throughput — the one real operating limit

This is the part of the demo most likely to bite, so it gets its own section.

Unthrottled, each core generates roughly **490 000 records per second**
(measured on the neighbouring testbed: 142 013 270 records in 289.8 s). The
Python reader of that testbed drained **4 660 per second per core**. On a
stream that lossy, a race detector reports fiction — which is why `rvmon`
refuses a verdict when the shims dropped anything.

You have four levers, and the second one is free:

1. **A C reader instead of Python.** That is why `rvmon` is C.
2. **The table *is* the rate control.** `wp_table_*_hot.txt` loads about 67
   sites instead of 1000. Same binary, same run, a fraction of the records.
   Nothing else changes.
3. **Pacing.** `--pace N` inserts a delay loop between transactions. Set it
   from the drain rate you measured; the loop touches no memory, so it
   changes the *rate* without changing the *sequence*.
4. **A full-speed burst that fits in the buffers.** Shim 256 (+1) plus FIFO
   1024 records is about **1281 records per core** with no drops at all —
   about 2.6 ms of unthrottled execution. Stop the reader, let the cores run
   a bounded number of transactions, then drain in peace.

Both the paced continuous run and the burst are expected to show **zero
drops**. If they do not, the fix is a lever above, not a lower standard.

---

## 10a. Talking to the cores: the console

Each core has a character channel to Linux — two 2 KiB FIFOs behind three
registers at `0x4000_0100` (core side) and the CTRL bank at `0x60`/`0x70`
(PS side). It is deliberately **not** a UART: no device-tree overlay, no
`ttyUL*` whose number depends on probe order, no kernel driver — and the
whole channel is proven in simulation before any bitstream exists.

```bash
# what did core 0 print? (works while the cores are RUNNING)
sudo ./rvmon console --core 0

# send a line to core 1 and watch its output for five seconds
sudo ./rvmon console --core 1 --send "hello" --seconds 5
```

On the program side the whole "driver" is `sw/src/rv_console.h`: a blocking
`rv_putc`/`rv_puts` (the spin is uninstrumented, like every spin here) and a
non-blocking `rv_getc`. The demo programs greet with `hello core N` and echo
whatever was queued into their RX before the run — so one run demonstrates
both directions without any interactive step.

Two properties worth knowing before you rely on it:

* **Console I/O never appears in the record stream.** The registers live in
  a private segment, carry no instrumentation labels, and touch neither the
  shared memory nor the watchpointed objects. Printing costs cycles, nothing
  else — which is why the demo prints around the measured region, not
  inside it.
* **Overflow is counted, never silent.** A write into a full TX is dropped
  and counted (core-readable at `0x4000_010C`); a push into a full RX
  likewise (PS-readable at the PUSH offset). The same principle as
  everywhere else in this design: an operation that fails must not pretend
  to have worked.

## 10b. AXIS overflow: where to look when records are missing

Both AXIS paths (one per encoder) already carry full loss accounting, and it
is layered so that three different failure modes can be told apart:

| Counter | Where | Meaning |
|---|---|---|
| `shim drops` | WPCTRL `0xA040_0000` +0x04/+0x10, shown by `rvmon status` | records the shim had to drop because its FIFO was full — **the** backpressure indicator |
| `overflow sticky` | WPCTRL +0x0C/+0x18 | latched "it happened at least once", survives until reset |
| `fill level` | WPCTRL +0x08/+0x14 | current shim FIFO occupancy — watch it approach 256 |
| `doorbell hits` vs `act-cap conv` | CTRL bank 0x40/0x50 | software issued the store vs. the adapter converted it |

The counters clear only on reset; `rvmon` therefore works with before/after
deltas. And the single most important consumer of these counters is `rvmon`
itself: **any nonzero drop delta makes the verdict INCONCLUSIVE.** A race
detector on a sampled stream reports fiction, so the tool refuses rather
than guesses — if you see that verdict, go to section 10 and pick a lever.

For runs that must survive the FULL record rate without pacing, that DMA
path now exists — section 10c.

## 10c. The DDR fast lane: 2 x 128 MiB record rings

Section 10's levers all trade coverage or speed against the one bottleneck
of the FIFO path: the host drains through `/dev/mem` at roughly 28k
records/s per core, while the cores can produce records more than an order
of magnitude faster. The fast lane removes the host from the hot path
entirely: each core's record stream is written by HARDWARE into its own
ring buffer in PS DDR4, and the host reads the result afterwards at memcpy
speed.

**The shape.** The 256-MiB reserved-memory window at `0x5000_0000` (the
`resmem` overlay the deploy installs; Linux never maps it) is split into
two 128-MiB rings: core 0 at `0x5000_0000`, core 1 at `0x5800_0000`. One
`ct_soc_ddr_sink` per core writes over its own 32-bit PS HP port
(`S_AXI_HP0/HP1_FPD`) — two ports, no arbiter, and either port alone
outruns both shims combined. 128 MiB hold 8 million records per core;
at the full measured burst rate that is minutes of full-tilt capture,
not milliseconds.

**The route switch.** A mux per core sends the record words EITHER to the
MM-FIFO (`route_ddr=0`, the default — bit-identical to the pre-N3 demo) OR
to the ring sink. In ring mode the shim sees an always-ready consumer, so
the "host drains too slowly" failure mode is structurally gone: `shim
drops` stays 0 by construction, and the only loss counter that can move is
the sink's own (which at record rates never does — the simulation and the
bench treat any nonzero value as fatal). Switch the route only with the
cores stopped and after a clear pulse; a mid-record switch would tear a
record across the two consumers.

**The registers** (CTRL bank, `0x80` core 0 / `0xA0` core 1, stride 0x20):

| Offset | Register | Meaning |
|---|---|---|
| +0x00 | `RING_CTRL` (rw) | b0 en, b1 clear (W1 pulse, while disabled), b2 circ (reset 1), b3 route_ddr (reset 0) |
| +0x04 | `RING_BASE` (rw) | WARL: 32-byte aligned, inside `[0x5000_0000, 0x6000_0000)`; locked while enabled |
| +0x08 | `RING_SIZE` (rw) | WARL: multiple of 32, base+size inside the window; reset 128 MiB |
| +0x0C | `RING_WPTR` (ro) | TOTAL bytes written, monotonic — ring offset is `wptr % size` |
| +0x10 | `RING_STAT` (ro) | b0 full (one-shot), b1 axi_err, b2 wrapped, b3 cfg_rej (sticky) |
| +0x14 | `RING_DROPS` (ro) | sink-side drops, saturating — never expected at record rates |
| +0x18 | `RING_BEATS` (ro) | words offered while enabled — the proof the feed reaches the sink |

The WARL window is not pedantry: an AXI write outside the reservation on
`S_AXI_HP` does not return an error on this PS — it wedges the
interconnect until the power switch (measured on this very board family).
The hardware therefore refuses to aim outside the window, and a rejected
configuration write sets the sticky `cfg_rej` bit instead of half-taking
effect.

**Using it** is one flag on the run (the order contract — stop, route,
clear, enable, run, read back — is `rvmon`'s job, not yours):

```bash
sudo ./rvmon run --mode 1 --route ddr --iters 100000
```

`rvmon` reads the rings back through `/dev/mem` after quiescence, stitches
the wrap seam if the ring lapped, feeds the SAME analyser, and judges the
run by the ring counters (`wptr`, drops delta, `axi_err`, `cfg_rej`) plus
the shim counters that must now be zero. The record files and every
verdict are indistinguishable from a FIFO-path run — the simulation
enforces that literally: the `ddr` leg of the e2e bench requires the ring
capture to match the AXIS reference word for word.

The legacy ATB observer that used to own this window (sink window
`0x18..0x38`) is compiled away in this design (`EN_DDR=0`); its DDR fields
read zero, and the ATB stream keeps its always-ready URAM ring.

## 11. Extending it

### Add an instrumented site

In a transaction function, use the macro with a fresh site id:

```c
RV_LD(v, &SH->balance, 1234);      /* one labelled load  */
RV_ST(&SH->count, c + 1u, 1235);   /* one labelled store */
```

Then add the site to the manifest in `gen_program.py` so it gets a tag, and
re-run the three commands from section 6. `gen_sites.py` fails loudly if a
label is missing from the binary or if two labels land on one instruction.

### Add a monitor

Write a function of this shape and put it in the table at the bottom of
`board/rvmon/monitors.c`:

```c
static void mon_mine(const rv_rec_t *r, size_t n,
                     const rv_sitemap_t *map, rv_findings_t *out);
```

You get the merged, time-ordered stream of both cores. Develop it against
`rvmon selftest` on your workstation; go to the board when it works.

### Instrument a dynamic address

A watchpoint reports the site, not the address, and the *address* of a ring
slot depends on `head`. Two ways:

* **ACT-CAP with a computed tag** (what the demo does): store the index into
  the tag at run time. One instruction, and the value is exactly what you
  chose to put there.
* **The `DAQ_DADDR` pairing**: a watchpoint with `DAQ_DADDR` gives the real
  address but **no timestamp**, so pair it with a following `DAQ_PC_CURR`
  site for the time. Two slots and two records per access.

---

## 12. What the trace does *not* contain

Being explicit about this is what keeps the analysis honest:

* **The lock spin loop is not instrumented.** It hits the same two addresses
  as fast as the core can issue; under contention it would drown everything
  else — precisely in the situation that matters.
* **Stack traffic and the IRQ path are not instrumented.** Only labelled
  sites are reported.
* **Only what the table holds.** With the `hot` table you see about 67 sites,
  not 1000. That is a deliberate trade, and `rvmon` tells you which table was
  loaded so a finding is never read against the wrong expectation.
* **The ring buffer is a control, not a target.** It is
  single-producer/single-consumer and correct by construction. If a monitor
  ever reports a race there, the monitor is wrong — and the demo would rather
  find that out here than in front of a customer.

---

## 13. Give the board back

```bash
bash board/deploy.sh --board <board-ip> --restore
```

This unloads the app, restarts the dashboard service and lists what is
installed. It does not reload the previous app; that is
`xmutil loadapp <name>` by hand.

---

## 14. When it goes wrong

### 14.1 `rvmon status` says the magic is wrong

```
rvmon: CTRL magic is 0x00000000, expected 0x52564349 ("RVCI")
```

The wrong bitstream is loaded, or none. `xmutil listapps` on the board.
Do **not** interpret `fpga_manager` state as proof — it reports `operating`
even with no app loaded.

### 14.2 The shared memory silently became block RAM

Symptom: the implementation dies about an hour in with

```
[DRC UTLZ-1] RAMB18 and RAMB36/FIFO over-utilized ... requires 290 of such
cell types but only 288 compatible sites are available
```

Cause: `ram_style = "ultra"` was ignored. Vivado says so, once:

```
[Synth 8-12186] The ram_style = "ultra" ... is ignored because invalid write mode
[Synth 8-7217]  RAM identified as Multi-port RAM (2 WRite and 2 Read)
```

Two different mistakes produce this, and both were made here:

* **Separate read and write processes per port.** Vivado then builds a
  multi-port *emulation* (the array replicated per read port), which cannot
  be URAM. The canonical template is one process per port with one address,
  doing the write and the read together.
* **Byte-write enables.** URAM inference rejects a byte-enabled write
  template outright. The shared memory therefore writes whole words and
  answers a partial strobe with SLVERR.

Do not debug this with a full build. Use the probe:

```bash
vivado -mode batch -notrace -source examples/kv260/tgc5b2_rvcfi/fpga/probe_shared_mem.tcl
### PROBE_URAM: 16
### PROBE_BRAM: 0
### PROBE_OK: UltraRAM
```

One minute per hypothesis instead of one hour.

### 14.3 `vivado: command not found` — with exit code 0

`vivado` is not on `PATH` on a default Windows install, and if you pipe the
call into `tail` the shell reports the *pipe's* status. Export the path
explicitly and judge the run by `BITSTREAM_OK`, never by `$?`.

### 14.4 A core hangs when you load its RAM

An access to a **running** core's RAM window never gets ready and the AXI
transaction hangs. Stop both cores first (`CONTROL = 0`). `rvmon load`
enforces this; `devmem` by hand does not.

### 14.5 Timestamps look wrong

The timestamp is 32 bits and wraps after about **57 s at 75 MHz** — and after
about 43 s if `pl_clk0` came back at 100 MHz after a power cycle, which it
does. Set the clock explicitly (`--pl-mhz 75`) and let `rvmon` unroll the
wrap; it checks the clock before converting anything to seconds.

If every timestamp is **zero**, the units were never armed: `rvmon load`
does it (`trTsControl` = `0x8033`) and `rvmon status` must say `armed`. By
hand: `sudo busybox devmem 0xA0010040 32 0x8033` and the same at
`0xA0020040`.

### 14.6 `rvmon` reports INCONCLUSIVE

Read the reason it prints. The common one is dropped records: see section 10.
A refused verdict is the tool working, not the tool failing.

### 14.7 ACT-CAP records are missing

Three counters, taken at three different points on the same path, tell three
different stories apart. Read them with `rvmon status`:

* `doorbell hits` — software issued the store
* `act-cap conv` — the adapter turned it into an ACT-CAP beat
* `shim drops` — the record was lost afterwards

If hits rose and conversions did not, the doorbell address is wrong. If both
rose and records are missing, they were dropped downstream.

---

## 15. Provenance of the numbers in this tutorial

| Figure | Where it comes from |
|---|---|
| 490 000 records/s generated, 4 660/s drained by Python | the neighbouring `tgc5b2_axis_wp` testbed's completion report |
| 1281 loss-free records per core | shim FIFO 256 (+1 holding) + `axi_fifo_mm_s` 4096 words / 4 |
| WNS +2.188 ns, LUT 52.67 %, BRAM 105.5, URAM 48 | this design's own `fpga/reports/`, build of 2026-08-24 |
| 16 URAM / 0 BRAM for the shared memory | `fpga/probe_shared_mem.tcl`, measured per variant |
| 20 472 / 21 432 B program images | `sw/build.sh` output |

Numbers that are **not** measured are not in this tutorial. Where a step has
not yet been run end to end on hardware, the accompanying report says so
explicitly rather than implying otherwise.

---

## 16. Status: what is measured

**Status, 2026-08-26.** Everything in this tutorial is built and **measured twice: in simulation and on
KV260 silicon**, the N3 build included (its silicon run happened on a
second, differently provisioned KV260 — which is its own data point: the
prebuilt fast path deployed there from zero). Concretely:

| Step | State |
|---|---|
| §5 `rvmon selftest` | **verified** — `SELFTEST_PASS` (host, and on both boards' own builds) |
| §6 build programs + tables | **verified** — `GEN_OK`, `BUILD_OK`, `SITES_OK` (1004 ACT-ST + 50 ACT-CAP sites/core) |
| §7 bitstream + memory gate | **verified** — N3 build: `BITSTREAM_OK`, WNS **+1.550 ns**, `MEMKIND_OK` (the pre-N3 build closed at +2.217 ns; the two extra AXI masters cost slack, not correctness) |
| §8 board run | **verified on silicon, both builds and both transports** — `deploy.sh` end to end (`--prebuilt` on the second board: manifest check, 75 MHz with readback, md5, MAGIC ok), `run_board_verdicts.sh` twin table says `BOARD_VERDICTS_OK` over 12 legs |
| §9 the six verdicts | **measured in simulation AND on silicon** — FIFO and DDR silicon tables are identical, leg for leg |
| §10a console | **verified in simulation and live on both boards** — greeting + echo, both directions |
| §10b loss accounting | **exercised on silicon** — a full-tilt FIFO run (2000 iterations, pace 200) reported 59805/64982 dropped records and refused the verdict; the paced legs report 0/0 |
| §10c DDR fast lane | **verified in simulation AND on silicon** — the exact run the FIFO path lost 59805/64982 records on is loss-free through the rings (`RUN_OK`, drops 0/0), and a full-tilt run of ~1.14 million records per core (100000 iterations, pace 0) also finished `RUN_OK` with ring drops 0/0 — no pacing, no levers |

Simulation (60 iterations/core, 0 drops everywhere, every claim checked
mechanically by `sim/run_verdicts.sh` — since N3 seven legs, `VERDICTS_OK`):

```
mode   ok   verdict                        [monitors that fired]
m0     ok   CLEAN -- no findings           [none]
m1     ok   13 finding(s)                  [mon_hb+mon_lockset+mon_proto]
m2     ok   11 finding(s)                  [mon_hb+mon_lockset]
m3     ok   1 finding(s)                   [mon_order]
m4     ok   2 finding(s)                   [mon_cfg]
cap    ok   CLEAN -- no findings           [none]
ddr    ok   CLEAN -- no findings           [none]
VERDICTS_OK
```

Silicon (KV260, same 60 iterations/core, judged by the same claim table
via `board/run_board_verdicts.sh`, drop DELTA 0/0 in every leg — first
measured with the pre-N3 build; the N3 build then reproduced the SAME
table twice on a second board, once per transport, `BOARD_VERDICTS_OK`
over all 12 legs):

```
mode   ok   verdict                        [monitors that fired]
m0     ok   CLEAN -- no findings           [none]
m1     ok   10 finding(s)                  [mon_hb+mon_lockset+mon_proto]
m2     ok   8 finding(s)                   [mon_hb+mon_lockset]
m3     ok   1 finding(s)                   [mon_order]
m4     ok   2 finding(s)                   [mon_cfg]
cap    ok   CLEAN -- no findings           [none]
BOARD_VERDICTS_OK
```

Note what the tables show beyond "findings exist": each defect class is
found by exactly the monitor built for it — m2 only via the runtime
(ACT-CAP) lock tags, m3 as a single order-graph finding with no noise,
m4 as exactly one CFI hit per core. The structurally deterministic legs
(m0, m3, m4, cap) agree exactly between simulation and silicon, and the
record counts per leg match to the record (684/696 for m0). The RACE
counts differ (13/11 simulated vs 10/8 on silicon) and that is the
defect class talking, not the tooling: how many of the planted race
windows actually collide depends on platform timing. On the board the
counts are stable — three m1 runs in a row gave the same 10 findings
(5 unordered-conflict + 3 data-race + 2 access-without-lock).

2026-08-27: the companion handover was walked end to end on a KV260,
first with the pre-N3 app (deploy, the six FIFO verdict legs, its
own-program example, malloc), then with the N3 app (deploy `--prebuilt`,
all 12 legs `BOARD_VERDICTS_OK`, the own-program example on both
routes); its closing status section says what that covered.
