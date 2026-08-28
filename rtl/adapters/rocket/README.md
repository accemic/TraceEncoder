<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# rtl/adapters/rocket -- Rocket TraceCoreInterface -> CTTE TIP adapter

Adapter RTL migrated 2026-08 from an internal predecessor repository (see
[`../README.md`](../README.md) for the package-level provenance, runner and
conventions). Rocket exposes its retirement/trap
information through rocket-chip's **TraceCoreInterface** (`nGroups=1`), a
4-bit `itype` that already carries the full E-Trace vocabulary (RISC-V
Processor Trace Spec V1.0) -- unlike the CVA6 ITI's narrower 3-bit code, no
separate refinement module is needed.

## Files

| File | Role |
|---|---|
| `rocket_tci_to_ctte_tip.sv` | TraceCoreInterface (flat) -> `tip_if.master`; trap-beat iretire=1->0 clamp, trap_return remap 13->3 (`MAP_TRAP_RETURN_TO_ERET`), idle-cycle contract, optional context (M3, `satp.PPN`-keyed ownership) |

This adapter is entirely **interface-driven** -- it was built and G1-verified
against the TraceCoreInterface field set before the vendored Rocket netlist
even existed (packages R3.0/R3.1a), and later cross-checked against the real
generated netlist (R3.2a, M3). Its RTL therefore has no
dependency on a vendored core at all, unlike `cva6_trace_wrap.sv` in the
neighboring `cva6/` adapter.

## Unit-test layout

`test/tb_rocket_tci_unit.sv` drives the shim directly through the
TraceCoreInterface fields (three parallel DUT instances covering the
trap-return-remap default/override and the optional context path) -- no
vendored core needed. Matches the CTTE convention of per-module unit
testbenches under `rtl/<module>/test/`.

The characterization testbenches that measure the real Rocket-chip netlist
need the vendored generated Verilog and a bootrom patch; they produced the
G1 truth table this adapter implements but are SoC/generator-level
artifacts, not unit tests of this shim, and are not part of this package --
see [`../README.md`](../README.md) "Known absences".

## What this adapter does not carry: the data channel

The Rocket TraceCoreInterface is an **instruction**-trace interface.
`rocket_tci_to_ctte_tip.sv` ties the whole TIP data half off:
`tip.dretire = 1'b0`, `dtype = 0`, `daddr = '0`, `sdata = '0`.

* **Works:** program/control-flow trace, and ACT-ST watchpoints (they
  trigger on a retired PC and need only `iaddr`).
* **Does not work:** data trace, the DF range filter, and the `DAQ_DATA` /
  `DAQ_DADDR` / `DAQ_DATA_DADDR` commands — no input, not reduced accuracy.
* **ACT-CAP is unreachable**: it decodes a CSR write off the data channel
  (`dretire && dtype == CSR_READ_WRITE && daddr == 0x0B10`,
  `rtl/preproc/ct_L23_preproc_act_cap.sv`). No data beat, nothing to decode,
  and no adapter-level workaround — the doorbell-store trick available on a
  core that exposes stores needs a store beat to convert.

One more limit worth knowing on a 64-bit Rocket: the watchpoint table's
CSR side stays a 32-bit word pair, so at `XLEN = 64` the upper key half is
written as 0 and a watchpoint can only be placed in the low 4 GiB
(`rtl/pkg/ct_pkg.sv`, "Definitions for M0"). Bare-metal images in the PL/DDR
window are fine; Linux kernel virtual addresses are not reachable.

The per-core comparison is tabulated in
[`../../../examples/kv260/README.md`](../../../examples/kv260/README.md),
section "What each core's trace ingress can and cannot carry".
