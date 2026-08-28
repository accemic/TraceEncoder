<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Tutorial — building the KV260 demos

Two ways to get a running demo, and both are supported:

* **A — take the prebuilt bitstream (fast).** Every demo carries its packaged,
  ready-to-load app **in the repository**, under
  `examples/kv260/<demo>/fpga/prebuilt/<app>/` — `.bit.bin`, device-tree
  overlay, `shell.json`, and a `MANIFEST.sha256` that verifies the set. No
  Vivado, no licence, no network beyond the clone, minutes instead of hours:

  ```bash
  cd examples/kv260/<demo>/fpga/prebuilt/<app> && sha256sum -c MANIFEST.sha256
  bash examples/kv260/common/board/deploy_kv260_app.sh \
       --app-dir examples/kv260/<demo>/fpga/prebuilt/<app> \
       --board <board-ip> [--jump <host>]
  ```

  Each `fpga/prebuilt/README.md` states that demo's provenance. The in-repo
  copies of the nine series demos are the deterministic, board-gated bundles
  of the `v1.0.1-demo2` series, extracted verbatim (see the note below).
* **B — build it yourself.** Run the example's Vivado flow, package the result,
  deploy it. Same artefacts, produced on your machine.

Path B is the one this tutorial documents in full detail, because a demo you
cannot rebuild is a demo you cannot trust. Path A exists so you can see the
thing work first.

