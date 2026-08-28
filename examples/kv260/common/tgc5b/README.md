<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# `common/tgc5b` — the shared MINRES TGC5B SoC building blocks

Not an example. This is the **library** that eight KV260 examples build on:
the vendored RV32 core, the AXI-Lite→Wishbone bridge, the SoC peripherals and
their generated register block, and a worked program to run on them.

It used to live in `examples/tgc5b_soc/`, a minimal single-core example that
also happened to hold everything else's building blocks. That example was
superseded by [`../../tgc5b2_axis_wp/`](../../tgc5b2_axis_wp/), but deleting it
would have taken the CPU, the bridge, the RAM and the register block with it —
so the library moved here and the example half was dropped.

## What is in here

| Path | What it is |
|---|---|
| `cpu/` | The vendored MINRES TGC5B RV32 core. **Do not edit** — provenance, config hash and the licence consequences of modifying it are in [`cpu/README.md`](cpu/README.md) |
| `rtl/ct_axil_to_wb.sv` | AXI4-Lite → Wishbone bridge. The single most-reused file here: every KV260 example uses it to reach the encoder's CSRs |
| `rtl/ct_soc_ram.sv` | Program/data RAM |
| `rtl/ct_soc_periph.sv` | CLINT + INTC + PS control, driven by the generated register block |
| `rtl/ct_soc_axis_buf.sv` | AXI-Stream capture buffer |
| `rtl/ct_soc_trace_buf.sv` | The small trace buffer of this SoC. **Not** `ct_soc_trace_ring` — see "Two trace buffers" below |
| `rtl/ct_tip_adapter.sv` | TGC5B trace port → the encoder's TIP |
| `rtl/ct_soc_synth_wrap.sv` | Core + encoder + RAM + peripherals as one synthesisable block |
| `pkg/ct_soc_regs*.sv` | Generated from `rdl/ct_soc.rdl` by `make rdl-soc`. **Never hand-edited** |
| `rdl/ct_soc.rdl` | The SoC register map, and the only worked example of instantiating `rdl/ct_cs_cpuif.rdl` inside a larger system map |
| `prog/` | `hello_trace`: a committed RV32 program plus its `.pcinfo` oracle, and the sources to rebuild it. The pattern `tgc5b2_axis_wp/sw/` follows |
| `ct_soc_top.sv`, `test/ct_soc_tb.sv` | The SoC top and its bench — the regression gate for everything above (`make sim-tgc5b-soc`) |

## Who consumes it

| Consumer | Takes |
|---|---|
| [`../../tgc5b2_axis_wp/`](../../tgc5b2_axis_wp/) | `cpu/`, `pkg/`, `ct_tip_adapter`, `ct_axil_to_wb`, `ct_soc_ram`, `ct_soc_periph` |
| [`../../duo/`](../../duo/), [`../../trio/`](../../trio/) | the above plus `ct_soc_synth_wrap`, `ct_soc_axis_buf` |
| [`../../mbv/`](../../mbv/) | `ct_axil_to_wb`, `ct_soc_axis_buf` |
| `rocket_linux`, `rocket2`, `cva6_linux`, `cva6_linux64`, `cva6_2` | `ct_axil_to_wb` |

Both routes resolve the same files: the `.abc` filelists import
`@examples/kv260/common/tgc5b/...`, the Vivado flows `add_files` them by path.
Move a file here and both have to follow.

## Two trace buffers, deliberately

`ct_soc_trace_buf` (here) and `ct_soc_trace_ring`
([`../ct_soc_trace_ring.sv`](../ct_soc_trace_ring.sv)) are **different
designs**, not two names for one. The ring is the 1-MiB URAM board sink inside
`ct_trace_sinks`; this one is the small, simpler buffer of this SoC. The board
examples instantiate the ring.

## Regenerating the register block

```bash
make rdl-soc      # rdl/ct_soc.rdl -> pkg/ct_soc_regs{,_pkg}.sv
```

Commit the RDL and the regenerated SystemVerilog together — `make rdl-soc`
followed by a non-empty `git diff` means someone hand-edited the output.

## Simulating it

```bash
make sim-tgc5b-soc
```

Runs `test/ct_soc_tb.sv`: the real core executes `prog/hello_trace`, the
encoder emits N-Trace, and the decoder has to find a synchronization message
in it. The exact golden-PC cross-check runs as a **soft** check — it reports
without failing the target.
