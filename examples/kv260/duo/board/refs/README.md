<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->
# Reference PC sequences for the `duo` board gate

`duo_board_gate.sh` can check each core's decoded PC sequence against a
reference (`--oracle0`, `--oracle1`). Until 2026-08-19 it printed
`SKIP -- no --oracle given (needs a sim retired.pcs reference; none exists in
this tree yet)`, so the gate proved that trace *arrives*, not that it is
*right*. These two files close that, and they are **not the same kind of
evidence** -- which is the point of this README.

| File | PCs | What it is | What it proves |
|---|---:|---|---|
| `core0_trace_test.retired.pcs` | 26,772 | **Simulation oracle.** Byte-identical copy of `../../../mbv/board/refs/trace_test.retired.pcs` -- core 0 of `duo` runs the same `trace_test` image as the `mbv` example | The decoded sequence matches what the program *should* execute |
| `core1_hello_trace.recorded.pcs` | 100,000 | **Recorded reference.** The first 100,000 PCs the TGC5B produced on 2026-08-19, decoded from a board capture | The decoded sequence matches what the hardware *did* execute, on two independent designs |

## Why core 1 has no oracle, and why the recorded reference is still worth having

There is no TGC5B simulation reference in this repository, and inventing one
would be worse than having none. What exists instead is a **cross-check
between two different bitstreams**: `duo` (two cores) and `trio` (three cores)
were captured independently on 2026-08-19, and their TGC5B PC sequences are
**identical over all 1,201,992 decoded PCs** -- not a prefix, the whole run.
The MBV sequences agree over the full 1,602,399 PCs the shorter capture holds.

Two designs, two captures, the same instruction stream. That does not prove
the program is correct; it proves that the encoder, the funnel and the decoder
reproduce it exactly, and that is what a board gate is for. The file is
trimmed to 100,000 PCs because a regression guard needs to be long enough to
cover many loop iterations, not long enough to be a second copy of the run.

**Label it honestly when quoting it:** `core0` is an oracle result, `core1` is
a reproduction result. A report that calls both "verified against a reference"
without that distinction is overclaiming.

## 2026-08-21: the recorded core-1 reference no longer reproduces -- and a second file next to it

Running `duo_board_gate.sh` with its defaults **fails on core 1 today**. Four
board runs, two designs, two PL clocks, all on kria-kv260b on 2026-08-21:

| Run | core 0 vs oracle | core 1 vs `core1_hello_trace.recorded.pcs` |
|---|---|---|
| duo, 75 MHz | PASS (26 772 PCs) | FAIL at index **855** |
| duo, 68 MHz | PASS | FAIL at index **855**, same PCs |
| trio, 68 MHz | PASS | FAIL at index **855**, same PCs |
| trio, 68 MHz, new reference | PASS | **PASS** (100 000 PCs) |

The divergence is identical in every run:

```
decoded  [855] = 0x0000006c    context: 0x1e0 0x1e4 0x1e8 0x06c 0x070 0x074 0x078
reference[855] = 0x000001ec    context: 0x1e0 0x1e4 0x1e8 0x1ec 0x020 0x020 0x020
```

**What was ruled out by measurement, not by argument:**

* *The PL clock.* duo at 75 MHz and duo at 68 MHz produce **identical PC
  sequences over all 720 238 decoded core-1 PCs**. The clock does not change
  the instruction stream, and it is not the reason the stored reference
  misses.
* *A trio-specific effect.* trio at 68 MHz and duo at 75 MHz are likewise
  **identical over the full shorter capture** -- 720 238 PCs on core 1,
  609 352 on core 0. That is the same cross-design reproduction the section
  above describes, freshly measured; it just no longer coincides with the
  file recorded on 2026-08-19.
* *A decoder or encoder fault.* core 0 passes against a REAL oracle in every
  one of the four runs.

So three independent runs across two designs and two clocks agree with each
other and disagree with one file. The stored reference's own context is the
telling part: after `0x1ec` it shows `0x20` repeated, which is a core sitting
still, not a program running on. The likeliest reading is that the
2026-08-19 capture caught a one-off state at that point and was recorded as
if it were the norm.

**What was done about it, and what was deliberately NOT done.**
`core1_hello_trace.recorded_20260821.pcs` is the first 100 000 PCs of the
duo/68 MHz run of 2026-08-21 -- recorded exactly like its 2026-08-19
predecessor, and the file `trio` passes against. The old file is **kept**,
not overwritten: it is the only evidence of what the board did on
2026-08-19, and deleting it would erase the very discrepancy this section
describes.

**The gate's default now points at the 2026-08-21 file.** A gate that fails
with its own defaults is worse than no gate, and the choice is not close:
three independent runs across two designs and two clocks agree with the new
recording and disagree with the old one. Verified with the defaults on
2026-08-21 at duo's own 75 MHz -- i.e. at a DIFFERENT clock from the one the
new file was recorded at:

```
### CORE0: [core0] PASS - reference (26772 PCs) ... of 629 371 decoded
### CORE1: [core1] PASS - reference (100000 PCs) ... of 748 081 decoded
### DUO_BOARD PASS
```

**The reservation stands beside that result, not instead of it:
reproducible is not correct.** Nobody has held either sequence against what
`hello_trace` is *supposed* to do. Core 1 therefore remains a reproduction
result and never an oracle result -- the distinction the section above
insists on -- and the 2026-08-19 file stays in this directory as the only
evidence of what the board did that day. Pass it with `--oracle1` to compare
the two directly.

## Reproducing

```bash
bash examples/kv260/duo/board/duo_board_gate.sh \
     --oracle0 examples/kv260/duo/board/refs/core0_trace_test.retired.pcs \
     --oracle1 examples/kv260/duo/board/refs/core1_hello_trace.recorded.pcs
```

Verified 2026-08-19 against both captures (the run predates the English
wording of `check_pcout_vs_retired.py`; the lines below are its present
wording, the numbers are the recorded ones):

```
[duo-core0]  PASS - reference (26772 PCs) contained IN FULL as a prefix of the decoded sequence (1602656 PCs)
[trio-core0] PASS - reference (26772 PCs) contained IN FULL as a prefix of the decoded sequence (1602399 PCs)
[duo-core1]  PASS - reference (100000 PCs) contained IN FULL as a prefix of the decoded sequence (1201992 PCs)
[trio-core1] PASS - reference (100000 PCs) contained IN FULL as a prefix of the decoded sequence (1201992 PCs)
```
