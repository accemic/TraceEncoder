<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# SPEC: KV260 board memory map

**What this is.** The single address plan every KV260 example in this
repository is built against.

**Why it appears only now (2026-08-21).** Sixteen places in twelve tracked
source files referenced this document by name — `ct_trace_sinks.sv`,
`axi_ram_sim.sv`, `duo_soc_top.sv`, `trio_soc_top.sv`, the four Rocket
files, both `*_kv260_top.sv`, two READMEs — and every one of them pointed at
`docs/SPEC_board_memory_map.md`. That path does not exist in what you
cloned: `docs/` is listed in `.gitignore` (line 47). The document lived in
the internal predecessor repository, the references came along with the
migration, and the file did not. Anyone reading the RTL headers was sent to
a path that is deliberately not published.

This file is that document, moved into the published tree next to the
examples it describes, with every reference rewritten to point here. It is a
**description of what the RTL and the overlay actually do**, not a wish
list: every number below carries the file it comes from.

---

## 1. The reserved PS DRAM window

The soft cores live in PS DDR, not in PL memory. Linux must therefore be
kept away from that range, which is what the device-tree overlay
[`common/board/ctrace_resmem.dtso`](common/board/ctrace_resmem.dtso)
does — a `reserved-memory` node with **`no-map`**, so the kernel never hands
the region out and never maps it into its linear map.

**Address plan v4** (since 2026-08-10), node `ctrace-pl-ddr@50000000`,
512 MiB:

| PS address | Size | Use |
|---|---|---|
| `0x5000_0000` | 256 MiB | DDR trace sink (`ct_soc_ddr_sink`) |
| `0x6000_0000` | 64 MiB | **clearance** — and the old v3 window |
| `0x6400_0000` | 192 MiB | guest code and data |

Why the sink is 256 MiB and not 64: measured at 29.7 MB/s a 64 MiB window
wraps every **2.3 s**, a 256 MiB window every **9.0 s**
(`ctrace_resmem.dtso:18-20`). Why the 64 MiB clearance exists: before v4 the
sink and the guest window abutted with zero bytes of margin
(`rocket2_soc_top.sv:441-448`).

Why the guest window is 192 MiB and not 128: the CVA6 is meant to boot
Linux, and OpenSBI + kernel + an unpacked initramfs do not fit into 64 MiB
(`ctrace_resmem.dtso:46-49`).

**Address plan v3 is still in the field.** Some boards carry the older
overlay (`ctrace-pl-ddr@60000000`, 256 MiB). Board scripts must therefore
**not** hard-wire the node name: they read every `ctrace-pl-ddr@*` node from
the live device tree and demand that *one* of them covers the range the
example needs. `cva6_linux_boot_trace.sh:163-184` is the reference
implementation of that check. The live device tree is the only source —
`no-map` regions never appear in `/proc/iomem`.

---

## 2. Guest-side views differ from the PS view

A core does not necessarily see its memory at the PS address. Three cases
exist in this tree:

| Design | Guest sees | PS address | Source |
|---|---|---|---|
| CVA6 single-core (`cva6_linux`, `cva6_linux64`) | `0x6400_0000` | `0x6400_0000` | identity — `cva6_kv260_rv64.dts:108` |
| Rocket (`rocket_linux`, `rocket2`) | `0x8000_0000` | `0x6400_0000` | `rocket_mem_window.sv:12-21` |
| CVA6 AMP (`cva6_2`) | `0x6400_0000` **per core** | core 0 `0x6400_0000`, core 1 `0x6600_0000` | `cva6_2_soc_top.sv:78,147` (`PS_DRAM1`) |

The Rocket case is not a preference: the Rocket's bootrom jumps to `_ram` =
`0x8000_0000`, materialized in ROM, and on the ZynqMP that PS address is
something else entirely — so the window translates instead of relocating the
guest (`rocket_mem_window.sv:17-22`).

The AMP case is the reason `cva6_2` needs **two** windows: the two cv64a6
cores carry no coherence path, so one shared cached window would corrupt
silently. Each core gets its own 32 MiB window at the same core-side view,
plus one **uncached** mailbox outside the cached region
(`cva6_2_soc_top.sv:18-45`).

---

## 3. The AXI4-Lite aperture

All KV260 designs present the same control aperture at PS `0xA000_0000`.
Offsets (from `cva6_linux_soc_top.sv:24-31`, `rocket2_soc_top.sv:44-48`,
`trio_soc_top.sv:50-62`, `cva6_2_soc_top.sv:70-80`):

