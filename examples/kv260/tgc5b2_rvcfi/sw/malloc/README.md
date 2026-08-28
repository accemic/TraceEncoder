<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# malloc on a bare-metal TGC5B, watched through ACT-CAP

A newlib `malloc` running on the two TGC5B cores of the
[rvcfi](../../TUTORIAL_runtime_verification.md) design, with every
allocation reported through the encoder's ACT-CAP path: the allocation
**id**, the **requested size**, the **pointer that came back**, the
**caller**, and every time the heap **grows**. Nothing in the SoC changes --
same bitstream, same doorbell, same shim and FIFO, same `rvmon` to load and
drain. What changes is the program: it links a C library and gives it a heap.

## What it shows

Watchpoints (ACT-ST) report *where* a program was; their tag is fixed when the
table is loaded. A heap pointer is the opposite kind of fact -- nobody knows it
before the program runs -- and that is what ACT-CAP is for: one store to the
doorbell per field, each landing as one timestamped 96-bit record. Decoded
from the simulation (`decode_malloc.py`), core 0:

```
#    event     id   size      ptr caller          t[us] dur[us]  heap
1    malloc     1     24   0x0e50 main+0x13c       0.00    6.00  brk->0xe6c
2    malloc     2    100   0x0e70 main+0x158      20.08    4.43  brk->0xed8
3    malloc     3    512   0x0ee0 main+0x178      42.72    4.53  brk->0x10e0
4    free       2          0x0e70 main+0x198      65.89    0.88
5    malloc     4     64   0x0e98 main+0x1a0      68.67    3.04            <- first fit: the freed 100-byte hole
6    malloc     5   4096   0x10e8 main+0x1c0      89.92    4.80  brk->0x20e8
...
26   free       5          0x10e8 main+0x240     363.45    0.88
27   malloc    14   2000   0x1c18 main+0x248     366.76    3.04            <- coalesced: no sbrk needed
28   free      14          0x1c18 main+0x268     387.96    0.88
29   malloc    15  60000     NULL main+0x270     391.09    4.35            <- beyond the heap limit, refused
records: 115  events: 29  final break: 0x23e8  heap used at peak: 5532 B  still live: 0
MALLOC_DEMO_OK
```

Every line is reconstructed from records alone -- the program never prints
it. The `heap` column is newlib asking for memory *inside* a `malloc`
(`_sbrk` is instrumented too), so you can see which requests grew the heap
and which were served from freed space.

## Measured on silicon (KV260, 2026-08-26)

Bitstream built here with Vivado 2024.2 (the tutorial says 2026.1; this one
closed at WNS +2.033 ns, `MEMKIND_OK`, BRAM 107.5 / URAM 48), deployed with
the tutorial's `deploy.sh`, `pl_clk0` = 75 MHz, MAGIC verified. Then:

```
core0 done=0E0DDA7A iters=1 sum=80104 | core1 done=0E0DDA7A iters=1 sum=81016
records: core0=115 core1=115 in 0.44 s          shim drops: core0=0 core1=0 (clean)
doorbell     : core0 hits=115 | core1 hits=115     act-cap conv : core0=115 core1=115
console core0: hello core 0 / malloc demo: 15 allocations, 115 ACT-CAP records, heap top 0x000023e8
decode: 29 events, final break 0x23e8, heap used at peak 5532 B, still live 0 -> MALLOC_DEMO_OK  (core1: 0x2428, 5596 B, OK)
```

Record for record the same stream as the simulation: same pointers, same
breaks, same NULL for the 60 000-byte request; the console line and the
decoder agree on 15 allocations and 115 records; hits = conversions =
records, so nothing was dropped anywhere on the path.

**Timestamps.** The bench arms the encoders' timestamp unit itself
(`trTsControl` = `0x8033`: Active, Count, Type = the shared fabric counter,
Enable). On the board nothing did, so the first silicon run carried
timestamp 0 in every record. Since 2026-08-27 `rvmon load` arms both
encoders with the same value and reads it back, and `rvmon status` shows
`timestamp : core0=armed core1=armed`. Only if you start the cores without
`rvmon load` do you arm them by hand:

```bash
sudo busybox devmem 0xA0010040 32 0x8033    # ENC0 trTsControl
sudo busybox devmem 0xA0020040 32 0x8033    # ENC1 trTsControl
```

## How it works

