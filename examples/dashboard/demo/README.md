<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->
# The hardware-free demo dataset

Every file here is a **recording**, not a construction. The dashboard replays
them when no board is attached, and `insight.py` decodes them with the same
CTTD build the board uses -- so the numbers a visitor sees in demo mode are
the numbers the hardware produced.

## Where each dataset comes from

Recorded 2026-08-19 on a Kria KV260, PL clock **68.181818 MHz** (the only
label at or below the 71.114 MHz sign-off constraint that every design in
this repository is routed against -- see `../plclk.json`). The guest images
are the OpenSBI+Linux payloads built from the RV64 Buildroot output; the
`.pcinfo` listings are generated from **those same images**, not from a
similar build.

| Scenario | Trace | Listing | Console | Instructions decoded | Decode errors |
|---|---|---|---|---:|---:|
| `cva6_linux` | `demo_trace_cva6_linux.bin` | `cva6_linux.pcinfo` | `console_cva6_linux.txt` | 1,218,940 | 0 |
| `rocket2` | `demo_trace_rocket2.bin` | `rocket2.pcinfo` | `console_rocket2.txt` | 1,708,826 | 0 |
| `rocket64` | `demo_trace_rocket64.bin` | `rocket64.pcinfo` | `console_rocket64.txt` | 278,672 | 0 |
| `cva6_linux64` | `demo_trace_cva6_linux64.bin` | `cva6_linux64.pcinfo` | `console_cva6_linux64.txt` | 276,138 | 0 |
| `cva6_2_rv64` | `demo_trace_cva6_2_rv64.bin` | `cva6_linux64.pcinfo` | -- | 446,774 | 0 |
| `trio` | `demo_trace_trio.bin` | `mbv.pcinfo` + `tgc.pcinfo` | -- | 2,804,391 (MBV 1,602,399 + TGC5B 1,201,992) | 0 |
| `duo` | `demo_trace_duo.bin` | `mbv.pcinfo` + `tgc.pcinfo` | -- | 2,804,648 (MBV 1,602,656 + TGC5B 1,201,992) | 0 |

File sizes and checksums (sha256, first 16 hex digits):

| File | Bytes | sha256 |
|---|---:|---|
| `cva6_linux64.pcinfo` | 773,634 | `0e99e553e9952e8c...` |
| `demo_trace_cva6_2_rv64.bin` | 66,720 | `09cf0b4ff7b620fa...` |
| `demo_trace_cva6_linux64.bin` | 262,144 | `6cfd16a63e66a080...` |
| `demo_trace_rocket2.bin` | 262,144 | `b0e30c3edf778a05...` |
| `demo_trace_rocket64.bin` | 262,144 | `d239cc277b482a40...` |
| `rocket2.pcinfo` | 870,367 | `3727772eb187cacb...` |
| `rocket64.pcinfo` | 863,550 | `b274f504297f16af...` |

## How to reproduce a dataset

1. Build the guest image on a Linux build host -- `examples/kv260/cva6_linux64/sw/build_payload_rv64.sh`
   for the CVA6 RV64 guest, `examples/kv260/rocket2/sw/build_payload_rocket2_rv64.sh`
   for the two-hart Rocket, `examples/kv260/cva6_2/sw/build_payload_cva6_2.sh`
   for the AMP pair.
2. Stage the payload on the board and run the board recipe under
   `../boot/` with `PHASE=prep`, then `PHASE=start`, then `PHASE=trace`
   and `PHASE=con`. The recipes verify the payload by reading it back and
   comparing checksums; they refuse to start when `pl_clk0` is wrong.
3. Build the listing from the **same** `fw_payload.elf`:
   `objdump -d --start-address=<load address> --stop-address=<payload_bin>`,
   then `cttd -conv -objd <listing> -pcinfo <out>`. For the Rocket designs
   prepend a disassembly of the boot ROM at `0x1_0000` -- the capture starts
   there, not in OpenSBI.
4. Verify before committing: `cttd -deco <trace> -pcinfo <listing> -pcout /dev/null -stat`
   must report **0 error messages**.

## What these recordings do and do not show