Every command below is written to be run **from the repository root** unless a
line says otherwise, and every one of them has been executed — the "verified"
column in [§4](#4-the-build-matrix) says when, and with which result.

> **State 2026-08-18:** all nine examples build, and all nine were packaged as
> one deterministic, board-gated bundle series (`v1.0.1-demo2`; the series
> record with the sha256 per bundle is `scripts/demo.pin`).
> **2026-08-26:** those bundles live in-tree under each demo's
> `fpga/prebuilt/` (path A above), together with the RV/CFI demo
> (`tgc5b2_rvcfi`, board-verified the same day) and the post-series
> `cva6_2` RV64 variant. Nothing is fetched.

---

## 1. What you need

| Need | Version used here | Notes |
|---|---|---|
| Vivado | **2026.1** (`C:\Xilinx\2026.1\Vivado\bin`) | 2025.2 works for the pure-RTL examples; the `mbv`/`duo`/`trio` block design is generated against 2026.1 |
| Python | 3.13, invoked as `py` on Windows, `python3` on Linux | stdlib only — no packages to install |
| Bash | Git Bash (Windows) or any POSIX shell | the board drivers are Bash since the R1 port |
| CTTD (the decoder) | fetched, pinned by sha256 | `py scripts/fetch_cttd.py` — see §2 |
| KV260 board | Ubuntu image with `xmutil` | only for the board legs (§6); everything else runs off-board |
| GNU make | any | drives the simulation legs of §4.2 |
| `abc` (abc-flow) | latest | the build/simulation driver every `make sim-*` target calls — [github.com/accemic/abc-flow](https://github.com/accemic/abc-flow). Without it `make sim-examples` stops immediately with `ct_env: ... abc` |
| Verilator | 5.x (5.040 here) | the simulator those legs run on; no Vivado needed for them |

Some examples additionally need a reference core that this repository does not
vendor:

```bash
bash examples/kv260/third_party/fetch.sh          # CVA6 (cva6_linux*, cva6_2, trio)
```

**Rocket needs a generated blob, and it is in the tree.** `rocket_linux` and
`rocket2` are built around `system-nexys-video.v` (~8.8 MB per variant), the
FIRRTL output of the vivado-risc-v flow around rocket-chip. It is **not**
fetched like CVA6 and it cannot be regenerated from this repository — the
recipe in [`third_party/ROCKET_PIN.md`](third_party/ROCKET_PIN.md) needs four
patches that live upstream and a Linux sbt/FIRRTL toolchain. It is therefore
**committed** at `examples/kv260/third_party/rocket_ref/`, with the upstream
licence texts beside it (BSD-3-Clause, Apache-2.0, MIT, chisel-jtag).

> Committed on 2026-08-19 for exactly one reason: until then these two
> examples could not be built by anyone who did not already have the file,
> while this matrix said they build with one command. Now they do.

**The four RV64 examples need an encoder mirror first.** `cva6_2`, `rocket2`,
`cva6_linux64` and `rocket_linux` do not build against the repository's own
`rtl/` — that tree is RV32 and is shared with the other five examples. They
build against a *mirror* under `bld/`: a copy of `rtl/` (plus `rdl/` when a
profile is involved) with `ct_pkg::CT_XLEN` and, where required, a slim build
profile set. `CT_XLEN` is a `localparam`, not a `` `define ``: the address width
is a synthesis parameter of the netlist, so it cannot be a switch, and since
2026-08-12 `ct_encoder` *refuses* a core/encoder width mismatch during
elaboration instead of quietly truncating addresses. Build the mirrors once —
they take seconds, and re-running is a no-op unless the tree moved:

```bash
# cva6_linux64 + rocket_linux  (tree profile, 64-bit)
bash examples/kv260/common/tools/mk_encoder_mirror.sh \
     --dest bld/w1_rv64_decode/ctte_xlen64 --xlen 64
# rocket2 + cva6_2's RV64 variant  (slim profile, 64-bit, 22-bit context)
bash examples/kv260/common/tools/mk_encoder_mirror.sh \
     --dest bld/m4_rocket_2hart/ctte_slim64 \
     --profile slimfull_gold --xlen 64 --ctx-width 22
# cva6_2's RV32 variant (the one the build matrix below uses)
bash examples/kv260/common/tools/mk_encoder_mirror.sh \
     --dest bld/d3_cva6_2_soc/ctte_slim32 \
     --profile slimfull_gold --xlen 32 --ctx-width 22
```

The tool only ever *reads* the working tree and writes nothing outside
`--dest`; it prints the button state it read back out of the copy, and leaves a
provenance file (source commit, `ct_pkg` hash) that every build flow prints into
its log. Two mirrors carry the slim profile because those two designs hold *two*
encoders each: the full profile costs 25 743 LUT per encoder against 4 653 for
`slimfull_gold`, and two full ones plus two cores do not fit the xck26.

## 2. First: get the decoder

Nothing downstream means anything without it — the decoder is what turns
captured trace bytes back into a PC sequence, and it is what every gate below
compares against.

```bash
py scripts/fetch_cttd.py            # downloads the pinned build into bin/, verifies sha256
py scripts/fetch_cttd.py --check    # re-verify later without downloading
```

The decoder is [CEDARtools.TraceDecoder (CTTD)](https://github.com/accemic/CTTD);
the pin in [`scripts/cttd.pin`](../../scripts/cttd.pin) names the release the
build is fetched from and its sha256 per platform. A mismatching hash is a hard
error, never a warning: decoding with an unknown binary would make every
verdict below meaningless.

## 3. Path A — run a demo without building it

Every demo carries its packaged app in the checkout, under
`examples/kv260/<demo>/fpga/prebuilt/<app>/`: the packaged bitstream
(`*.bit.bin`), the device-tree overlay, `shell.json` and a per-file
`MANIFEST.sha256`. Nothing is fetched. Verify a set before first use:

```bash
cd examples/kv260/mbv/fpga/prebuilt/mbv_ctrace_kv260 && sha256sum -c MANIFEST.sha256
```

The app name is not the example directory name (`mbv_ctrace_kv260`, not
`mbv`); each `fpga/prebuilt/README.md` names its app and states its
provenance. The apps were extracted verbatim from the deterministic bundle
series recorded in [`scripts/demo.pin`](../../scripts/demo.pin) (series tag +
sha256 per bundle tarball). Deploy the app directory with the same script the
build path uses — continue at [§6](#6-deploying-to-the-board).

> Linux-payload demos (`cva6_linux*`, `rocket*`) additionally need a **one-time
> board setup**: the soft core boots out of a reserved PS-DDR window that only
> the boot device tree can carve out. The bundle ships `ctrace_resmem.dtso` and
> a `BOARD_SETUP.txt` next to it; apply it once per board, then reboot.

## 4. The build matrix

Every example builds with **one** command. They differ in shape because they
grew at different times — the table is the authority, not the pattern:

| Example | Build command (from repo root) | Bitstream lands in | Verified |
|---|---|---|---|
| `mbv` | `MBV_KV260_SYNTH=1 vivado -mode batch -source examples/kv260/mbv/fpga/create_project_kv260.tcl` | `examples/kv260/mbv/fpga/proj/mbv_kv260.runs/impl_1/mbv_kv260_top.bit` | see §4.1 |
| `duo` | `DUO_KV260_SYNTH=1 vivado -mode batch -source examples/kv260/duo/fpga/create_project_kv260.tcl` | `examples/kv260/duo/fpga/proj/duo_kv260.runs/impl_1/duo_kv260_top.bit` | see §4.1 |
| `trio` | `TRIO_KV260_SYNTH=1 vivado -mode batch -source examples/kv260/trio/fpga/create_project_kv260.tcl` | `examples/kv260/trio/fpga/proj/…/impl_1/…_top.bit` | see §4.1 |
| `tgc5b2_axis_wp` | `vivado -mode batch -notrace -source examples/kv260/tgc5b2_axis_wp/fpga/create_project.tcl` then `… -source …/fpga/run_bitstream.tcl` | `examples/kv260/tgc5b2_axis_wp/fpga/proj/tgc5b2_axis_wp.runs/impl_1/tgc5b2_kv260_top.bit` | see §4.1 |
| `cva6_linux` | `vivado -mode batch -notrace -source examples/kv260/cva6_linux/fpga/run_cva6_linux_bitstream.tcl` | `examples/kv260/cva6_linux/fpga/proj_linux/cva6_linux_kv260.runs/impl_1/cva6_linux_kv260_top.bit` | see §4.1 |
| `cva6_linux64` | `vivado -mode batch -notrace -source examples/kv260/cva6_linux64/fpga/run_cva6_linux64_bitstream.tcl -tclargs 64` | `examples/kv260/cva6_linux64/fpga/…/impl_1/…_top.bit` | see §4.1 |
| `cva6_2` | `vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/run_cva6_2_bitstream.tcl -tclargs cv32a6_ima_sv32_fpga` | `examples/kv260/cva6_2/fpga/…/impl_1/…_top.bit` | see §4.1 |
| `rocket_linux` | `vivado -mode batch -notrace -source examples/kv260/rocket_linux/fpga/run_rocket_bitstream.tcl -tclargs 0 64` | `examples/kv260/rocket_linux/fpga/…/impl_1/…_top.bit` | see §4.1 |
| `rocket2` | `vivado -mode batch -notrace -source examples/kv260/rocket2/fpga/run_rocket2_bitstream.tcl` | `examples/kv260/rocket2/fpga/…/impl_1/…_top.bit` | see §4.1 |

All nine rows build from a fresh clone plus the CVA6 fetch (`third_party/fetch.sh`).
The Rocket generator output needed for the last two is committed — see §1.


If you want all of them, there is a queue that runs the same commands one after
another and judges each by its **artefact** rather than by Vivado's exit code:

```bash
bash examples/kv260/build_all_demos.sh              # everything, serially
bash examples/kv260/build_all_demos.sh mbv duo      # a subset
PACKAGE=1 BUNDLE_VERSION=v1.0.1 bash examples/kv260/build_all_demos.sh mbv
```

It gives every run its own log under `bld/demo_builds/`, never starts two Vivado
sessions at once, and prints a summary table at the end. It does not replace the
per-example entry points above — it calls exactly them, with one exception you
have to know about: for `tgc5b2_axis_wp` the queue runs only the **second** step
(`run_bitstream.tcl`). That step refuses to run without an existing project
(`### ERROR: project missing … (run create_project.tcl first)`), so on a fresh
clone create it once first:

```bash
vivado -mode batch -notrace -source examples/kv260/tgc5b2_axis_wp/fpga/create_project.tcl
```

`PACKAGE=1` calls the packaging step through the Windows launcher `py`. On a
host where that launcher does not exist (Linux), build with the queue and run
[§5](#5-packaging-a-build-into-a-loadable-app) by hand with `python3`.

Without the `*_SYNTH=1` variable the `mbv`/`duo`/`trio` entry points stop after
`synth_design -rtl` — that is the **elaboration gate**: it proves the RTL and the
block design fit together, in a couple of minutes instead of an hour, and it is
the right thing to run after editing RTL.

### 4.1 Verification log

This section carries the actual runs (date, host, result). It is filled by the
person who ran them; an empty row means *not verified here*, not *broken*.

| Example | Run at | Result |
|---|---|---|
| `tgc5b2_axis_wp` (project) | 2026-08-18 11:20 WEDT, Vivado 2026.1 | exit 0 |
| `tgc5b2_axis_wp` (bitstream, 1st) | 2026-08-18 11:20 WEDT | **FAILED** — synthesis crashed after 23 min (`EXCEPTION_ACCESS_VIOLATION`), `vivado` still exited 0; cause: multi-threaded synthesis, see §9 |
| `tgc5b2_axis_wp` (bitstream, 2nd) | 2026-08-18 11:23–12:36 WEDT | **PASS** with `maxThreads 1` — `### BITSTREAM_DONE`, timing WNS **+1.575 ns**, bitstream 7 797 907 bytes |
| `mbv` (full bitstream) | 2026-08-18 12:39–13:07 WEDT | **PASS** — `### BITSTREAM_OK`, timing WNS **+2.331 ns**, 7 797 904 bytes. First build after the sink rework, so it also proves the two new outside edges (`S_AXI_HP0_FPD`, PIB pins) place and route |
| `mbv` (elaboration gate) | 2026-08-18 11:34 WEDT | **inconclusive** — the project was created (11:36) but the run left no log and no verdict while a second Vivado batch run was active in the same directory; both write `vivado.log` in the repository root. Repeat it alone, or give each run its own `-log`/`-journal` path |
| `duo` | 2026-08-18 13:09–14:0x WEDT | **PASS** — 7 797 904 bytes |
| `cva6_linux` | 2026-08-18 15:0x WEDT | **PASS** — 7 797 911 bytes |
| `cva6_linux64` | 2026-08-18 17:5x WEDT | **PASS** — needed the RV64 encoder mirror (`bld/w1_rv64_decode/ctte_xlen64`), which did not exist before today |
| `trio` | 2026-08-18 18:29 WEDT | **PASS** — `### BITSTREAM_OK`, timing WNS **+0.215 ns**, 7 797 905 bytes. Needed two fixes: the `cva6_ref` path and a build-local `CT_EN_ETRACE=1` profile (the shared package has E-Trace off) |
| `cva6_2` | 2026-08-18 20:5x WEDT | **PASS** — `### BITSTREAM_OK`; needed the RV64 mirror `bld/m4_rocket_2hart/ctte_slim64` |
| `rocket2` | 2026-08-18 20:5x WEDT | **PASS** — timing WNS **+2.399 ns**; same mirror |
| `rocket_linux` | 2026-08-18 21:0x WEDT | **PASS** — timing WNS **+2.114 ns**; needed the boot-ROM tool, the Rocket generat AND the RV64 mirror |

## 4.2 Simulating before you build

A bitstream takes an hour; a simulation takes seconds to minutes and catches the
things that would otherwise cost you that hour. Six legs run without Vivado, on
Verilator, straight from the repository root:

```bash
make sim-examples            # all of them, with a PASS/FAIL table at the end
make sim-ddr-sink-window     # DDR window guard              ~11 s
make sim-axis-wp-shim        # AXIS shim, FIFO depth 256+16  ~19 s
make sim-tgc5b2-axis-soc     # watchpoint chain, full oracle ~15 min
make sim-ctte-smoke        # encoder probe                 ~100 s
make sim-tgc5b-soc           # the shared common/tgc5b SoC
```

Measured 2026-08-18: `make sim-examples` → **6/6 PASS** in 214 s — with the
Verilator models already built. The first run in a fresh tree also compiles
them: re-measured 2026-08-19 on this host, **6/6 PASS** in about 10 minutes,
most of it `g++`.

If a Verilator build dies with `cc1plus: out of memory`, it is the host, not the
design — Verilator compiles with one job per core. Cap it:

```bash
ABC_VERILATOR_EXTRA_ARGS="--build-jobs 4" make sim-examples
```

**What does not simulate here, and why.** Eight further testbenches of the `mbv`,
`duo` and `trio` examples (SoC and end-to-end level, including the devmem chains)
need the Vivado block design around the encrypted MicroBlaze-V core
(`mbv_ctrace_soc_wrapper`, `xpm_memory_tdpram`); those are not source files in
this repository. They are shipped, documented in each example's `sim/README.md`,
and elaborate cleanly against throw-away stubs — but they are **not** wired into
`make sim-examples`, because a target that can never resolve is a trap, not a
test.

## 5. Packaging a build into a loadable app

Vivado gives you a `.bit`; the Kria fpga-manager wants a `.bit.bin` plus a
device-tree overlay. One script does both:

```bash
py examples/kv260/common/board/package_kv260_app.py \
    --bit examples/kv260/mbv/fpga/proj/mbv_kv260.runs/impl_1/mbv_kv260_top.bit \
    --app mbv_ctrace_kv260
```

It writes `<bit dir>/app_pkg/<app>/` containing `<app>.bit.bin` (via `bootgen`),
`<app>.dtso`, `shell.json` and `MANIFEST.sha256`. `bootgen` is taken from
`--vivado-bin`, whose default is the Windows install path from the table in
[§1](#1-what-you-need) — on Linux pass your own, e.g.
`--vivado-bin /tools/Xilinx/2026.1/Vivado/bin`. Add `--bundle --version vX` to
also produce the deterministic tarball whose sha256 a series record like
`scripts/demo.pin` carries — that determinism is what makes a recorded
checksum worth anything.

The `.dtbo` is deliberately **not** built here: `dtc` lives on the board, and the
deploy script compiles it there.

## 6. Deploying to the board

```bash
bash examples/kv260/common/board/deploy_kv260_app.sh --app-dir <printed app-dir> --board <ip>
```

Three traps are documented at length in [`README.md`](README.md) and they cost
real board-hours the first time each was hit — read them before your first
deploy:

1. `scp -r` onto an existing directory nests instead of overwriting, and the
   deploy still reports success.
2. Touching the PL aperture `0xA000_0000` while your app does *not* own the slot
   wedges the AXI bus — hard power cycle only.
3. `fpga_manager` state says `operating` even with no app loaded; only
   `xmutil listapps` tells you the truth.

## 7. Running the demo and checking it

Each example ships its own board driver under `<example>/board/`, with its own
README. They all end in the same place: captured trace, decoded with CTTD,
compared against an oracle.

| Example | Driver | Verdict it prints |
|---|---|---|
| `mbv` | `mbv/board/mbv_board_gate.sh` | `MBV_BOARD_GATE PASS <n>/<n>` |
| `duo` | `duo/board/duo_board_gate.sh` | `DUO_BOARD PASS` (both cores) |
| `cva6_linux` | `cva6_linux/board/cva6_linux_boot_trace.sh` | `Decoded OK (<n> instructions)` |
| `tgc5b2_axis_wp` | `tgc5b2_axis_wp/board/wp_board_gate.sh` | per-phase, `G1CHECK … PASS` |

Every driver documents its own options in its header — read that first, because
the defaults are this lab's and not yours. The shortest one, for example:

```bash
bash examples/kv260/mbv/board/mbv_board_gate.sh \
     --bit examples/kv260/mbv/fpga/proj/mbv_kv260.runs/impl_1/mbv_kv260_top.bit \
     --board <board-ip> --jump <ssh-host-that-reaches-the-board> \
     --sudo-pass <board-sudo-password>
```

`--bit` is the only option the script *enforces*, but `--board` and `--jump`
are just as necessary: both default to empty (`$KV260_BOARD`, `$KV260_JUMP`)
and are not validated, so leaving them out fails inside `ssh` rather than with
a message. `--sudo-pass` likewise reads `$KV260_SUDO_PASS`. The transport is
workstation → jump host → board, because the board this was developed on only
accepts ssh from the jump host; `--jump` therefore has to name a host that can
`ssh` to the board. The oracle defaults to the committed reference under
`<example>/board/refs/`, so you do not have to build the test program first.

### 7.1 Booting a Linux guest from the dashboard

The Linux and AMP demos differ from the small ones in one respect: the soft
core has nothing to run until a **payload** (OpenSBI + kernel, a single
`fw_payload*.bin`) has been written into the reserved PS-DDR window. The
dashboard can do that for you — but only for scenarios that have a recipe in
[`../dashboard/boot.json`](../dashboard/boot.json), and only once the board
carries the three pieces below.

**Once per board.** Apply `ctrace_resmem.dtso` and reboot (see the note in
[§3](#3-path-a--run-a-demo-without-building-it)); without the reservation the
guest window belongs to the host kernel and the recipes refuse to write into
it.

**Then check that it took** — this is not ceremony. A board that carries an
*older* reservation boots fine, runs the guests fine, and silently cannot arm
the DDR sink, because the sink's window then lies outside the reserved range.
Nothing announces that; the sink simply stays off:

```bash
# on the board
ls /sys/firmware/devicetree/base/reserved-memory/
```

Expected: a node named `ctrace-pl-ddr@50000000`. The designs reset their sink
window to `0x5000_0000 +256 MiB` and place the guests at `0x6400_0000
+192 MiB`, so the reservation has to cover `0x5000_0000 +512 MiB` — that is
exactly what `ctrace_resmem.dtso` carves out.

Seen on a lab board on 2026-08-19: the node was `ctrace-pl-ddr@60000000`
(256 MiB), left over from the address plan before v4. Guests worked, every
demo ran, and the DDR sink could not be armed — `ddr_window_ok()` in the
dashboard refused it, correctly and without drama. If you see a node whose
address is not `@50000000`, the overlay on that board predates the current
address plan; re-apply it.

Then install the dashboard service, which also stages the two board tools
the recipes need (`phys_io.py`, `kv260_plclk.sh`):

```bash
# on the board
sudo bash board_dashboard_install.sh <app-name> 8099
```

**Once per payload.** Copy the payload to the path the recipe expects — the
`PAYLOAD` value in `boot.json`, one per scenario:

```bash
# from the machine that built it, e.g. for the CVA6 RV64 demo
scp fw_payload64.bin ubuntu@<board-ip>:/tmp/fw_payload64.bin
```

The recipes live with the dashboard, not with the examples — `boot/` below
is `examples/dashboard/boot/`, and `ls boot/` from this directory finds
nothing:

| Scenario | Recipe | `PAYLOAD` on the board |
|---|---|---|
| `cva6_linux64` | `examples/dashboard/boot/cva6_linux64_run.sh` | `/tmp/fw_payload64.bin` |
| `rocket64` | `examples/dashboard/boot/rocket_linux64_run.sh` | `/tmp/fw_payload_rocket.bin` |
| `rocket2` | `examples/dashboard/boot/rocket2_linux_run.sh` | `/tmp/fw_payload_rocket2.bin` |

The payload itself is built outside this repository (a Buildroot/OpenSBI host).
What goes into it is described per example: `cva6_linux64/sw/README.md`, and for
the two Rocket scenarios the example's own `README.md` plus the build script
next to it (`rocket_linux/sw/build_payload_rocket_rv64.sh`,
`rocket2/sw/build_payload_rocket2_rv64.sh`).

**Every time.** Open the dashboard, pick the scenario, press **Run**. Where a
recipe exists, Run does not merely release the core — it asks first and then
runs the whole sequence, because a guest that has already booted has modified
its own image and cannot be restarted by releasing the core again:

1. `prep` — writes the payload into the window and **reads it back**, comparing
   the md5 against the file. A mismatch aborts here; no phase after a failed
   one is run.
2. `start` — releases the core, records a trace window, reports bytes, console
   bytes and status.
3. `live` — switches to continuous operation so the view keeps showing traffic.

The PL clock is handled for you: the server programs `pl_clk0` between
`xmutil unloadapp` and `xmutil loadapp` (the only point at which a PL clock may
change) to the label the scenario needs, taken from
[`../dashboard/plclk.json`](../dashboard/plclk.json). If the app is already in
the slot, it is **not** reloaded just to change the clock — the load result
then names the mismatch and asks for a manual `xmutil unloadapp` instead. A
recipe whose clock is wrong stops in `prep` with `PLCLK_WRONG` rather than
running a design faster than the frequency it was signed off at.

Progress and every line the board prints appear in the dashboard's boot log
while the sequence runs (it takes about a minute, most of it the payload
write and read-back).

## 8. Seeing it without any board at all

The dashboard replays recorded board sessions:

```bash
cd examples/dashboard
py server.py --demo --port 8142
```

Then open <http://127.0.0.1:8142/> and pick a scenario. Which scenarios carry
their own recording (and which currently fall back to a generic stream) is
listed in [`../dashboard/README.md`](../dashboard/README.md).

## 9. Two Vivado traps that cost real hours here

**A run can fail while `vivado` exits 0.** `launch_runs` + `wait_on_run` return
normally even when the run died; the only reliable signal is the run's
`PROGRESS` property, which is why every flow in this tree checks it:

```tcl
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
```

If you wrap a build in your own script, check the same thing — a shell that
trusts the exit code will report a green build over a crashed synthesis.

**Do not run two Vivado batch sessions in the same directory.** Both write
`vivado.log` and `vivado.jou` in the current working directory, and the second
one can end without a log and without a verdict — which looks exactly like a
run that never started. Give each run its own `-log`/`-journal` path (absolute,
with forward slashes), or run them one after another.

**Multi-threaded synthesis crashes Vivado 2026.1 on these designs.** Measured
here on 2026-08-18: the watchpoint example died after 23 minutes in *Cross
Boundary and Area Optimization* with `EXCEPTION_ACCESS_VIOLATION` (a JVM crash
dump lands in the run directory as `hs_err_pid*.log`) — no RTL error involved.
Every flow now sets

```tcl
set_param general.maxThreads 1
```

before launching synthesis. If you build one of these designs from your own
script, set it too.

## 10. If something fails

* **`extract_tlrom.py` not found** (rocket examples) — the tool lives in
  `examples/kv260/common/tools/`; older documentation pointed at a `sim/`
  directory that was never migrated. Fixed 2026-08-18.
* **Vivado cannot create a directory named `C`** — a Windows path was passed
  through a shell that rewrote it. Use forward slashes and quote, or run the
  command from `cmd.exe`.
* **Decoder verdict is `Cttd ERROR:`** — check that the `pcinfo` belongs to the
  program that actually ran. A trace and a `pcinfo` from different builds decode
  into plausible nonsense.
* **`fetch_cttd.py` reports a checksum mismatch on a fresh download** — check
  *what* was downloaded before suspecting a corrupt release. A host that will
  not serve the asset (a wrong `base_url` or `version` in the pin, a release
  that does not carry the asset) often answers `200` with an HTML page; the
  script recognises that and says so instead of reporting a checksum mismatch.
  The pin names the host and path ([`scripts/cttd.pin`](../../scripts/cttd.pin));
  open that URL in a browser and read what comes back.