| Offset | Region | Present in |
|---|---|---|
| `0x00_0000` | `CTRL` — run/stop, clears, counters, sink and funnel control | all |
| `0x01_0000` | `ENC0` — CTTE CSRs, first encoder | all |
| `0x02_0000` | `ENC1` — second encoder | `duo`, `trio`, `rocket2`, `cva6_2` |
| `0x03_0000` | `ENC2` — third encoder | `trio` |
| `0x08_0000` | `RAM1` — TGC5B program/data RAM, 64 KiB | `duo`, `trio` |
| `0x10_0000` | `RAM0` — MicroBlaze V program/data RAM, 128 KiB | `duo`, `trio`, `mbv` |
| `0x20_0000` | `TRACE` — merged trace ring, 1 MiB URAM | all |
| `0x30_0000` | `CON` — guest console ring / AXIS capture | all |

Two rules that cost real boards when broken:

1. **Never touch the aperture unless your app occupies the active slot.** An
   access with no slave behind it wedges the AXI interconnect
   (`deploy_kv260_app.sh:16-20`). `xmutil listapps`' slot column decides
   that, not the `fpga_manager` state.
2. **A core's RAM may only be written while that core is held in reset.** An
   access to a running core's RAM never gets `ready` and hangs the
   transaction (`trio_soc_top.sv:69-71`).

---

## 4. PS ports and their widths

`psu_init` — which would configure the AFIFM port widths — does **not** run
for a DFX app, so the widths sit at their 128-bit reset value until a board
script sets them. Each port has a read control and a write control register.

| Port | AFIFM | Register base | Width | Carries |
|---|---|---|---|---|
| `saxigp2` | AFIFM2 | `0xFD38_0000` / `…0014` | **32 bit** | trace sink (write-only) |
| `saxigp3` | AFIFM3 | `0xFD39_0000` / `…0014` | **64 bit** | guest memory (core 0) |
| `saxigp4` | AFIFM4 | `0xFD3A_0000` / `…0014` | **64 bit** | guest memory of the **second** core — `cva6_2` only |

Both entries in this table were learned the expensive way, and both failure
modes are silent:

* **Wrong port, right idea (2026-08-19).** An early script wrote
  `0xFD36_xxxx`/`0xFD37_xxxx` and called them "HP0/HP1". Those are AFIFM0/1
  = HPC0/HPC1, which these bitstreams do not even enable. The cost was not
  an error message: the trace sink then writes 32-bit beats into a port
  presenting 128 bit, one word lands per 16-byte slot, and the capture is
  unreadable while every counter reads healthy with 0 drops
  (`cva6_2_run.sh:90-103`).
* **One port too few (2026-08-21).** Every recipe configured *two* ports,
  because every other design has one core and therefore one guest window.
  `cva6_2` has two cores with a private port each, and AFIFM4 was never
  touched. Core 1 then could not write **at all** — no store ever reached
  DDR, and the window guard reported nothing, because the accesses never got
  that far. Its read path was unaffected, so the core looked perfectly
  alive; the first operation that *waits* for an answer, OpenSBI's boot
  lottery `amoswap.w`, hung forever (`cva6_2_run.sh:86-115`).

---

## 4a. The PL clock, and one open inconsistency

`pl_clk0` comes from `PL0_REF_CTRL` (`0xFF5E_00C0`) and is set by the **boot**
firmware. An `xmutil` runtime overlay that only carries `firmware-name` does
not change it, so a freshly loaded design runs at whatever the boot firmware
left behind — measured on these boards: **100 MHz**, once 150 MHz. Every
KV260 design here is constrained against **71.114 MHz** (period 14.062 ns),
so "as found" is 40 % over the signed-off frequency.

`f = 1500 MHz / DIVISOR0` with an integer divider, so only a few values
exist. The three labels
[`common/board/kv260_plclk.sh`](common/board/kv260_plclk.sh) accepts:

| Label | Divider | Actual frequency |
|---|---|---|
| 100 | 15 | 100 000 000 Hz |
| 75 | 20 | 75 000 000 Hz |
| 68 | 22 | **68 181 818 Hz** — not 68 000 000 |

Every consumer must form the same integer division, or it fails on a
rounding instead of on an error.