* **`rocket2`** is the boot from reset of the two-hart Rocket. The URAM ring
  is a 1 MiB one-shot, and it fills during hart 0's pre-SMP phase -- so the
  capture carries **SRC 0 only**. Hart 1 has not been released by the SMP
  bring-up at that point. That is the ordering of an SMP boot, not a gap in
  the funnel; the console capture reaches `smp: Brought up 1 node, 2 CPUs`
  because the console ring keeps running after the trace ring is full.
* **`cva6_2_rv64`** shows something the console cannot: the AMP guest emits
  **no console output at all**, and the trace still carries 446,774 decoded
  instructions of core 0 -- `_try_lottery` through `generic_early_init` into
  OpenSBI's device-tree scan, with 257,516 instructions in `fdt_offset_ptr`
  alone. The core-0 PC register reads `sbi_hart_hang` afterwards, and core 1
  retires 14 instructions and stops. **The bring-up of the AMP guests is an
  open item**; what the window shows is where execution was when the ring
  filled, which is not the same as where it stopped. The dataset is included
  because it is a real capture and because this is precisely the situation a
  trace is for -- a target that dies silently.
* **`rocket64`** and **`cva6_linux64`** boot Linux; their consoles run from
  the OpenSBI banner into the kernel's I/O scheduler registration.

### Why `trio` and `duo` were re-recorded

Their previous streams could not be split by source. The live path never
programmed the encoders' `SrcBits`/`SrcID` fields and never cleared
`InhibitSrc` -- and the RDL reset of `trTeControl` has that bit **set**, i.e.
SRC off. A multi-source capture taken from the dashboard therefore carried no
SRC field at all. It decoded cleanly -- 49,135 messages, zero errors -- and
attributed **zero** instructions to either target, because there was nothing
to attribute by. The demo bus had been faking the correct register values all
along, so the UI showed "SRC on" while the hardware had it off: the mock was
more correct than the machine.

Fixed 2026-08-19 in `trace_on` (the same `Enable = 0` window the sync fields
are written in, because both are swwel-locked). The capture above is from
after that change: `FEAT0 = 0x20000000`, `FEAT1 = 0x20010000`,
`FEAT2 = 0x20020000`, `trTeControl` bit 15 clear -- the values the board
runners program. The previous `duo` recording (`demo_trace.bin`, kept as the
fallback stream) decodes 35,341 instructions; the new one 2,804,648.

### The one dataset that predated this round

`cva6_linux` was the only demo capture in the repository before 2026-08-19,
and it was the only one that did **not** decode cleanly: it stopped after
53,075 PCs with `ERROR EmitICNT with n=34`. Nothing flagged that, because the
only check in place asked whether the files exist. It was re-recorded with the
rest -- 1,218,940 instructions, zero errors -- and `../test_demo_decode.py`
now runs the decoder over every shipped capture on every CI run, so a capture
and its listing cannot drift apart unnoticed again.

## Program images

`trace_test.elf` and `hello_trace.hex` are the guest programs the bare-metal
scenarios stage into their cores' RAM windows (`preload` in
`../scenarios.json`). They live **here**, not in the example directories they
were built in, for one reason: the board rollout copies this directory and
nothing else. A `preload` path pointing outside it resolves into nothing on
the board, and the failure is silent -- the cores then run whatever the
fabric powered up with. Measured 2026-08-19: `hello_trace.hex` sat outside
and a `trio` run produced **40 bytes** of trace instead of 7,475,444.
`../test_demo_assets.py` fails on any `preload` path that leaves this tree.

Source of record: `hello_trace.hex` is a copy of
`../../kv260/common/tgc5b/prog/hello_trace.hex`, `trace_test.elf` of the MicroBlaze V
example's `sw/build/trace_test.elf`.

## Raw material

`raw/` holds the untouched console ring dumps. `../make_demo_console.py`
derives the `.txt` files from them, removing capture artefacts only (paired
duplicate lines from earlycon and console writing to the same UART, trailing
NUL padding from the ring). Keeping the raw dumps in the repository is what
makes that script reproducible -- its earlier sources pointed into build
trees that do not exist here.
