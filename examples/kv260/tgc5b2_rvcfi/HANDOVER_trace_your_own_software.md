<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Handover — trace your own software on the TGC5B demo (KV260)

This document is for one reader. You have your own KV260. You want to run
your own RISC-V program on the demo's two TGC5B cores and trace it with
hardware watchpoints. It goes step by step and stays operational. The
demo's own story (what the five modes plant, and which monitor catches
which) is the [tutorial](TUTORIAL_runtime_verification.md)'s job; this
document links into it where depth helps.

## The red thread

1. Know the setup ([§1](#1-the-setup)). Get what you need
   ([§2](#2-what-you-need)). Find the code ([§3](#3-where-the-code-is)).
2. Put the demo app on your board ([§4](#4-put-the-demo-app-on-your-board)).
3. Meet `rvmon`, the tool that drives everything ([§5](#5-rvmon-in-one-page)).
4. Run the demo once ([§6](#6-run-the-demo-once)). If it passes, your board
   and your tools are fine.
5. Talk to a program on a core ([§7](#7-talk-to-a-program-on-a-core)).
6. Build your own program ([§8](#8-build-your-own-program)).
7. Set watchpoints on your functions
   ([§9](#9-set-watchpoints-on-your-functions-act-st)).
8. Load, trace, capture ([§10](#10-load-trace-capture)). Read the records
   ([§11](#11-read-the-records)).
9. malloc ([§12](#12-is-malloc-working-yes)), limits ([§13](#13-limits)),
   registers ([§14](#14-register-definitions-on-the-pl-side)), when it goes
   wrong ([§15](#15-when-something-goes-wrong)).

---

## 1. The setup

Two RISC-V cores, each with its own trace encoder (CTTE), share one
memory. Linux on the PS side reads the records.

```
TGC5B-0 --retire--> CTTE0 --ACT-ST (1023 slots)--> shim0 --> FIFO0 --+
   |                                                      0xA041_0000  |
   +-- port A --+                                                      +--> rvmon
                +-- shared memory, 256 KiB UltraRAM                    |    (PS Linux)
   +-- port B --+                                                      |
   |                                                      0xA042_0000  |
TGC5B-1 --retire--> CTTE1 --ACT-ST (1023 slots)--> shim1 --> FIFO1 --+
                                     |
                        one shared fabric counter -> timestamp in BOTH encoders
```

| Item | What you have |
|---|---|
| Cores | 2 × TGC5B, RV32I. No atomics, no compressed instructions. 75 MHz (`pl_clk0`). |
| Private RAM per core | 64 KiB for code and data, from address 0. The stack starts at `0xF000` and grows down. The demo image uses about 21 KiB. |
| Shared memory | 256 KiB UltraRAM. Core address `0x3000_0000`, same view from both cores. PS address `0xA004_0000`, readable only while both cores are stopped. No reset value: it keeps what the last run wrote. |
| Watchpoints (ACT-ST) | 1023 slots per encoder. A slot holds one instruction address. When the core retires that instruction, the encoder emits one 16-byte record. The core pays nothing: no code, no cycles. |
| Software records (ACT-CAP) | One doorbell per core at `0x4000_0000`. One store to it = one record with a run-time value. Costs one instruction plus six nops. |
| Console | Per core: 2 KiB TX FIFO + 2 KiB RX FIFO at `0x4000_0100` (core side). Not a UART (§7). |
| Record path | encoder → shim FIFO (256 records) → AXI FIFO (1024 records) → Linux over `/dev/mem`, read by `rvmon`. 1281 records per core fit without loss. Or, with `--route ddr`: encoder → shim → a 128 MiB ring per core in PS DDR4 (8 million records), read back by `rvmon` after the run. |
| Timestamp | One fabric counter feeds both encoders. 32 bits in the record. Same time base on both cores. Wraps after about 57 s at 75 MHz. |
| Also in the design, not used here | A 1 MiB N-Trace ring for compressed trace. `rvmon` does not read it. |
| Bitstream | Prebuilt in the tree: the N3 build, DDR rings included. Timing closed (WNS +1.550 ns), shared memory in UltraRAM. Verified on two KV260s, 2026-08-26 and 2026-08-27. |

Words used below. ACT-ST is a hardware watchpoint on an instruction
address. ACT-CAP is a software-issued record with a run-time value. CTTE
is the trace encoder. `rvmon` is the Linux tool that loads, starts, drains
and analyses (§5). A record is 16 bytes: PC, 24-bit tag, timestamp, meta.

---

## 2. What you need

On the Kria (target):

* a KV260 with Ubuntu (24.04 verified), reachable over SSH, direct or
  through a jump host
* `gcc`, `make`, `device-tree-compiler`. One `apt-get install` covers them.

On your host (build machine):

* a RISC-V GCC: `riscv32-unknown-elf-`, or `riscv64-unknown-elf-` with
  the rv32 multilib (GCC 10.1 verified)
* `python3`, bash
* Vivado 2026.1, but only to rebuild the bitstream (2024.2 verified too).
  You do not need it; the bitstream is in the tree.

Not needed anywhere: a trace decoder. The records are plain 16-byte words.

---

## 3. Where the code is

Everything is under `examples/kv260/tgc5b2_rvcfi/`:

```
rtl/          the SoC: shared memory, ACT-CAP doorbell, console, SoC top
sim/          testbenches (Verilator through abc); tb_rvcfi_e2e.sv is the full system
sw/           the demo programs, the generators, the watchpoint tables
sw/src/       the sources you will reuse: crt0.S, prog.ld, rv_shared.h, rv_console.h, ...
sw/malloc/    the newlib malloc program (§12)
board/        deploy.sh (puts the app on the board) and rvmon/ (the Linux tool)
fpga/         Vivado project and scripts; fpga/prebuilt/ holds the ready app
```

Which files are the truth, and which are made from them:

| File | Role |
|---|---|
| `sw/src/main.c`, `sw/src/crt0.S`, `sw/src/prog.ld` | source: the demo program, its start code, its memory layout |
| `sw/src/rv_shared.h` | source: layout of the shared memory and the host protocol. Read by the programs and by `rvmon`. |
| `sw/src/rv_tags.h`, `sw/src/rv_site.h`, `sw/src/rv_console.h` | source: the demo's tag format, the label macros, the console driver |
| `sw/gen_program.py`, `sw/gen_sites.py`, `sw/build.sh` | source: the generators and the build |
| `sw/src/rv_funcs_core0.c`, `sw/src/rv_funcs_core1.c`, `sw/src/rv_funcs.h`, `sites_meta_core*.json` | generated by `gen_program.py` |
| `rvcfi_core*.hex`, `rvcfi_core*.dis`, `rvcfi_core*.sym` | generated by `build.sh`. Committed, so nobody needs a toolchain to run. The `.elf` is not committed. |
| `wp_table_core*_full.txt`, `wp_table_core*_hot.txt`, `sites_core*.csv` | generated by `gen_sites.py`, committed |
| `sw/malloc/` images and `wp_table_none.txt` | generated by `sw/malloc/build.sh`, not committed (they contain newlib) |
| `fpga/prebuilt/tgc5b2_rvcfi/` | the built app, with `MANIFEST.sha256` |

Rule: after any change to a program, run the three commands in §6.3 again.
The tables hold addresses. A code change moves them.

---

## 4. Put the demo app on your board

First check the app is intact:

```bash
cd examples/kv260/tgc5b2_rvcfi
(cd fpga/prebuilt/tgc5b2_rvcfi && sha256sum -c MANIFEST.sha256)
```

Then deploy. The script stages the files, builds `rvmon` on the board,
stops the dashboard service, sets `pl_clk0` to 75 MHz, loads the app, and
reads the design's MAGIC back:

```bash
bash board/deploy.sh --board <board-ip> --prebuilt
# through a jump host:  add --jump <host>
# other user than ubuntu: add --user <name>
```

Then, on the board:

```bash
cd /tmp/rvcfi
sudo ./rvmon status
```

Expected:

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

`magic ... (ok)` says the right bitstream is loaded. "NOT armed" is fine
at this point; `rvmon load` arms the timestamps (§10.1).

To give the board back (unload the app, restart the dashboard service):
`bash board/deploy.sh --board <board-ip> --restore`. It does not reload
the previous app; that is `xmutil loadapp <name>` by hand.

To rebuild the bitstream yourself, see tutorial §7 and
[TUTORIAL_build_demos.md](../TUTORIAL_build_demos.md). You do not need
this.

---

## 5. rvmon, in one page

Every step below goes through `rvmon`, so know what it is: two C files
and a header (`board/rvmon/rvmon.c`, `board/rvmon/monitors.c`,
`board/rvmon/rvmon.h`), no libraries, built on the board with `make`.
Everything it does to the hardware is a plain register access through
`/dev/mem`. Nothing is hidden: every address is a named constant in
`board/rvmon/rvmon.h`, §14 says where each register is defined, and you
can replay any step with `devmem` by hand.

| Command | What it does, register by register |
|---|---|
| `rvmon status` | Reads the MAGIC and the run bits (CTRL bank at `0xA000_0000`), the doorbell and conversion counters (`0xA000_0040..0x54`), the shim drop counters (WPCTRL at `0xA040_0000`), the FIFO occupancy (`0xA041_0000` / `0xA042_0000`), the two DDR ring banks (`0xA000_0080` / `0xA000_00A0`), the console state and the timestamp state. Writes nothing. Run it first, always. |
| `rvmon load` | Refuses while a core runs. Writes the two program images into the RAM windows (core 0 at `0xA010_0000`, core 1 at `0xA008_0000`), writes the 1023 watchpoint slots into each encoder (§9.1) and reads three back, then arms both timestamp units (`0xA001_0040` / `0xA002_0040` = `0x8033`) and reads them back. |
| `rvmon run` | Writes the demo's control block into shared memory (`0xA004_0000`), releases both cores with one write (CONTROL `0xA000_0000` = `0x300`), drains both record FIFOs while they run, stops the cores (CONTROL = 0), prints the per-run drop delta, and writes `core0.bin` / `core1.bin`. With `--route ddr` it routes the records into the DDR rings instead (ring banks at `0xA000_0080` / `0xA000_00A0`: stop, route, clear, enable, run, read back) and judges the run by the ring counters. |
| `rvmon drain` | Only the FIFO draining, no start and no stop. For cores you started yourself (§10.3). `--route ddr` reads already-filled rings instead. |
| `rvmon console` | Moves characters through the console registers in the CTRL bank (`0xA000_0060` core 0, `0xA000_0070` core 1). Works while the cores run (§7). |
| `rvmon analyze` | No hardware. Reads record files and runs the demo's five monitors. This one is demo-specific (§11). |
| `rvmon selftest` | No hardware. Checks the analyser against built-in cases. Runs on your workstation too. |

`rvmon help` prints the exact options.

---

## 6. Run the demo once

Do this before your own program. It proves the board, the clock, the
record path and `rvmon` in one go.

### 6.1 One command

```bash
cd /tmp/rvcfi
sudo bash run_board_verdicts.sh     # last line must be: BOARD_VERDICTS_OK
```

This runs the demo in all five modes (the table in §6.2) plus one leg
with software instrumentation on, then the same six legs again with the
records routed through the DDR rings: 12 legs, every verdict judged.

### 6.2 The same by hand

This is the pattern you will reuse for your own program:

```bash
sudo ./rvmon load --hex0 rvcfi_core0.hex --hex1 rvcfi_core1.hex \
     --wp0 wp_table_core0_full.txt --wp1 wp_table_core1_full.txt
sudo ./rvmon run --mode 1 --iters 60 --pace 0 --seconds 5
sudo ./rvmon analyze --in0 core0.bin --in1 core1.bin \
     --map0 sites_core0.csv --map1 sites_core1.csv
```

Expect `LOAD_OK`, then `shim drops: core0=0 core1=0 (clean)` and `RUN_OK`,
then a verdict with a `[mon_lockset] data-race` finding.

`--mode` selects what the demo programs do. It is one word that
`rvmon run` writes into shared memory before the start; the programs read
it. The watchpoint table is the same for all five runs:

| Mode | Name | What the programs do | What `rvmon analyze` must say |
|---|---|---|---|
| 0 | `M0_SAFE` | every account update inside a correct lock | `CLEAN`: the detector must not cry wolf |
| 1 | `M1_RACE_OPEN` | the lock around the account update is skipped | a data race, both sites named |
| 2 | `M2_RACE_WRONG_LOCK` | both cores lock, but each takes a different lock | a lockset finding, although the accesses never had to overlap in time |
| 3 | `M3_LOCK_ORDER` | two locks, taken in opposite order by the two cores | a lock-order inversion, for a deadlock that did not happen in this run |
| 4 | `M4_CFI_SKIP` | one dispatch index is corrupted | a forward-edge CFI violation |

The point of the five runs is which monitor fires on which mode; tutorial
§1 tells that story, and tutorial §16 carries the measured verdict
tables. The mode word means nothing to your own program: read `SH->mode`
from the control block if you want it, or ignore it (§8.2).

### 6.3 Rebuild the demo programs on your host (optional)

This is "how to compile an application" for the demo:

```bash
cd examples/kv260/tgc5b2_rvcfi/sw
python3 gen_program.py     # -> src/rv_funcs_core{0,1}.c, src/rv_funcs.h, manifests
bash build.sh              # -> rvcfi_core{0,1}.{elf,dis,hex,sym}
python3 gen_sites.py       # -> wp_table_core{0,1}_{full,hot}.txt, sites_core{0,1}.csv
```

Expect `GEN_OK`, `BUILD_OK`, `SITES_OK`. `build.sh` finds the toolchain by
itself; set `CROSS=riscv64-unknown-elf-` if it does not. Copy the new
`.hex` and table files to `/tmp/rvcfi` on the board with `scp`.

The rebuilt files will not be byte-identical to the committed ones if
your compiler differs (the committed set came from GCC 10.1 with
`-march=rv32i`). That is fine. What matters is that image and tables
travel together (§3).

---

## 7. Talk to a program on a core

There is no UART. Each core has a character channel: two FIFOs behind
registers. No device tree, no kernel driver, and it works while the cores
run.

On the board:

```bash
sudo ./rvmon console --core 0                       # print what core 0 wrote
sudo ./rvmon console --core 1 --send "hello" --seconds 5   # send a line, then listen 5 s
```

There is no persistent terminal mode: one `rvmon console` call sends at
most one line and listens for the given time. For an interactive session,
wrap it in a loop. Each line you type goes to the core, and whatever the
core prints comes back:

```bash
while read -r line; do
    sudo ./rvmon console --core 0 --send "$line" --seconds 1
done
```

Whether the core answers live is your program's job: call `rv_getc()` in
your main loop and react. The demo programs only echo what was queued
before the run.

In your program, include `sw/src/rv_console.h`:

```c
rv_puts("hello\n");          /* blocking; waits for TX space */
int c = rv_getc();           /* non-blocking; -1 if nothing waits */
unsigned n = rv_rx_count();  /* characters waiting */
```

Console I/O never appears in the trace: the registers are in a private
segment and carry no watchpoints. Overflow is counted, not hidden. A write
into a full TX is dropped and counted at `0x4000_010C`, and the PS sees
its own drop counter in the `console` line of `rvmon status`.

---

## 8. Build your own program

### 8.1 What to keep, what to replace

Keep from `sw/src/`: `crt0.S` (sets the stack, clears bss, calls `main`,
then parks), `prog.ld` (64 KiB at address 0), `rv_shared.h`,
`rv_console.h`. Keep the compiler flags from `sw/build.sh`:
`-march=rv32i -mabi=ilp32 -ffreestanding -nostdlib -nostartfiles`.

Replace `main.c` with your program. You do not need `gen_program.py`,
`gen_sites.py`, `rv_site.h` or `rv_tags.h`. They belong to the demo's
race analysis.

### 8.2 The contract with `rvmon`

`rvmon run` always starts both cores, and it writes the first `0x1C0`
bytes of the shared memory before it does (the demo's control block:
magic, mode, iters, pace, go, seed, and zeros up to `0x1BF`). Then it
drains both FIFOs, and it stops both cores after `--seconds`, or earlier
when no record has arrived for about 0.4 s.

So:

* Keep your own shared data above offset `0x200` of the shared memory.
* Either wait for the control block like the demo does (below), or ignore
  it. Both work.
* A program that is silent for more than 0.4 s looks "finished" to
  `rvmon run`. See §13.
* You need an image for both cores. Build your program twice
  (`-DRV_CORE=0` and `-DRV_CORE=1`), or give the second core any image,
  for example the demo's, with the table from §9.6 with no real entries.

### 8.3 A minimal program

```c
#include "rv_shared.h"
#include "rv_console.h"
#define SH RV_SHARED

static void __attribute__((noinline)) work(unsigned n)
{
	volatile unsigned acc = 0;
	while (n--) acc += n;
}

int main(void)
{
	while (SH->magic != RV_MAGIC) { }   /* rvmon run wrote the control block */
	while (SH->go == 0u) { }            /* start barrier: both cores start together */
	rv_puts("hello from my program\n");
	work(SH->iters);                    /* the count rvmon run set (--iters) */
	SH->result[RV_CORE].done = RV_DONE_MAGIC;   /* rvmon run prints this mailbox */
	return 0;                           /* crt0 parks in a halt loop */
}
```

Use `__attribute__((noinline))` on every function you want to see. With
`-O2` the compiler inlines small functions, and an inlined function has
no entry, no call site and no return.

Also pass the function something the compiler cannot compute at build
time (here: the `iters` word from the control block). With a constant
argument, gcc clones a static function into `work.constprop.0`, and the
plain name `work` disappears from the symbol table, `noinline` or not.

### 8.4 Build it

Easiest: copy `sw/build.sh` and change the source list in its `gcc` line.
The essential steps, with the toolchain prefix of your machine:

```bash
cd examples/kv260/tgc5b2_rvcfi
CROSS=riscv32-unknown-elf-
LIBGCC=$($CROSS'gcc' -march=rv32i -mabi=ilp32 -print-libgcc-file-name)
$CROSS'gcc' -march=rv32i -mabi=ilp32 -O2 -g -ffreestanding -fno-builtin -fno-common \
    -Isw/src -DRV_CORE=0 -nostdlib -nostartfiles -T sw/src/prog.ld \
    sw/src/crt0.S my_prog.c $LIBGCC -o my_core0.elf
$CROSS'objdump' -d my_core0.elf > my_core0.dis      # addresses for §9
$CROSS'nm' -n my_core0.elf > my_core0.sym           # symbols for §9
$CROSS'objcopy' -O binary my_core0.elf my_core0.bin
od -An -tx4 -v -w4 my_core0.bin | tr -d ' ' | grep -v '^$' > my_core0.hex
```

The `.hex` is one 32-bit word per line. `rvmon load` writes it into the
core's RAM. Check the size: `my_core0.bin` must stay below 64 KiB, and in
practice below `0xE000` to leave room for the stack. `libgcc` is linked
because RV32I has no divide instruction.

### 8.5 With a C library (malloc, printf-free newlib)

Copy `sw/malloc/build.sh` instead. It links newlib nano
(`-specs=nano.specs -specs=nosys.specs`) and gives it a heap through
`_sbrk()`. See §12.

---

## 9. Set watchpoints on your functions (ACT-ST)

### 9.1 The registers behind it

Each encoder holds a table of 1023 watchpoint slots. A slot is one
instruction address plus a command word. When the core retires the
instruction at that address, the encoder emits one record.

Three registers program the table. For encoder 0 (core 0; encoder 1 is
the same at `0xA002_xxxx`):

| Register | Address | Meaning |
|---|---|---|
| `trWpIndex` | `0xA001_400C` | which slot the next write fills |
| `trWpDataLow` | `0xA001_4010` | the instruction address |
| `trWpDataHigh` | `0xA001_4014` | the command word (§9.3). Writing it commits the slot and moves the index on. |
| `trWpReadLow` / `trWpReadHigh` | `0xA001_4018` / `0xA001_401C` | read the slot at the current index back |
| `trWpCap` | `0xA001_4020` | how many slots the table has (1023 here) |

So one slot by hand is three `devmem` writes: index, address, command.
`rvmon load` does exactly this 1023 times, reading the slots from a text
file (§9.2), and then reads three slots back to prove the writes landed.

Rules for the table, from the encoder's RDL:

* All 1023 slots are filled. The lookup is a perfect binary tree; an
  empty slot is a wrong branch, not a "don't care".
* Addresses strictly ascending, no duplicates.
* Unused slots hold odd addresses. Instructions are 4-byte aligned
  (RV32I without the C extension), so an odd address never matches.

### 9.2 The table file

This is the file you pass to `rvmon load --wp0` / `--wp1`. You write it
yourself, any name (the demo's are `wp_table_core0_full.txt` and
friends). Plain text, one slot per line, `ADDRESS COMMAND`, both hex.
Lines that start with `#` are comments:

```
000002D8 00010141
```

### 9.3 The command word

Bits `[5:0]` = command, `[7:6]` = sink, `[31:8]` = your 24-bit tag. Use
command 1, `DAQ_PC_CURR`; it is the only command that carries a
timestamp. Use sink 1, the AXIS path `rvmon` reads. The low byte is then
always `41`, and the whole word is `(tag << 8) | 0x41`. The tag in the
line above is `0x000101`.

Other commands exist. `DAQ_DADDR` (5) reports the data address of a load
or store, but without a timestamp; `DAQ_DIRECT` (3) reports only the tag.
Tutorial §11 shows the `DAQ_DADDR` pairing.

### 9.4 Which address for entry, call site, return

Take them from the disassembly (`.dis`) and the symbol list (`.sym`) of
the image you load. Every rebuild moves them.

| You want | Take this address | Example from the demo's `rvcfi_core0.dis` / `.sym` |
|---|---|---|
| Function entry | the symbol address of the function | `000002d8 T rv_t000` → `000002D8` |
| Call site | the address of the `jal` / `jalr` instruction in the caller | `24: 008000ef jal ra,2c <main>` → `00000024` |
| Return (the function leaves) | the address of the `ret` (`jalr x0,0(ra)`) in the function | `298: 00008067 ret` → `00000298` |
| Return target (where the caller continues) | the instruction after the `jal` in the caller | `00000028` |

The record's PC is the address of the retired instruction, so the
watchpoint on a `jal` reports the call site itself, not the callee. For
the callee you use its entry. A function with several `ret` instructions
needs one slot per `ret`.

Budget: three slots per function (entry, return, one call site) give
about 340 fully instrumented functions per core. If you need more,
choose. The demo does the same with its `hot` table: fewer slots, fewer
records, no other change (§13).

### 9.5 Your tags

The 24-bit tag is yours. The hardware does not interpret it. A simple
scheme: bits `[23:20]` = kind (1 entry, 2 call site, 3 return, 4 return
target), bits `[19:0]` = a function or site number of your choice. Keep a
list (a CSV like `sw/sites_core0.csv`) that maps tag to meaning; your
reader (§11) needs it.

The demo's own tag format is `sw/src/rv_tags.h`. `rvmon analyze`
understands only that format. It is a convention, not a hardware
property.

### 9.6 Make the table

Any script will do. This one takes `(address, tag)` pairs and writes a
valid table. The padding follows `gen_sites.py`: odd addresses above the
last real one, ascending:

```python
sites = [(0x000002D8, 0x100001), (0x00000024, 0x200001), (0x00000298, 0x300001)]
sites.sort()
rows = ["%08X %08X" % (a, (t << 8) | 0x41) for a, t in sites]
pad = (sites[-1][0] | 1) + 2
while len(rows) < 1023:
    rows.append("%08X 00000000" % pad)
    pad += 2
open("wp_table_mine.txt", "w").write("\n".join(rows) + "\n")
```

A table with no real entries (for a core you do not trace) is the same
script with an empty list and `pad = 0x10001`.

Check it: `grep -vc '^#' wp_table_mine.txt` must print `1023`. `rvmon
load` refuses a table with the wrong slot count, and it reads three slots
back after writing. If a slot reads back wrong, it says so and stops.

### 9.7 Worked example: two watchpoints on `work()`

Take the minimal program from §8.3 and trace every call of `work`: one
watchpoint on its entry, one on its `ret`. First find the two addresses:

```bash
grep ' work$' my_core0.sym                        # the entry:  00000024 t work
sed -n '/<work>:/,/ret$/p' my_core0.dis | tail -1 # its ret:    50: 00008067 ret
```

Give the entry tag `0x100000` (kind 1, function 0) and the return tag
`0x300000` (kind 3, function 0), per the scheme in §9.5. The two real
table lines are then:

```
00000024 10000041
00000050 30000041
```

Fill the file to 1023 lines with the script in §9.6, then on the board:

```bash
sudo ./rvmon load --hex0 my_core0.hex --hex1 my_core1.hex \
     --wp0 wp_table_mine.txt --wp1 wp_table_mine.txt
sudo ./rvmon run --seconds 5
python3 reader.py core0.bin                # the ten-line reader from §11
```

What comes back, one line per record. Measured on a KV260 on 2026-08-27
with the N3 app and the program from §8.3 exactly as printed; your
addresses move with any code change, so take them fresh from the `.sym`
/ `.dis` of the image you load:

```
core 0  pc 00000024  kind 1  site     0  t 38761844.293 us
core 0  pc 00000050  kind 3  site     0  t 38762164.427 us
```

Entry at `t1`, return at `t2`: `work(2000)` ran 320 µs. Core 1 produced
the same pair at the same times, because one register write starts both
cores on one time base. One pair per call. The same run with
`--route ddr` returned the same two records from the DDR ring (8 beats,
0 drops). That is the whole loop: address from the disassembly, line in
the table, `load`, `run`, read.

---

## 10. Load, trace, capture

### 10.1 Load

```bash
sudo ./rvmon load --hex0 my_core0.hex --hex1 my_core1.hex \
     --wp0 wp_table_mine.txt --wp1 wp_table_mine.txt
```

`load` refuses to run while a core runs, because writing a running core's
RAM hangs the bus. It writes both images, both tables, verifies the
tables by readback, then arms both timestamp units and reads them back.
The arming value, `trTsControl` = `0x8033`, sets Active, Count, Type =
the shared fabric counter, and Enable. Expect `LOAD_OK`. `rvmon status`
now says `core0=armed core1=armed`.

That is the whole encoder configuration. The Nexus trace engine
(`trTeControl`) stays off; the watchpoint path does not need it.

### 10.2 Run and capture

```bash
sudo ./rvmon run --seconds 5
```

`run` writes the control block, opens the `go` barrier, releases both
cores with one register write, drains both FIFOs while they run, and
stops both cores after 5 s or after 0.4 s of silence. It writes
`core0.bin` and `core1.bin` (raw records) and prints:

```
records: core0=1234 core1=1234 in 0.44 s (...)
shim drops: core0=0 core1=0 (clean) (cumulative since load: 0/0)
wrote core0.bin (19744 B) and core1.bin (19744 B)
RUN_OK
```

`RUN_WITH_DROPS` means the stream is incomplete: go to §13. `--out0` /
`--out1` rename the files. The mailbox line (`core0 done=...`) shows
garbage if your program does not write the mailbox; ignore it.

For a run that must survive the full record rate, add `--route ddr`.
The records then go into a 128 MiB DDR ring per core instead of the
FIFOs, the host is out of the hot path, and `rvmon` reads the rings back
after the run. Same record files, same reader. Tutorial §10c has the
registers and the order contract.

### 10.3 By hand, without `rvmon run`

Start and stop are one register: CONTROL at `0xA000_0000`, bit 8 = core 0
runs, bit 9 = core 1 runs.

```bash
sudo busybox devmem 0xA0000000 32 0x300    # start both
sudo ./rvmon drain --seconds 10            # drain to core0.bin / core1.bin
sudo busybox devmem 0xA0000000 32 0x0      # stop both
```

A parked core restarts from address 0 when you release it again. The
control block from the last `rvmon run` is still in shared memory, so a
program that waits on magic and `go` runs immediately.

**Never touch the shared memory window (`0xA004_0000`) or a core's RAM
window while that core runs.** The access never completes, and only a
power cycle recovers the board. `rvmon` enforces this; `devmem` does not.

### 10.4 Records from software (ACT-CAP)

For a value only known at run time (a pointer, a counter, a lock id): one
store to the doorbell, six nops after it. From `sw/src/rv_tags.h`:

```c
#include "rv_tags.h"
RV_ACTCAP(RV_ACT_CMD_DAQ_PC_CURR, RV_ACT_SINK_AXIS, my_24bit_tag);
```

The record looks exactly like a watchpoint record: PC of the store, your
tag, timestamp. The six nops are needed. If a watchpoint instruction
retires in the cycle the doorbell beat lands, the encoder drops the
doorbell command. `rvmon status` counts `doorbell hits` (stores issued)
and `act-cap conv` (records made); if the two differ, that is the reason.

---

## 11. Read the records

`core0.bin` is a sequence of 16-byte records, four little-endian 32-bit
words:

| Word | Content |
|---|---|
| 0 | PC of the retired instruction |
| 1 | your 24-bit tag, zero-extended |
| 2 | timestamp, 32 bits, 75 MHz ticks |
| 3 | meta: bits `[23:20]` core id, `[19:8]` strobe, `[7:0]` stream id |

`rvmon analyze` only understands the demo's tags. For your own tags, ten
lines of Python are enough:

```python
import struct, sys
MHZ = 75.0
data = open(sys.argv[1], "rb").read()
for off in range(0, len(data) - 15, 16):
    pc, tag, ts, meta = struct.unpack_from("<4I", data, off)
    kind, site = tag >> 20, tag & 0xFFFFF
    print("core %d  pc %08X  kind %d  site %5d  t %12.3f us"
          % ((meta >> 20) & 0xF, pc, kind, site, ts / MHZ))
```

Entry/return pairs give you call durations. Timestamps of the two cores
are comparable because both encoders share one counter. The counter wraps
after 2^32 ticks, about 57 s; unroll it in your reader if a run is
longer.

A complete reader with a verdict is `sw/malloc/decode_malloc.py`
(`--sym` for names, `--mhz 75`). Copy it.

---

## 12. Is malloc working? Yes

`sw/malloc/` is a program that links newlib nano and calls
`malloc`/`free` on both cores. Every allocation is reported through
ACT-CAP: id, size, pointer, caller, and every heap growth from inside
`_sbrk()`. Verified in simulation and on the KV260: 115 records per core,
0 drops, same pointers to the byte.

How it works: newlib needs one hook, `_sbrk()`. The program gives it a
heap from `_end` (end of the image) up to `0xD000`, below the stack. A
request beyond that returns NULL. See `sw/malloc/src/malloc_demo.c`.

Build and run it. The images contain newlib and are therefore not
committed:

```bash
cd examples/kv260/tgc5b2_rvcfi/sw/malloc && bash build.sh    # needs riscv32-unknown-elf-gcc
scp malloc_core0.hex malloc_core1.hex wp_table_none.txt decode_malloc.py malloc_core0.sym <board>:/tmp/rvcfi/
# on the board, in /tmp/rvcfi
sudo ./rvmon load --hex0 malloc_core0.hex --hex1 malloc_core1.hex --wp0 wp_table_none.txt --wp1 wp_table_none.txt
sudo ./rvmon run --seconds 3 --iters 1
python3 decode_malloc.py core0.bin --sym malloc_core0.sym --mhz 75      # expect MALLOC_DEMO_OK
```

Details, the decoded heap timeline and two traps:
[sw/malloc/README.md](sw/malloc/README.md).

---

## 13. Limits

| Limit | Numbers | What to do |
|---|---|---|
| Record rate vs. drain (FIFO route) | ~490 000 records/s per core generated, unthrottled; the FIFO path buffers 1281 records per core | `--route ddr` (§10.2): the DDR rings take the full rate, measured loss-free at 1.14 million records per core. On the FIFO route: fewer table slots (the table is the rate control), a burst that fits 1281, pacing in the program. |
| Lost records | counted in `shim drops` (WPCTRL `0xA040_0000`); cleared only by bitstream reload | any drop: `RUN_WITH_DROPS`, and `rvmon analyze` refuses the verdict (`INCONCLUSIVE`). Pick a lever, run again. |
| Trace content | only addresses in the table. No data values from a watchpoint; `DAQ_DADDR` has no timestamp | use ACT-CAP (§10.4) for run-time values |
| Not traced | stack traffic, interrupt path, spin loops | put a site in the table if you must; a spin loop drowns everything |
| Timestamp | 32 bits, wraps after ~57 s; only `DAQ_PC_CURR` carries one; assumes 75 MHz | unroll the wrap in your reader; `deploy.sh` sets the clock, a power cycle resets it to 100 MHz |
| Quiescence stop | `rvmon run` stops after ~0.4 s without a record | start by hand and use `rvmon drain` (§10.3), or emit a heartbeat record |
| Memory | 64 KiB per core for code, data and stack; shared memory and RAM windows PS-visible only while both cores are stopped | keep the image below `0xE000`; never `devmem` a running core's window |
| Cores | RV32I: no atomics, no compressed instructions; both cores always start together | software locks (the demo's Peterson lock); the odd-address padding relies on 4-byte alignment |
| Table | one per `load`; reloading means stopping the cores | plan the 1023 slots (~340 functions at 3 slots each) |
| Console | 2 KiB per direction; overflow dropped and counted | check the counters in `rvmon status` |
| Demo tools | `rvmon analyze` and the monitors know only the demo's tag format; `wp_table_none.txt` and the malloc images are build outputs, not committed | write your own reader (§11); run `sw/malloc/build.sh` first |

---

## 14. Register definitions on the PL side

| Registers | Where defined | Notes |
|---|---|---|
| Encoder CSRs (`trTsControl`, `trWpIndex`, `trWpDataLow/High`, `trWpCap`, `trActCapStCmd`, ...) | `rdl/ct_cs_cpuif.rdl` (repository root; SystemRDL, the single source) | `make rdl-html` renders it to HTML under `bld/rdl-html/`. Base addresses: ENC0 `0xA001_0000`, ENC1 `0xA002_0000`. |
| SoC CONTROL/STATUS, the observation bank `0x40..0x5C` (doorbell hits, ACT-CAP conversions, shared size, MAGIC), console PS side `0x60..0x7C` | header comment of `rtl/tgc5b2_rvcfi_soc_top.sv` | Base `0xA000_0000`. Also the core-side address map. |
| Console, core side (`0x4000_0100`: TX, RX_CNT, RX_POP, TX_DROPS) | header comment of `rtl/ct_soc_console.sv` | driver: `sw/src/rv_console.h` |
| ACT-CAP doorbell (`0x4000_0000`) and the command word | `rtl/ct_soc_doorbell.sv`, `sw/src/rv_tags.h` | |
| WPCTRL (shim drops, fill level, overflow sticky) `0xA040_0000`; the AXI FIFOs `0xA041_0000` / `0xA042_0000` (Xilinx PG080 register set) | header comment of `fpga/tgc5b2_rvcfi_kv260_top.sv` | |
| DDR ring banks (`RING_CTRL`, `BASE`, `SIZE`, `WPTR`, `STAT`, `DROPS`, `BEATS`) at CTRL `0x80` core 0 / `0xA0` core 1 | header comment of `rtl/tgc5b2_rvcfi_soc_top.sv`; tutorial §10c | rings at `0x5000_0000` / `0x5800_0000` in the reserved 256 MiB |
| All of the above as C constants | `board/rvmon/rvmon.h` | what `rvmon` actually uses |
| The PS aperture of all KV260 examples | `examples/kv260/SPEC_board_memory_map.md` | |

Note: `examples/kv260/common/tgc5b/rdl/ct_soc.rdl` describes a different
SoC, the single-core `tgc5b` example. Its CTRL bank is not this one.

---

## 15. When something goes wrong

| Symptom | Cause, fix |
|---|---|
| `rvmon: CTRL magic is 0x00000000` | wrong or no bitstream. `xmutil listapps` on the board; deploy again. `fpga_manager` says "operating" even with no app. |
| `rvmon load` says "a core is running" | stop first: `sudo busybox devmem 0xA0000000 32 0x0`. |
| `rvmon load`: "trWpCap says 1023 slots, the table has N" | your table has the wrong number of lines (§9.6). |
| `rvmon load`: "index did not wrap" or a slot reads back wrong | the table is not strictly ascending, or has an even padding address that duplicates a real one. |
| All timestamps are 0 | timestamp units not armed. `rvmon load` arms them; `rvmon status` must say `armed`. By hand: `sudo busybox devmem 0xA0010040 32 0x8033` and the same at `0xA0020040`. |
| Timestamps look wrong by a factor 4/3 | PL clock is at 100 MHz after a power cycle. Run `deploy.sh` again, or `MHZ=75 bash kv260_plclk.sh` from `/tmp` (staged by deploy). |
| `RUN_WITH_DROPS` | too many records for the drain. Fewer slots, a shorter burst, or pacing (§13). |
| `rvmon run` ended but my program was not finished | it was silent for 0.4 s (§13). Start by hand and use `rvmon drain` (§10.3). |
| `doorbell hits` rise, `act-cap conv` does not | wrong doorbell address, or the six nops are missing (§10.4). |
| Both rise, records missing | dropped downstream: `shim drops`. |
| Board hangs on a `devmem` | you touched a window that belongs to a running core. Power cycle. |
| A function shows no entry/return records | it was inlined. `__attribute__((noinline))`, rebuild, take the addresses again. |

More: tutorial §14.

---

## 16. Where this document links to

* [TUTORIAL_runtime_verification.md](TUTORIAL_runtime_verification.md): the demo itself. The five modes, the monitors, throughput (§10), the console (§10a), loss accounting (§10b), the DDR fast lane (§10c), the full bitstream build (§7), troubleshooting (§14), the measured status (§16).
* [sw/malloc/README.md](sw/malloc/README.md): the malloc program in detail.
* [fpga/prebuilt/README.md](fpga/prebuilt/README.md): where the prebuilt app came from.
* [HANDOVER.md](HANDOVER.md): the development log of the demo. State snapshots, newest first.
* [../TUTORIAL_build_demos.md](../TUTORIAL_build_demos.md): building all KV260 examples.

---

## Status, 2026-08-27

The demo `tgc5b2_rvcfi` is built and measured, in simulation and on
KV260 boards. The ready-to-load bitstream in the tree is the N3 build
(DDR record rings, tutorial §10c; WNS +1.550 ns). Since this handover
`rvmon load` also arms the timestamp units. Reference tool: Vivado
2026.1; a 2024.2 build of the pre-N3 design was verified on the board
too.

Walked end to end on a KV260 on 2026-08-27, twice: first with the
pre-N3 app (deploy, the six FIFO verdict legs, the worked example in
§9.7, malloc), then with the N3 app and the merged `rvmon` (deploy
`--prebuilt`, all 12 verdict legs, the worked example on both routes).
Every output shown in this document is measured; the malloc numbers are
from the pre-N3 run, and nothing on that path changed in N3.