**The clock may only be changed with the PL unloaded.** A frequency jump
under a running design is a clock glitch in the middle of the logic; no
state is trustworthy afterwards. `kv260_plclk.sh` refuses the change while an
app occupies the active slot, which is why the step belongs **between**
`xmutil unloadapp` and `xmutil loadapp`. Which label each scenario gets, and
the routed-timing evidence for it, is in
[`../dashboard/plclk.json`](../dashboard/plclk.json).

### The Rocket clock: an inconsistency, and how it was closed

Until 2026-08-21 the device tree and the board runner disagreed for the two
Rocket examples. The device tree declares
`clock-frequency = <75000000>` / `timebase-frequency = <750000>`
(`rocket_linux/sw/rocket_kv260_rv64.dts:104,118,187`, same in rocket2),
while `boot.json` had carried the 68 label since 2026-08-14. The guest
therefore reckoned time about **10 % fast** -- nothing crashed, every delay,
timeout and timestamp inside it was simply wrong by that factor, and
`timebase-frequency` is not free because the generat divides
`clock-frequency` by a fixed 100.

**Resolved by raising the runner to 75 MHz**, not by editing the device
tree. Two reasons, and one of them was a correction to the analysis:

* The slack permits it, by the criterion this repository already applies to
  `mbv`, `duo` and `tgc5b2_axis_wp`: 75 MHz costs 0.729 ns against the
  71.114 MHz constraint, and rocket64 has +2.114 ns of margin, rocket2
  +3.578 ns. The Rocket entries in `plclk.json` had used a stricter rule
  than its own mbv/duo entries.
* **The cost that was assumed does not exist.** The concern was that the
  recorded demo datasets under `dashboard/demo/` were captured at 68 MHz and
  would stop describing the running configuration. Measured instead of
  assumed: the PL clock **does not touch the decoded trace at all**. A duo
  run at 75 MHz and one at 68 produce identical PC sequences over all
  720 238 decoded core-1 PCs, and both Rocket captures decode to exactly the
  same instruction count at either clock against the pinned pcinfo --
  5 414 841 for rocket64 and 7 770 406 for rocket2. What the clock changes is
  wall-clock time inside the guest, which is precisely the thing that was
  wrong.

Verified on the board on 2026-08-21 at 75 MHz: rocket64 boots to
`buildroot login:` with `WIN_ERR_CNT 0`; rocket2 reports
`M5_TWOHART_HW PASS` with both harts retiring, 0 drops and
`WIN_ERR_CNT 0`, and likewise reaches the login prompt.

**`cva6_linux64` deliberately stays at 68.** Its margin is +0.603 ns --
*less* than the 0.729 ns that 75 MHz costs. There the label is not a
preference but the only one available, and the same holds for `trio`
(+0.215 ns) and both `cva6_2` configurations.

## 5. The correspondence rule

The reset values of `DDR_BASE`/`DDR_SIZE` in the RTL and the
`reserved-memory` node in `ctrace_resmem.dtso` describe the same window.
**They must agree**, and a mismatch is not caught by any build step — the
sink would simply write into memory the kernel also uses.

Where a bitstream predates a change to the plan, the board runner restores
the values at runtime **and checks them against the live device tree in
every case** (`rocket2_soc_top.sv:449-453`). That check is the safety net;
the reset values are the intent.

A header comment that contradicts its own reset values is worse than no
header at all — `rocket2_kv260_top.sv` carried the v3 numbers until
2026-08-21 while its RTL had long since reset to v4.

---

## 6. Reading and writing the window from the PS

Only `mmap` works. For `no-map` reserved ranges and for the AXI-Lite
aperture the `read()`/`write()` path of `/dev/mem` answers **"Bad address"**
— there is no kernel mapping for it (`phys_io.py:10-15`, measured
2026-07-27). `dd` therefore cannot be used.

And within an `mmap`, **access width matters**: a glibc `memcpy` — which is
what an mmap slice assignment compiles to — uses NEON and unaligned stores,
and those SIGBUS on a Device-nGnRnE mapping. Both tools in this tree
therefore write strictly 32 bits at a time through `ctypes`:

* [`phys_io.py`](common/board/phys_io.py) — read and write
* [`mem_load.py`](common/board/mem_load.py) — write with verify

`mem_load.py` used a slice copy until 2026-08-21 and died with SIGBUS at
exactly 16 MiB. The caller swallowed the signal, its probe read the *first*
word of the window — written, therefore non-zero — and the guest booted far
enough to print a plausible kernel log with the tail of the image missing.
A payload of 17.7 MB never reached userspace. Nothing in the test suite
would have gone red.
