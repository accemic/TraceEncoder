<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# rtl/adapters/cva6 -- CVA6 ITI -> CTTE TIP adapter

Adapter RTL migrated 2026-08 from an internal predecessor repository (see
[`../README.md`](../README.md) for the package-level provenance, runner and
conventions). CVA6 exposes its retirement/trap
information through an **ITI** (Instruction Trace Interface, a 3-bit
`itype` E-Trace-chapter-4 vocabulary) rather than a raw signal bundle like
the MicroBlaze V's `TRACE` bus.

## Files

| File | Role | Needs the vendored CVA6 core? |
|---|---|---|
| `cva6_riscv_itype_refine.sv` | Reconstructs CALL/RETURN/CO_ROUTINE_SWAP from the raw instruction word (package I1) -- the 3-bit ITI code alone cannot express them | No -- pure combinational, instruction-word in |
| `cva6_iti_to_ctte_tip.sv` | ITI struct (flat) -> `tip_if.master` (Gate C2); trap-beat iretire=0 forcing, idle-cycle contract, optional context (W2) and itype refinement (I1) | No -- interface-driven |
| `cva6_trace_wrap.sv` | Instantiates the upstream `cva6` + `cva6_rvfi` + `cva6_iti` (the CVA6-with-ITI fork) and exposes a flat AXI4 master + ITI output + RVFI golden reference | **Yes** -- the only file here that touches vendored core sources |

## Why `cva6_trace_wrap.sv` has no unit testbench here

Per the TraceEncoder consolidation plan, reference cores are **fetched, not
vendored** into this IP tree (`examples/kv260/third_party/fetch.sh`
pattern, not landed yet at the time of this migration). `cva6_trace_wrap.sv`
is adapter-side glue, but its body instantiates `cva6`, `cva6_rvfi` and
`cva6_iti` by name and includes `rvfi_types.svh` / `cvxif_types.svh` /
`iti_types.svh` from that fork -- none of which live in this repository.
It therefore cannot elaborate standalone here; its `.abc` file documents
that instead of pretending otherwise. Its only test coverage were a Gate C1
characterization bench and an end-to-end bench, both of which need the real
vendored core and are therefore example-level, not part of this package.

## Unit-test layout

`test/tb_iti2tip_unit.sv` (Gate C2) and `test/tb_itype_refine_unit.sv`
(package I1) are fully interface-driven -- neither needs `cva6_trace_wrap`
or the vendored core, matching the CTTE convention of per-module unit
testbenches under `rtl/<module>/test/`. `tb_itype_refine_unit.sv` reads
`itype_vectors.vec`, a static snapshot generated from the real RISC-V
assembler + objdump (an oracle independent of the DUT, see the file
header); the generator itself is not part of this repository.

A wider RV64 variant of `tb_iti2tip_unit` (plus an XLEN-mismatch probe)
exists outside this repository but was not carried over -- see
[`../README.md`](../README.md) "Known absences".

## What this adapter does not carry: the data channel

ITI is an **instruction**-trace interface. It delivers
`valid/iretire/ilastsize/itype/cause/tval/priv/iaddr/cycles` (plus the
optional `satp.ASID` context) and **no data-access information at all**.
`cva6_iti_to_ctte_tip.sv` therefore ties the whole TIP data half off:
`tip.dretire = 1'b0`, `dtype = 0`, `daddr = '0`, `sdata = '0`.

Consequences for anyone wiring a CVA6 integration:

* **Works:** program/control-flow trace, and ACT-ST watchpoints — they
  trigger on a retired PC and need nothing but `iaddr`.
* **Does not work:** data trace, the DF range filter, and the `DAQ_DATA` /
  `DAQ_DADDR` / `DAQ_DATA_DADDR` ACT commands. They are not degraded, they
  have no input.
* **ACT-CAP is unreachable.** It decodes a CSR write off the data channel
  (`dretire && dtype == CSR_READ_WRITE && daddr == 0x0B10`,
  `rtl/preproc/ct_L23_preproc_act_cap.sv`). With no data beat there is
  nothing to decode, and no adapter-level workaround either: on a core that
  *does* expose stores one can convert a store to a doorbell address into
  the CSR beat, but that trick needs a store beat to start from.

RVFI is not an escape route. `cva6_trace_wrap.sv` exposes it as a golden
reference and the example wrappers tie the outputs off; more importantly the
CVA6 RVFI CSR structure is a **fixed list of named architectural CSRs**
(`rvfi_types.svh`, `RVFI_CSR_T`) with no field for an arbitrary
(address, value) pair — it cannot express a write to a vendor CSR such as
`0x0B10` even if it were connected. Making ACT-CAP work on CVA6 means
probing the core's own commit/LSU stage, i.e. a change inside vendored
third-party RTL.

The per-core comparison is tabulated in
[`../../../examples/kv260/README.md`](../../../examples/kv260/README.md),
section "What each core's trace ingress can and cannot carry".