* `src/malloc_demo.c` -- the program. Newlib (nano) `malloc`/`free`, a heap
  from `_end` up to `0xD000` (below rvcfi's scratch page and the stack),
  `_sbrk()` as the one system call newlib needs, and two wrappers
  (`md_malloc`, `md_free`) that issue the ACT-CAP beats. The same
  host protocol as the rvcfi programs (magic, `go` barrier, result mailbox,
  console greeting), so `rvmon` and the e2e bench work unchanged.
* `src/md_cap.h` -- the tag. `DAQ_PC_CURR` beats only (the one command that
  carries a timestamp); inside rv_tags.h's 21-bit VALUE payload,
  `[20:18]` says which field and `[17:0]` carries it:

  | field | value |
  |---|---|
  | `MALLOC` | allocation id (a malloc begins) |
  | `SIZE` | requested bytes |
  | `SBRK` | new program break (issued from inside `_sbrk`) |
  | `PTR` | the pointer returned (0 = NULL) |
  | `CALLER` | return address into the caller |
  | `FREE` / `FREE_PTR` / `FREE_CALLER` | the same for `free` |

  Four records per `malloc`, three per `free`, one per heap growth.
* `decode_malloc.py` -- turns a record dump into the table above and
  **judges** it: pointers 8-byte aligned and inside the heap window, no two
  live blocks overlap, every `free` names a live block, the break only grows
  and only while a `malloc` is in flight. Prints `MALLOC_DEMO_OK` or the
  list of violations.
* `build.sh` -- builds both cores (`-specs=nano.specs -specs=nosys.specs`,
  3.4 KiB image) and writes `wp_table_none.txt`, a watchpoint table of 1023
  padding slots, because `rvmon load` insists on a full table and this demo
  has no ACT-ST sites. Unlike the rvcfi programs, the images are **not
  committed**: they contain newlib, and a binary of mixed provenance is not
  something this repository ships -- run `build.sh` first (it needs
  `riscv32-unknown-elf-gcc`, or `riscv64-` with the rv32 multilib).

## Run it

Simulation (Verilator through `abc`, no hardware; the leg is
`sim/tb_rvcfi_e2e_malloc.abc`):

```bash
cd examples/kv260/tgc5b2_rvcfi/sw/malloc && bash build.sh      # needs riscv32-unknown-elf-gcc
cd /path/to/TraceEncoder
(. ./scripts/ct_env.sh && ct_need_abc && cd bld && abc -sim ../examples/kv260/tgc5b2_rvcfi/sim/tb_rvcfi_e2e_malloc.abc) | grep -E 'TB_PASS|%Fatal'
python3 examples/kv260/tgc5b2_rvcfi/sw/malloc/decode_malloc.py bld/tb_rvcfi_e2e_malloc.vsim/rvcfi_e2e_malloc_core0.hex \
        --sym examples/kv260/tgc5b2_rvcfi/sw/malloc/malloc_core0.sym
```

Expected: `TB_PASS (tb_rvcfi_e2e MODE=0): records core0=115 core1=115 drops=0/0`
and `MALLOC_DEMO_OK`.

Board (the rvcfi app deployed as in the tutorial, §8; then stage this
directory next to `rvmon`):

```bash
scp malloc_core0.hex malloc_core1.hex wp_table_none.txt decode_malloc.py malloc_core0.sym <board>:/tmp/rvcfi/
# on the board, in /tmp/rvcfi (rvmon load arms the timestamp units)
sudo ./rvmon load --hex0 malloc_core0.hex --hex1 malloc_core1.hex --wp0 wp_table_none.txt --wp1 wp_table_none.txt --mode 0
sudo ./rvmon run --seconds 3 --iters 1
python3 decode_malloc.py core0.bin --sym malloc_core0.sym --mhz 75
```

`rvmon run` reports the doorbell/conversion/drop counters; the decoder's
`MALLOC_DEMO_OK` is the verdict. `--iters N` (up to 8) repeats the
allocation script.

## Two things learned building it

* **A record-free stretch is read as "finished".** The e2e bench and `rvmon
  run` both stop the cores when no record has arrived for a while (16 000
  cycles in the bench). The first version of this demo filled every
  allocated block byte by byte; a 4 KiB block is ~90 000 silent cycles on
  this dBus (about ten cycles per byte access), the bench stopped the cores
  mid-loop and reported a hang that was not one. `sim/tb_rvcfi_e2e_malloc_dbg.sv`
  is the diagnostic leg that showed the PCs moving; the program now touches
  only the ends of a block.
* **`rvmon load` wants a full table.** The encoder's watchpoint search tree
  is a perfect binary tree over 1023 slots with strictly ascending unique
  keys; an "empty" table is 1023 odd addresses above the RAM, not 1023
  zeros -- see `gen_sites.py`'s programming rules.
