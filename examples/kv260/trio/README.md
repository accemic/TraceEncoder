<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/trio -- MicroBlaze-V + MINRES TGC5B + CVA6, mixed-protocol funnel, on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces
**three** independent RISC-V cores at once, extending [`../duo/`](../duo/)
(MicroBlaze-V + MINRES TGC5B) with a third branch: a CVA6 (`cv32a60x`
configuration) traced through its ITI (Instruction Trace Interface) and the
`cva6_iti_to_ctte_tip` shim. Each encoder instance carries **exactly one**
back end, chosen as a **synthesis parameter** (`ENC0/1/2_ETRACE`; dual
N-Trace+E-Trace builds with a run-time protocol select were retired on
2026-08-04 -- `trTeProtocolSel` is read-only discovery since). What the
example shows is a **protocol MIX per instance in one netlist**: the board
top builds MBV and TGC5B as N-Trace and the CVA6 as E-Trace; `ct_L1_funnel`
merges all three ATB streams into one packet-atomic trace stream, mixing
N-Trace and E-Trace framing in the same merged output (`EN_TE_RAW=1`).

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share. The cross-example risk around
`cva6_soc_synth_wrap.sv`, open at migration time, has since been resolved by
sharing the single copy in [`../cva6_linux/`](../cva6_linux/) (see "Open
items" below). Companion
examples: [`../duo/`](../duo/) (the two-core pattern this example extends)
and [`../tgc5b2_axis_wp/`](../tgc5b2_axis_wp/) (two TGC5Bs, watchpoint/DAQ
export instead of a third core).

## What it shows

- **Three heterogeneous cores, one merged trace stream.** `ct_L1_funnel`
  (`N_STREAMS=3`, `MDO_WIDTH=6`, `EN_TE_RAW=1`) arbitrates by priority
  (`FUNNEL_CTRL`, default round-robin).
- **Mixed-protocol operation.** Each encoder's back end is fixed per
  instance at synthesis (`ENC0/1/2_ETRACE`); its `trTeProtocolSel` (in its
  own ENC CSR window) reports that choice read-only, so host software can
  discover the mix. The funnel reads the framing actually in effect straight
  from the encoder (`atb_te_raw`, an ATB-domain signal) -- never a second,
  software-tracked copy that could drift out of sync.
- **The CTMX container for mixed E-Trace sources.** When a channel is in
  E-Trace mode, the funnel prepends a one-byte source tag (`0x80 | src`)
  ahead of that channel's packets so a merged E-Trace-containing stream stays
  splittable. [`tools/etrace_trio_demux.py`](tools/etrace_trio_demux.py)
  (vendored into this example, see below) splits a captured container back
  into one `.te_inst_raw` stream per source, byte-identical to a
  single-core capture and therefore readable by an unmodified E-Trace
  reference decoder.
- **A board-vs-simulation backend split, made explicit in the top.**
  `trio_kv260_top.sv` builds the CVA6 encoder (the core with the native
  E-Trace ingress) as E-Trace (`ENC2_ETRACE=1`) and the MBV/TGC5B encoders as
  N-Trace (`ENC0/1_ETRACE=0`); `trio_soc_top`'s own defaults set all three to
  E-Trace for the simulation legs. (The historical figure "120,665 LUT
  post-synth = 103.03 %, place aborts" belongs to the retired triple-DUAL
  build of 2026-07-25 and is kept in the migration notes, not here.)
- **A third memory path.** The CVA6 has no RAM-loader window like the other
  two branches -- it fetches code/data itself over a 64-bit AXI4 master
  (`m2_axi_*` -> PS `S_AXI_HP1_FPD` -> DDR4 window **`0x6400_0000` +192 MiB**)
  and starts independently via `CONTROL.b5`/`b10`, only after that window is
  loaded. The core enters at `BOOT_ADDR = 0x6400_0000`
  (`rtl/trio_soc_top.sv:430`), which is also the PS-side address -- unlike the
  two-core AMP example, the two views coincide here.

  > **Corrected 2026-08-19.** This line named `0x7C00_0000` until then, a
  > leftover from the address plan before v4. That address lies **outside**
  > the `reserved-memory` window (`0x5000_0000` +512 MiB, overlay
  > `../common/board/ctrace_resmem.dtso`) -- and the failure mode of following
  > the old line is not an error message: `devmem` writes tens of megabytes
  > into memory the host kernel is using. The authoritative split is in
  > `rtl/trio_soc_top.sv`'s header at `DDR_BASE`: `0x5000_0000` +256 MiB trace
  > sink, `0x6000_0000` +64 MiB gap, `0x6400_0000` +192 MiB CVA6 code/data.

## Which protocol each encoder speaks -- measured, not assumed

`fpga/trio_kv260_top.sv` instantiates the SoC with `ENC0_ETRACE = 0`,
`ENC1_ETRACE = 0`, `ENC2_ETRACE = 1`. Read back from the board on 2026-08-19
(`trTeProtocolSel`, offset `0x030` of each encoder):

| Encoder | Core | `trTeProtocolSel` | Back end |
|---|---|---|---|
| ENC0 `0xA001_0030` | MicroBlaze V | `0x0` | N-Trace 1.0 (Nexus) |
| ENC1 `0xA002_0030` | TGC5B | `0x0` | N-Trace 1.0 (Nexus) |
| ENC2 `0xA003_0030` | CVA6 | `0x1` | E-Trace 2.0 (`te_inst`) |

The register is **read-only**: the protocol is a synthesis parameter per
encoder instance, and the runtime select of the former dual build was retired
on 2026-08-04 (see `rdl/ct_cs_cpuif.rdl` at `trTeProtocolSel`). All three
encoders with the E-Trace back end no longer fit on the xck26 -- 120,665 LUT
post-synthesis, 103 %, the placer aborts -- so the board top picks a
combination that fits.

**What that means when you decode.** With the CVA6 branch running, the merged
ring is not a pure Nexus stream, and a decode aborts at the framing
(`MSEO='10' is not allowed`) -- for *all* targets, not only the third. Two
ways forward, and they are different in kind:

* **Two-source run.** Leave the CVA6 branch stopped (do not set `CONTROL.b5`/
  `b10`). The merged stream is then uniform N-Trace and one decode run splits
  MBV and TGC5B by source tag. Measured 2026-08-19: 2,804,391 instructions,
  zero errors -- and the shipped dashboard capture is exactly this run.
* **Mixed container.** Split it host-side first with
  [`tools/etrace_trio_demux.py`](tools/etrace_trio_demux.py), then decode each
  stream with the decoder that matches it.

Whether this example should keep demonstrating mixed protocols, or be rebuilt
with `ENC2_ETRACE = 0` for one uniform stream and three targets in a single
decode run, is a **product decision**. It is not a defect, and it is not
something to change silently in passing.

## Layout

```
rtl/    trio_soc_top.sv            AXI4-Lite control-port top: 3 SoC branches + mixed-protocol
                                   funnel + sinks (CTRL/ENC0/ENC1/ENC2/RAM0/RAM1/TRACE/AXIS)
        tgc5b_dual_synth_wrap.sv   the TGC5B branch's synth wrapper
                                   (the CVA6 branch's cva6_soc_synth_wrap.sv is NOT vendored
                                   here -- it is shared from ../cva6_linux/rtl/, see below)
fpga/   trio_kv260_top.sv          bitstream top: Zynq PS + AXI plumbing (adds S_AXI_HP1_FPD
                                   for the CVA6 memory path vs. duo_kv260_top.sv)
        create_project_kv260.tcl  entry point: builds the Vivado project (see "Build" below)
        gen_ip.tcl                 the 4 standalone PS-glue IPs, now with S_AXI_GP3/HP1 64-bit
                                   (byte-identical to ../mbv/ and ../duo/'s copies except the
                                   header's top-name references -- see gen_ip.tcl's own note)
        duo_pib_pmod.xdc           PIB pinout (same physical pinout as ../duo/fpga/duo_pib_pmod.xdc)
        abc_filelist.py            resolves the CTTE encoder's .abc dependency graph into a file list
tools/  cva6_filelist.py           resolves the CVA6 Flist manifest into a file list (the manifest
                                   comes from ../third_party/fetch.sh, see "Open items" below)
        etrace_trio_demux.py       host-side CTMX container splitter (vendored, self-test included)
sim/    tb_trio_ps_devmem.sv       the whole devmem flow through trio_soc_top -- Vivado xsim
                                   only (see sim/README.md for why, and for what was checked
                                   without it)
```

`trio_soc_top.sv` instantiates `mbv_soc_synth_wrap` from
[`../mbv/rtl/`](../mbv/rtl/) for its MBV branch, `ct_soc_synth_wrap` from
[`../common/tgc5b/rtl/`](../common/tgc5b/rtl/) for its TGC5B branch, this
`cva6_soc_synth_wrap` shared from [`../cva6_linux/rtl/`](../cva6_linux/rtl/)
for its CVA6 branch (which in turn
instantiates `cva6_trace_wrap`/`cva6_iti_to_ctte_tip` from
[`../../../rtl/adapters/cva6/`](../../../rtl/adapters/cva6/), already
migrated to this repository's root), and the shared sink RTL from
[`../common/`](../common/) plus `ct_L1_funnel` from this repository's root.

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

| Region | Offset | Contents |
|---|---|---|
| CTRL  | `0x00_0000` | control/status registers (`trio_soc_top.sv`) |
| ENC0  | `0x01_0000` | CTTE encoder CSRs, MBV     (via `ct_axil_to_wb` -> Wishbone) |
| ENC1  | `0x02_0000` | CTTE encoder CSRs, TGC5B   (via `ct_axil_to_wb` -> Wishbone) |
| ENC2  | `0x03_0000` | CTTE encoder CSRs, CVA6    (via `ct_axil_to_wb` -> Wishbone) |
| RAM1  | `0x08_0000` | TGC5B program/data RAM (64 KiB; write while `core1_run=0`) |
| RAM0  | `0x10_0000` | MBV program/data RAM (128 KiB; write while `core0_run=0`) |
| TRACE | `0x20_0000` | merged ATB ring buffer (1 MiB URAM) |
| AXIS  | `0x30_0000` | AXIS capture (MBV encoder only) |

CTRL register detail -- including `CONTROL.b5`/`b10` (CVA6 start), the C6
observation-channel sticky flags in `STATUS[7:4]`, the `SINK_CTRL`/`DDR_*`/
`PIB_*`/`FUNNEL_CTRL` window (with the added `b16` TagAlways and `b[26:24]`
per-channel framing readback) -- is documented in `trio_soc_top.sv`'s header
comment (`@details`).

## Build (TCL flow)

Like `../mbv/` and `../duo/`, this example's Vivado flow is still a plain
TCL script, not yet this repository's `abc` build driver.

```bash
# Project + RTL elaboration check only:
vivado -mode batch -source examples/kv260/trio/fpga/create_project_kv260.tcl

# Full synth -> impl -> bitstream:
TRIO_KV260_SYNTH=1 vivado -mode batch -source examples/kv260/trio/fpga/create_project_kv260.tcl
```

Like `../duo/`, this migrated version is a single, self-contained entry
point rather than the two-script, project-cache-reusing flow it came from.

**The build flips one encoder profile switch -- in a sandbox, not in the
tree.** trio is the only example whose three encoders do not all speak the
same protocol, and that has a consequence the other eight do not have. The
back end is chosen per *instance* (`EN_NTRACE`/`EN_ETRACE`), but the eTIP
**sideband widths** it consumes -- privilege, `ecause`, `tval`, last-instruction
size -- are sized by a *package* (`ct_etip_pkg`, from `ct_pkg::CT_EN_ETRACE`),
and a package cannot be parameterised per instance. `ct_pkg` therefore stays
the netlist master: it has to say `CT_EN_ETRACE = 1` as soon as **any**
instance speaks E-Trace, even though only ENC2 does.
`rtl/ct_encoder.sv:246` enforces exactly that and names this build in its own
comment; without the flip the run stops in elaboration with

```
ERROR: [Synth 8-6058] ct_encoder: EN_ETRACE=1 requires ct_pkg::CT_EN_ETRACE=1 …
```

The committed `rtl/pkg/ct_pkg.sv` keeps `CT_EN_ETRACE = 0`, because it is
shared with all eight other examples and every gate -- flipping it there would
widen the sideband in `mbv`/`duo`/`cva6_*`/`rocket*` too and move their
resource numbers. So `fpga/create_project_kv260.tcl` uses the profile-sandbox
pattern of [`scripts/cli_etrace_test.sh`](../../../scripts/cli_etrace_test.sh):
it copies `rtl/pkg/*.sv` into `bld/trio_kv260_profile/pkg/` (gitignored), sets
the switch **there**, and points the fileset at the copy. Nothing in the
repository changes, and a parallel build or gate in the same checkout never
sees the flip. The build prints what it did:

```
### PROFILE: CT_EN_ETRACE=1 (mixed N-/E-Trace netlist), 16 package sources from …/bld/trio_kv260_profile/pkg
```

`CT_EN_NTRACE` stays 1 in the sandbox as well: `ct_pkg.sv` sanctions that
combination for exactly this case ("the netlist contains encoders of both
kinds"), all three instances pick their back end explicitly, and an
*unparameterised* one then fails loudly instead of silently inheriting the
wrong protocol. `scripts/gen_rdl_profile.py` is deliberately not run -- the
CSR block does not depend on this switch (its `SWITCH_TO_DEFINE` map has no
`CT_EN_ETRACE` entry; two out-of-tree runs over an otherwise identical
`CT_EN_ETRACE` 0/1 pair produce byte-identical `ct_cs_cpuif.sv`,
`ct_cs_cpuif_pkg.sv` and `ct_profile.inc.rdl`), so the sandbox uses the
committed generated files unchanged and the build needs no PeakRDL venv.

**The CVA6 branch needs the fetched reference core.**
`cva6_soc_synth_wrap.sv` instantiates the upstream CVA6 core via
`rtl/adapters/cva6/cva6_trace_wrap.sv`, which in turn needs the pinned
CVA6-with-ITI fork under `third_party/cva6_ref/`. That fork is *fetched*,
not committed — the fetch step has landed since this example was migrated:
run [`../third_party/fetch.sh`](../third_party/fetch.sh) (pin and rationale
in `../third_party/CVA6_PIN.md`). This example's
`create_project_kv260.tcl` resolves the CVA6 file list via the vendored
`tools/cva6_filelist.py` and fails with a named, actionable error if
`third_party/cva6_ref/core/Flist.cva6` is missing, rather than a cryptic
one. Fetch the core with
[`../third_party/fetch.sh`](../third_party/fetch.sh).

**`cva6_soc_synth_wrap.sv` is shared with `cva6_linux`, not duplicated.** The
same module is instantiated by `cva6_linux_soc_top.sv`. At migration time no
`examples/kv260/cva6_linux/` existed, so this was recorded here as a future
collision risk; the directory exists today
([`../cva6_linux/`](../cva6_linux/)) and the risk has been resolved by
sharing the single copy: `trio` no longer carries its own
`rtl/cva6_soc_synth_wrap.sv`, and
[`fpga/create_project_kv260.tcl:155`](fpga/create_project_kv260.tcl) adds
`../../cva6_linux/rtl/cva6_soc_synth_wrap.sv` to the project instead. A
repository-wide search finds exactly one `module cva6_soc_synth_wrap`
declaration (`examples/kv260/cva6_linux/rtl/cva6_soc_synth_wrap.sv:26`). Do
not vendor a second copy.

## Running the bare-metal programs

This example has **no board gate of its own yet** -- `../README.md` lists
`trio` as "pending" on the board column, and unlike `../mbv/`, `../duo/`,
`../cva6_linux/` and `../tgc5b2_axis_wp/` there is no `trio/board/`
directory. The shared packaging/deploy/loader tooling those examples use
does exist and is reusable from here:
[`../common/board/`](../common/board/) (`package_kv260_app.py`,
`deploy_kv260_app.sh`, `mem_load.py`), and
[`../duo/board/README.md`](../duo/board/README.md) is the closest template
(same funnel/sink register set, one core fewer).

The register-level protocol is the one in `../mbv/README.md`'s "Running the
bare-metal programs" section, applied per core (RAM0/ENC0 for MBV, RAM1/ENC1
for TGC5B; the CVA6/ENC2 branch instead needs its DDR window loaded via
`devmem` before `CONTROL.b5`/`b10` is set -- see
[`../SPEC_board_memory_map.md`](../SPEC_board_memory_map.md), part of this
repository since 2026-08-21).

## Running it on the board

This example has no `board/` directory and needs none: its control map for
the MicroBlaze V and the TGC5B is the same as `duo`'s, so the proven
[`../duo/board/duo_board_gate.sh`](../duo/board/duo_board_gate.sh) drives it
unchanged:

```sh
bash examples/kv260/duo/board/duo_board_gate.sh \
     --skip-package \
     --app-dir examples/kv260/trio/fpga/proj/trio_kv260.runs/impl_1/app_pkg/trio_ctrace_kv260 \
     --app trio_ctrace_kv260 --pl-mhz 68 \
     --oracle1 examples/kv260/duo/board/refs/core1_hello_trace.recorded_20260821.pcs \
     --board <ip> --jump <host>
```

The bitstream and a ready-made app package are in the tree, so
`--skip-package` is the normal case. **Stop `ctrace-dashboard.service`
before any `xmutil unloadapp`** (see
[`../SPEC_board_memory_map.md`](../SPEC_board_memory_map.md) §3).

Two things this run deliberately does NOT do. It leaves the **CVA6
stopped**: with all three sources active the ring is not a pure Nexus stream
and the decode aborts at the framing -- for all three targets, not just the
third. And it uses the **2026-08-21** core-1 reference, not the 2026-08-19
one; why there are two, and which is right, is an open question documented
in [`../duo/board/refs/README.md`](../duo/board/refs/README.md).

Measured 2026-08-21: **`DUO_BOARD PASS`** -- core 0 against the real oracle
(26 772 PCs contained in full as a prefix of 624 064), core 1 against the
recorded reference, 1 353 645 instructions decoded in total. The PC
sequences are **identical** to a `duo` run over the full length of the
shorter capture (720 238 PCs on core 1, 609 352 on core 0) -- the
cross-design reproduction that `duo/board/refs/README.md` describes, freshly
measured.

## Verification performed during migration

`verilator --lint-only` elaboration of `trio_soc_top`'s own RTL (this
example's files, `../mbv/rtl/`, `../common/tgc5b/rtl/`, `../common/`, and
`rtl/ct_L1_funnel.sv`) plus the `rtl/adapters/cva6/` shim files
(`cva6_iti_to_ctte_tip.sv`, `cva6_riscv_itype_refine.sv`) that do NOT
require the vendored core; `cva6_soc_synth_wrap.sv`/`cva6_trace_wrap.sv`
themselves could not be elaborated (they need the vendored CVA6 core, see
"Open item" above) -- a port-compatible throwaway stub for
`cva6_trace_wrap` was used instead, mirroring the stubbing technique
`../mbv/README.md`'s own verification section documents for
Vivado-generated modules. Full results, the stub's port list, and the
repository-wide duplicate-module-name check were both green. This
example's
`tools/etrace_trio_demux.py` carries a self-test; from the repository root it
runs as `py examples/kv260/trio/tools/etrace_trio_demux.py --selftest`
(equivalently `py tools/etrace_trio_demux.py --selftest` with this example
directory as the working directory) and prints
`etrace_trio_demux: self-test OK (5 cases)`.
The Vivado TCL flow itself (`fpga/`) was adapted by careful path/reference
review, not executed -- no Vivado license/session was exercised as part of
this migration, and the CVA6 branch could not be executed regardless (see
above).
