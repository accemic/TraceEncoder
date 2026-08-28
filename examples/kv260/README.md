<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# KV260 example baukasten

This directory holds the KV260 board-integration examples. They were
migrated here on 2026-08-17 from an internal predecessor repository; the
migration plan and its closing report are not part of this repository, so
what mattered from them is written down where it belongs -- in this file and
in each example's own `README.md`.

**Start here if you want to run one of these:**
[`TUTORIAL_build_demos.md`](TUTORIAL_build_demos.md) walks both paths command by
command — take a published bitstream bundle (no Vivado), or build any of the
nine examples yourself — and ends at the board gates and the dashboard.

## `common/` — cross-example trace-sinks RTL

`common/` holds the SystemVerilog that is genuinely shared by more than one
board example (verified by grepping which top-level SoC instantiates which
module, not from a list):

| Module | File | Role |
|---|---|---|
| `ct_axis_wp_shim` | `ct_axis_wp_shim.sv` | Encoder AXIS (96-bit, no backpressure) → 32-bit AXIS shim with drop accounting, for the watchpoint/DAQ export path |
| `ct_trace_sinks` | `ct_trace_sinks.sv` | The common three-sink trace subsystem: bundles the ring, the DDR4 sink and the PIB behind ONE ATB beat input and ONE CTRL register window — identical layout for every board design (T2 consolidation) |
| `ct_soc_trace_ring` | `ct_soc_trace_ring.sv` | 1-MiB URAM ring capture buffer (primary sink inside `ct_trace_sinks`, always-ready, ring or one-shot). **Renamed** from `ct_soc_trace_buf` on migration — see "Naming" below |
| `ct_soc_ddr_sink` | `ct_soc_ddr_sink.sv` | PS-DDR4 writer (AXI4 write-only master, additive observer, own FIFO + drop counting, never back-pressures the trace path) |
| `ct_soc_pib` | `ct_soc_pib.sv` | Parallel off-chip trace port (4-bit DDR, KR260-PMOD-adapter-compatible), additive observer like the DDR sink |

`common/sim/` holds the bench for that shared RTL that is not tied to one
example: `tb_ddr_sink_window.sv`, the window guard of `ct_soc_ddr_sink`
(`make sim-ddr-sink-window`, see "Simulation legs" below).

Everything else that used to live in the predecessor repository — the
per-example SoC tops, their `_periph`/`_mem_xbar` helpers, and the
`_synth_wrap` bitstream-top wrappers — is **not** in `common/`: each is
specific to exactly one example and is migrated together with that example's
own directory. `ct_axil_to_wb` and `ct_soc_axis_buf` are not duplicated here
either; both were measured functionally identical to the copies already in
`examples/kv260/common/tgc5b/rtl/` (comment-only deltas), so those two examples share
that pair straight from `common/tgc5b`: the two files were measured
byte-identical apart from doc comments, so a second copy would only be a
second thing to keep in sync.

### Naming: `ct_soc_trace_ring`, not `ct_soc_trace_buf`

`examples/kv260/common/tgc5b/rtl/ct_soc_trace_buf.sv` already exists — a small
(4096-beat) BRAM, fill-and-stop buffer. The board_kv260 module of the same
name was a *different* design (262144-beat / 1-MiB URAM ring with wrap,
one-shot mode, 64-bit-packed storage) — same name, unrelated implementation.
Rather than force one design to absorb the other, the migrated copy is
disambiguated as `ct_soc_trace_ring`. If your example needs the ring
capability (all the multi-core / high-rate examples below do, via
`ct_trace_sinks`), instantiate `ct_soc_trace_ring`; the smaller `common/tgc5b`
example keeps using its own, smaller `ct_soc_trace_buf`.

## The examples (all migrated 2026-08-17)

Every example directory carries its own `README.md`; the shared RTL lives in
`common/`, packaging/deploy/loader in `common/board/`, pinned reference cores
come via `third_party/fetch.sh`. What each one shows, and whether it has
been proven on real hardware from this tree:

| Example | What it shows | Board-gated from this tree |
|---|---|---|
| `mbv/` | MicroBlaze V, bare-metal programs, `mbv_soc_top` + Vivado flow, Bash board gate | 2026-08-17: `MBV_BOARD_GATE PASS 26772/26772`  |
| `cva6_linux/`, `cva6_linux64/` | CVA6, RV32/RV64 Linux via Buildroot; `board/cva6_linux_boot_trace.sh` | 2026-08-18: cva6_linux boots, `Decoded OK (4 619 090 instructions)`, 0 errors. 2026-08-21: cva6_linux64 `buildroot login:` + 4 246 697 instructions decoded (recipe `../dashboard/boot/cva6_linux64_run.sh`)  |
| `cva6_2/` | AMP double-CVA6 (RV32 + RV64 scenarios) | 2026-08-21: **both guests boot to `buildroot login:`** (544 507 540 / 542 494 739 retires, 22 389 B console, 0 drops, window guards 0). Cause of the earlier one-guest state: AFIFM4 (saxigp4, core 1's private PS port) sat at its 128-bit reset value -- see `board/cva6_2_run.sh`  |
| `rocket_linux/`, `rocket2/` | Rocket RV64, 2-hart SMP Linux | 2026-08-21: rocket_linux64 `buildroot login:` + 5 414 841 instructions decoded; rocket2 `M5_TWOHART_HW PASS`, both harts, + 7 770 406 decoded. Recipes: `../dashboard/boot/rocket*_run.sh`  |
| `duo/`, `trio/` | Multi-core funnel demos (duo: MBV+TGC5B; trio: +CVA6, per-instance protocol mix N-Trace/E-Trace) | duo 2026-08-18: `DUO_BOARD PASS` (both streams decoded); trio 2026-08-21: `DUO_BOARD PASS` via the same gate (`--app trio_ctrace_kv260 --pl-mhz 68`), both cores, 1 353 645 instructions -- the CVA6 stays stopped there, see `duo/board/refs/README.md`  |
| `tgc5b2_axis_wp/` | Watchpoint testbed, `board/wp_board_gate.sh` (7 phases) | 2026-08-18: `G1CHECK runa PASS` 851/851, merge 1702/0  |

Packaging lives in `common/board/`: `package_kv260_app.py` turns a
routed `.bit` into the loadable app (`bit.bin` via bootgen + `.dtso` from the
template + `shell.json` + sha256 manifest) and with `--bundle` into the
deterministic demo tarball whose sha256 the series record `scripts/demo.pin`
carries. The dtbo is
compiled ON the board (dtc lives there). sdcard/systemd install material is
still a later step.

## What each core's trace ingress can and cannot carry

Every example above traces a real core, but the four cores do **not** offer
the encoder the same ingress. The difference is invisible until a feature
that needs the data channel silently produces nothing, so it belongs here
rather than in a commit message. Measured by reading the adapters, not
inferred:

| Core | Adapter | Data channel (`dretire`/`dtype`/`daddr`/`sdata`) | CSR writes visible | ACT-ST (PC trigger) | ACT-CAP (CSR instrumentation) |
|---|---|---|---|---|---|
| MINRES TGC5B | [`common/tgc5b/rtl/ct_tip_adapter.sv`](common/tgc5b/rtl/ct_tip_adapter.sv) | **yes** — from the H2E port | no (see below) | yes | **only core where it is reachable** (see below) |
| CVA6 | [`../../rtl/adapters/cva6/cva6_iti_to_ctte_tip.sv`](../../rtl/adapters/cva6/cva6_iti_to_ctte_tip.sv) | **no** — `dretire` tied to 0 | no | yes | no |
| Rocket | [`../../rtl/adapters/rocket/rocket_tci_to_ctte_tip.sv`](../../rtl/adapters/rocket/rocket_tci_to_ctte_tip.sv) | **no** — `dretire` tied to 0 | no | yes | no |
| MicroBlaze V | [`../../rtl/adapters/amd_microblaze_v/mbv_to_ctte_tip.sv`](../../rtl/adapters/amd_microblaze_v/mbv_to_ctte_tip.sv) | **no** — `dretire` tied to 0 | no | yes | no |

**ACT-ST works everywhere** — it triggers on a retired instruction address
and needs nothing but `iaddr`.

**Everything that needs the data channel works on the TGC5B only**: data
trace, the DF range filter, and the `DAQ_DATA` / `DAQ_DADDR` /
`DAQ_DATA_DADDR` commands. On the other three cores those commands are not
"less precise", they produce **no useful payload at all**, because the
encoder never receives a data beat.

**And no core reports CSR writes**, which is what ACT-CAP decodes
(`dretire && dtype == CSR_READ_WRITE && daddr == 0x0B10`, see
[`../../rtl/preproc/ct_L23_preproc_act_cap.sv`](../../rtl/preproc/ct_L23_preproc_act_cap.sv)).
Two separate reasons, worth telling apart:

* The **TGC5B does decode** the vendor CSR window `0xB10-0xB9F` and raises
  no exception for it — the CSR arm only clears `illegalAccess`. But its
  H2E port derives `dtype` from the data bus alone (`0` = load, `1` =
  store), so the write never reaches the trace port. Since the adapter
  *does* see stores, an integration can close this locally: convert a store
  to a chosen doorbell address into the CSR beat the encoder expects. That
  is an adapter-level change, no core change.
* On **CVA6, Rocket and MicroBlaze V** there is no store beat to convert
  either, so no such local fix exists. For CVA6 specifically, RVFI is not
  an escape route: the wrapper ties its RVFI outputs off, and the CVA6 RVFI
  CSR structure is a fixed list of named architectural CSRs — it has no
  field for an arbitrary (address, value) pair and therefore cannot express
  a write to `0x0B10`.

ACT-CAP has consequently **never been exercised on silicon** in this
repository; its coverage comes from `tests/lib/cpu_model.sv`, which
synthesises the beat directly (scenario `sim-hsi-csr-cap`). Treat the first
hardware use as a bring-up step with its own verdict, not as a feature that
is known to work.

## Driving every example from the dashboard: walkthrough and soak

Two drivers exercise the demos through the board's dashboard service -- the
same API calls the buttons issue, not a second path built for testing:

| Script | Question it answers |
|---|---|
| `board_demo_walkthrough.sh` | Does each demo work once, end to end? Per scenario: load bitstream, verify slot ownership, check live mode, load program, run, watch counters, stop, read memory, decode -- one PASS/FAIL verdict each. |
| `board_demo_soak.sh` | Does it still work at the twentieth change of scenario? Repeats the demos in alternating order and checks after every step whether the board still answers; aborts immediately when it does not. |

Both need a reachable board and a jump host, and neither carries a default
for either -- they abort with a message if `KV260_BOARD` / `KV260_JUMP` are
unset:

```sh
KV260_BOARD=<board-ip> KV260_JUMP=<jump-host> \
  bash examples/kv260/board_demo_walkthrough.sh          # all scenarios
KV260_BOARD=<board-ip> KV260_JUMP=<jump-host> \
  bash examples/kv260/board_demo_walkthrough.sh mbv duo  # a selection
KV260_BOARD=<board-ip> KV260_JUMP=<jump-host> \
  bash examples/kv260/board_demo_soak.sh 5               # five rounds
```

The slot check inside both is not ceremony: writing to the PL aperture while
the app does not own the slot wedges the AXI interconnect, and only a power
cycle brings the board back -- trap 2 below. The soak driver exists because
that hazard lives in the *transition* between scenarios, which a per-demo
walkthrough executes exactly once and a user clicking around executes dozens
of times.

## Simulation legs of the KV260 examples

Until 2026-08-18 not one KV260 example simulated in this tree: `SIM_EXAMPLES`
listed only the two TGC5B SoC legs, and the benches sat unmigrated in the
predecessor repository as PowerShell runners around `xvlog`/`xelab`/`xsim`.
Four of them now run here as ordinary `.abc` graph nodes on the pinned
default backend (`.abc.config`: `sim_backend=verilator`) -- no Vivado, no
runner script:

| Target | Bench | Proves | Marker |
|---|---|---|---|
| `make sim-ddr-sink-window` | `common/sim/tb_ddr_sink_window.sv` | the DDR sink's window guard: shrinking `size_i` below the running write offset produces no burst outside `[base, base+size)`, the engine stops and counts the beats as drops. Drives `ct_soc_ddr_sink` directly -- the form the tops that wire the sink themselves (`rocket*`, `cva6_2`, `cva6_linux*`) use, which do not have the `ct_trace_sinks` register interlock | `U6_WINDOW_UNIT_PASS` |
| `make sim-axis-wp-shim` | `tgc5b2_axis_wp/sim/tb_axis_wp_shim*.sv` | `ct_axis_wp_shim` record packing, stall/overflow/resume, 12k-beat soak, `drop_count` saturation -- at `FIFO_DEPTH` 256 and 16 | `TB_PASS` (both legs) |
| `make sim-ctte-smoke` | `mbv/sim/tb_ctte_smoke.sv` | the encoder ALONE -- no core, no adapter, no Xilinx IP: `ct_encoder` at `CORE_XLEN=32` with a quiet TIP and always-ready ATB/AXIS sinks, 5 us. Elaboration + time-0 smoke, and the bisector the MicroBlaze-V bring-up used to pin an xsim kernel FATAL on the tool rather than on the integration (that probe needs `abc --sim-backend xsim`) | `[smoke] PASS` |
| `make sim-tgc5b2-axis-soc` | `tgc5b2_axis_wp/sim/tb_tgc5b2_axis_soc*.sv` | the whole watchpoint testbed through its AXI4-Lite port (two cores, two encoders, funnel, three sinks), legs C1a (13 watchpoints) and C1b (full 851-hit oracle + timestamps + negative probe) | `C1A_ALL_PASS`, `C1B_ALL_PASS` |

All four are in `SIM_EXAMPLES`, so `make sim-examples` runs them next to the
TGC5B SoC legs.

### Migrated but NOT runnable here: the MicroBlaze-V family

Package D3b (2026-08-18) brought the SoC/end-to-end benches of `mbv`, `duo`
and `trio` into the tree as well -- ten files under
[`mbv/sim/`](mbv/sim/), [`duo/sim/`](duo/sim/) and [`trio/sim/`](trio/sim/),
plus the shared CVA6 memory model
[`common/sim/axi_ram_sim.sv`](common/sim/axi_ram_sim.sv). They are **not** in
`SIM_EXAMPLES` and they cannot be: every one of them instantiates
`mbv_ctrace_soc_wrapper`, the module Vivado's `make_wrapper` generates from
the `mbv_ctrace_soc` block design at build time around the **encrypted**
MicroBlaze-V core, and through `mbv_soc_synth_wrap` also the Xilinx XPM macro
`xpm_memory_tdpram`. Neither has an in-repo `.sv` source, by design, so no
Verilator path can exist for them.

They were nevertheless checked as far as is possible without a licence: every
bench was **elaborated** with throwaway port-compatible stubs for those
modules (`verilator --lint-only -Wall --timing`, 0 real `%Error` for all
eight tops), which is how two genuine defects were found and fixed -- the
`duo`/`trio` one-shot gates still named the archive's `ct_soc_trace_buf`
instead of this tree's `ct_soc_trace_ring`, and `tb_mbv_ps_devmem` predated
the D2 sink rebuild and had to be re-wired to `m_axi_*`/`pib_*`. Full recipe,
per-bench dependency list and what a re-user needs:
[`mbv/sim/README.md`](mbv/sim/README.md).

Not present here at all: the CVA6, Rocket and `lrsc_nocache` bench groups.

## Conventions, and what is deliberately duplicated

**Testbench and build helpers are vendored per example, on purpose -- and
that is an open item, not a design goal.** There is no repository-wide
`tools/` tree, so nine example flows carry a byte-identical
`fpga/abc_filelist.py`, four carry a `cva6_filelist.py`, and every
`kv260_app`-family example carries its own `fpga/gen_ip.tcl`. Each copy says
so in its own header. Promoting them to one shared location needs a write
scope wider than a single example and has not happened yet; until it does,
a change to one copy has to be made to all of them.

**The per-example `gen_ip.tcl` copies are not duplicates of one another.**
They additionally enable `PSU__USE__S_AXI_GP2`/`_GP3` on the Zynq PS IP, which
the DDR trace sink and the CVA6/Rocket memory paths need, and which example
wires which port differs. That is a real configuration difference, so each
example keeps its own copy -- unlike `ct_axil_to_wb`/`ct_soc_axis_buf`, which
are shared from [`common/tgc5b/rtl/`](common/tgc5b/rtl/) because their delta
was documentation only.

**No two modules in this repository share a name.** The rule is checked
tree-wide, and it is what forced the one rename this migration made
(`ct_soc_trace_buf` -> `ct_soc_trace_ring`, see "Naming" above). The check
is a scan of every `module <name>` in the `.sv` sources outside `bld/`,
`.git/` and `formal/*/build`; at migration time it found exactly one
pre-existing duplicate, `fifo2clk_fwft`, which is unrelated to these
examples and untouched.

**The Vivado TCL flows here were adapted by careful reading, not run
end-to-end.** No Vivado session was invoked for the flow migration itself.
What *has* been proven from this tree is in the board column of the table
above and in the simulation legs below; everything else is a build script
that has been reviewed, not a build that has been executed. The bitstreams
that were board-gated were built before the flows moved.

**Two build inputs come from outside and are not vendored here:** the
CVA6-with-ITI fork and the Rocket generated netlist, both fetched and pinned
by [`third_party/fetch.sh`](third_party/fetch.sh) (see
[`third_party/CVA6_PIN.md`](third_party/CVA6_PIN.md) and
[`third_party/ROCKET_PIN.md`](third_party/ROCKET_PIN.md)). Without that
fetch, the CVA6 and Rocket flows stop with an explicit error rather than a
cryptic one -- that is deliberate.

## Three documented KV260 deploy traps

Carried forward from the board bring-up that produced these examples,
because every example above will hit them again otherwise. All three cost real
board-hours to diagnose the first time; the guards below exist specifically
because of that.

### 1. `scp -r` onto an existing target directory silently deploys the wrong bits

`scp -r <local-dir> <host>:<existing-dir>` does **not** overwrite the
contents of an already-existing remote directory — it copies `<local-dir>`
*into* it as a nested subdirectory (`<existing-dir>/<local-dir>/...`). A
deploy script that then loads/flashes from `<existing-dir>` picks up
whatever was there **before**, not the freshly copied files — and the `scp`
itself reports success (exit 0). This produced a multi-hour false lead
during the CVA6 trio bring-up: the board kept running the very first
bitstream through several redeploys because the staging directory already
existed on the host, and the symptom was initially misattributed to
unstable hardware.

**Rule:** `rm -rf` the target directory before every `scp -r`, never `scp -r`
onto a path that may already exist; verify the deployed file's hash **at the
target** afterward, not just the deploy script's exit code.

### 2. An AXI access to the unprogrammed/foreign PL aperture wedges the board — hard power cycle only

On the ZynqMP, an AXI read or write to the PL control-CSR aperture base
(**`0xA000_0000`**) while the PL has no matching target design loaded — either
completely unprogrammed after boot, or programmed only with the Kria DFX
base overlay (`k26-starter-kits`) — has no responding AXI slave. This is
**not** a clean decode error: the transaction is never acknowledged, and
that hangs the AXI interconnect. The board becomes completely unresponsive
(no SSH, no UART); the only recovery is a hard power cycle, there is no
software recovery path. Measured on three freshly-booted boards
(2026-07-27/28, PL entirely unprogrammed) and again on a fourth in the
"wrong thing loaded" variant — both trigger conditions are equally fatal, so
treat "PL programmed with *something*" and "PL programmed with *my* app" as
two different facts, never conflate them (`0xA000_0000` = the base this
`common/` sinks subsystem, and every board top above, sits behind).

**Rule:** never touch the aperture without first confirming — via `xmutil
listapps`, item 3 below, **not** via `fpga_manager` state — that your own
app owns the active slot. Sequence deploy services accordingly (app-load
unit `Before=` anything that opens the live bus).

### 3. `fpga_manager` state says "operating" even with no app loaded — use `xmutil listapps`

`/sys/class/fpga_manager/fpga0/state` reads `"operating"` whenever the PL
has **any** bitstream loaded — including the Kria DFX base overlay that
`dfx-mgrd` loads automatically at boot, before any user app is present. That
is exactly the state that wedges the AXI bus in trap 2, which makes
`fpga_manager` state worthless as a "safe to touch" signal despite looking
like one. The only reliable check is `sudo xmutil listapps`: read the
**Active_slot** column (`slot->handle` in some `xmutil` versions) for your
app's row — `-1` means not active, `N->N` means active in slot `N`. A
successful-looking `xmutil loadapp <name>` return ("Loaded with slot_handle
0") is not proof by itself either: `dfx-mgr` can report success while
`listapps` still shows `-1` for every app, after which the *next* load
attempt dies in-kernel (`fpga_region region0: Region already has overlay
applied`, `-22`), leaving the board unloadable without a reboot.

**Commands:**
```
sudo xmutil listapps                 # read the Active_slot / slot->handle column
sudo xmutil unloadapp                # ALWAYS before loadapp, even if listapps
                                      #   showed nothing mapped (the starter-kit
                                      #   base occupies slot 0 without appearing
                                      #   in the column)
sudo xmutil loadapp <app_name>
sudo xmutil listapps                 # re-check: your app's row must show N->N
```
If wedged in the "listapps shows nothing but load fails" state:
`systemctl restart dfx-mgr` → `unloadapp` → `loadapp`; if that still fails,
reboot the board.

**Traps 2 and 3 are one hazard with two symptoms** (freeze vs. false-positive
load) — both come down to the same rule: `0xA000_0000` is only safe once
`xmutil listapps` proves your app, specifically, owns the slot.
