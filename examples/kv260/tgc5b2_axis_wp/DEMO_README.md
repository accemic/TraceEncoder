<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# CEDARtools.TraceEncoder — KV260 watchpoint demo

This package contains a ready-to-load FPGA design for the **Xilinx KV260**
board, plus everything needed to run it and to trace your own program with it.

**What the design is.** Two independent RISC-V cores (MINRES TGC5B, RV32) run
on the FPGA. Each core has its own trace encoder watching it. When a core
executes an instruction at an address you marked, the encoder emits a small
record — the address, a timestamp, and a tag you chose — into a hardware FIFO.
A Linux program on the board reads those records out. You get an exact,
timestamped list of which marked places your program went through, without the
program itself doing any logging and without slowing it down.

The marks are called **watchpoints**; the mechanism the encoder uses is
**ACT-ST / ACT-CAP**. You can set up to 1023 of them per core.

---

## 1. What you need

- A KV260 board running Ubuntu, reachable over SSH, with `xmutil` installed
  (it ships with the Xilinx Ubuntu image).
- `sudo` on the board.
- Python 3 on the board (the Xilinx image has it).

Nothing needs to be installed on your PC. No Vivado, no licence.

---

## 2. What is in this package

```
app/         the FPGA design, ready for xmutil        <- install this
board/       scripts that run on the board
host/        the reader that decodes the records
demo/        a ready-made example program and its expected result
doc/         register maps and reference documentation
reports/     timing and resource figures for this build
BUILD_INFO.txt  which commit and which Vivado built it, and its checksum
```

---

## 3. Run the demo

One command does the whole thing — install, configure, run, check:

```bash
bash board/wp_demo_run.sh --board <your-board-hostname-or-ip>
```

It prints each step and what that step is for. It takes a couple of minutes.
Add `--dry-run` first if you want to see what it would do without touching the
board.

**What you should see at the end:**

```
G1CHECK runA fifo0: records=851 (expected 851)  invalid=0  wraps=0  misses=0
G1CHECK runA fifo1: records=851 (expected 851)  invalid=0  wraps=0  misses=0
G1CHECK runA cross-core: max|ts0[k]-ts1[k]| = 0
G1CHECK runa PASS

### DEMO_OK
```

851 records from each core, every one matching the expected list, and the two
cores' timestamps agreeing exactly. If you see that, the whole chain works:
FPGA loaded, both cores running, both encoders capturing, both FIFOs drained
correctly.

The captured records are left in `run/runA_reader_fifo0.log` and
`...fifo1.log` so you can look at them.

**When you are done**, put the board back the way it was:

```bash
bash board/wp_demo_run.sh --board <board> --restore
```

---

## 4. What just happened

```
  your program on core 0  ──▶  encoder 0  ──▶  shim  ──▶  FIFO 0  ──▶  you read it
  your program on core 1  ──▶  encoder 1  ──▶  shim  ──▶  FIFO 1  ──▶  you read it
```

1. Both cores were held stopped, and the demo program was written into their
   memories.
2. Each encoder was given a table of 1023 addresses to watch.
3. The cores were released. Every time a core reached a watched address, its
   encoder pushed a 4-word record into that core's FIFO.
4. After the program finished, the reader emptied both FIFOs and compared what
   came out against the expected list.

Each record is four 32-bit words: the **program counter**, a **24-bit tag** you
chose when you set the watchpoint, a **timestamp**, and some metadata (which
core it came from).

Both encoders stamp their records from **one shared counter**, which is why the
two cores' timestamps can be compared directly — that is what the
`cross-core: max|ts0-ts1| = 0` line is checking.

---

## 5. Trace your own program

The demo program is just an example. To use your own:

1. **Build your program** for the core. It is RV32I, with 64 KiB of RAM at
   address 0 and a CLINT timer at `0x1000_0000`. `demo/src/` has a working
   linker script (`prog.ld`), startup code (`crt0.S`) and build script
   (`build.sh`) — start from those. Produce a `.hex` file the same way
   `demo/build.sh` does.

2. **Choose your watchpoints.** A watchpoint is an address plus a 24-bit tag.
   `demo/gen_wp_set.py` shows the format and writes the table file; the table
   must be filled completely (1023 slots) with strictly ascending addresses.
   Unused slots get filler addresses your program never executes.

3. **Run it.** The board script takes your files instead of the demo's:

   ```bash
   python3 board/wp_board.py prep --walk 0 \
       --hex  your_program.hex \
       --wp   your_wp_table.txt
   python3 board/wp_board.py start
   # ... let it run ...
   python3 board/wp_board.py stop
   python3 host/read_wp_stream.py --source fifo --base 0xA0410000 --core 0 --raw
   ```

   `0xA0410000` is core 0's FIFO, `0xA0420000` is core 1's.

4. **Read the records.** `host/read_wp_stream.py` prints them decoded. Without
   `--expected` it just dumps what it found, which is what you want when there
   is no known-good answer to compare against.

---

## 6. Register maps

Open **`doc/tgc5b2_kv260.rdl.html/index.html`** in a browser. That is the
complete address map of this design as the board sees it — both encoders, the
core control block, the trace ring, the FIFOs — every register at the address
you would actually poke with `devmem`.

The most useful entries:

| What | Where |
|---|---|
| Start / stop the cores | `soc.ctrl.control` at `0xA000_0000` |
| Encoder 0 registers | `soc.enc0` from `0xA001_0000` |
| Encoder 1 registers | `soc.enc1` from `0xA002_0000` |
| Core 0 / core 1 memory | `0xA010_0000` / `0xA008_0000` |
| Is the design alive? | `wpctrl.magic` at `0xA040_0000` reads `0x41575031` |
| Records dropped? | `wpctrl.shim0_drop` / `shim1_drop` |
| Read the records | `fifo0.rdfd` at `0xA041_0020` |

`doc/ct_cs_cpuif.rdl.html/` is the same encoder register map without this
design's base addresses — use it if you are integrating the encoder into a
different chip.

---

## 7. If something goes wrong

**"MAGIC_FAILED" or the magic register reads something else.** The FPGA design
is not loaded, or a different design is. Check `sudo xmutil listapps` on the
board.

**The board stops answering SSH after loading.** Something was holding the old
design's memory open while it was unloaded. Power-cycle the board. The demo
script avoids this by stopping the `ctrace-dashboard` service first — if you
load the app by hand, stop that service first too.

**Records are missing, or `drop` is not zero.** The FIFO filled up faster than
it was drained. Either your program hits watchpoints faster than the reader
empties them, or the reader was started too late.

**Nothing at all comes out.** Check the cores actually ran:
`soc.ctrl.status` bits 8 and 9 are the running flags. If they are 0, the start
never took effect. If you wrote a program into a core's memory while it was
running, the write hangs — always stop the core first.

**The clock.** This design needs `pl_clk0` at **75 MHz**. The board boots at
100 MHz. `board/kv260_plclk.sh` sets it, and the demo script calls it — but the
clock can only be changed while no design is loaded.

---

## 8. Licence

The design and its documentation are dual-licensed, CERN-OHL-S-2.0 or a
commercial licence from Accemic Technologies. See `LICENSE.md` and `LICENSES/`.
