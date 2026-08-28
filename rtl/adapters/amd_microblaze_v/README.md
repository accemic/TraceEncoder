<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# rtl/adapters/amd_microblaze_v -- MBV -> CTTE TIP adapter

Adapter RTL migrated 2026-08 from an internal predecessor repository (see
[`../README.md`](../README.md) for the package-level provenance, runner and
conventions). **AMD-specific, outside the CTTE
core (AD-01).** The adapter **imports** `tip_pkg` from `rtl/pkg/` and drives
`tip_if.master` -- the TIP enums (`tip_itype_e`, `tip_ecause_e`, ...) are
**not** duplicated.

## Module plan + gate mapping

| File | Role | Gate | Status |
|---|---|---|---|
| `mbv_trace_pkg.sv` | AMD `TRACE` field widths, version fingerprint, RISC-V ISA decode constants | -- | elaborates standalone |
| `mbv_trace_if.sv` | AMD `TRACE` bus input interface -- signals **empirically confirmed** @ Vivado 2026.1 / `microblaze_riscv:1.0` | -- | structural |
| `mbv_riscv_itype_decoder.sv` | Instruction decode -> 4-bit `itype` (BRANCH/JAL/JALR/MRET/SRET) + `ilastsize` | **G2** | unit-TB green (30/30 vectors, 10 itype values covered) |
| `mbv_trap_mapper.sv` | Trap entry/return, `iretire`, `ecause`, special cause | **G3** | unit-TB green (12/12 against the G1 measured values) |
| `mbv_to_ctte_tip.sv` | Combines the above -> `tip_if.master` (incl. §5.1 priority, MVP constants, assertions) | **G2-G4** | integration-TB green (16/16 from real G1 scenarios) |

Not part of this package (see [`../README.md`](../README.md) "Known
absences" for the reasoning): `mbv_trace_normalizer.sv` and `mbv_data_mapper.sv` do not exist yet upstream
(later phases, R4 bitorder / P2 data trace); the SoC-level and native-encoder
testbenches (`tb_mbv_g0_soc`, `tb_mbv_g4_ctte`, `tb_mbv_dual_encoder`,
`tb_mbv_native_probe`, `tb_mbv_native_enable`) need a real, vendored
MicroBlaze V core and belong to `examples/`, not to this IP-level adapter
directory.

## Gate discipline

**G1 is closed for the MVP scope** (rounds 1-7, see
[`doc/adapters/microblaze_v_trace_semantics.adoc`](../../../doc/adapters/microblaze_v_trace_semantics.adoc));
the behavior modules are therefore based on **measured** rules, not
documentation assumptions:
- `iretire = Trace_Valid_Instr && !Trace_Exception_Taken` -- `Valid_Instr` is
  **not** retirement (confirmed over 6 sync causes + 69 interrupt events, 0
  counterexamples).
- `itype = Exc_Kind[5] ? INTERRUPT : EXCEPTION_TRAP`; `ecause = Exc_Kind[3:0]` directly.
- `ilastsize = (instr[1:0]==2'b11) ? 1 : 0` (R3 disproved).

**Still blocked for their respective scope** (not MVP): access faults (need
an AXI error response, from G4 on), special causes >15 (ports not exposed --
the `impdef` path in `trap_mapper` is **design per §5.3, HW-untested**),
data trace (P2/G8), RVC decode (G7 -- `SUPPORT_RVC=1` deliberately triggers
`$fatal`).

## Unit-test layout

Per-module unit testbenches live **next to** the module under
`rtl/adapters/amd_microblaze_v/test/`, matching the CTTE convention
(`rtl/<module>/test/`, see e.g. `rtl/preproc/test/`). None of them need the
vendored MicroBlaze V core -- `tb_mbv_itype_decoder` and `tb_mbv_trap_mapper`
drive their DUT directly from vectors, `tb_mbv_to_ctte_tip` drives the
adapter top through `mbv_trace_if` with real measured G1 scenarios.

## What this adapter does not carry: the data channel

The AMD `TRACE` bus this adapter maps is an **instruction**-trace bus.
`mbv_to_ctte_tip.sv` ties the TIP data half off: `tip.dretire = 1'b0`,
`dtype = LOAD` (an inert default), `daddr = '0`, `sdata = '0`. Data trace is
listed among this package's known absences (P2/G8) — this section says what
that means downstream.

* **Works:** program/control-flow trace, and ACT-ST watchpoints (retired-PC
  trigger, needs only `iaddr`).
* **Does not work:** data trace, the DF range filter, and the `DAQ_DATA` /
  `DAQ_DADDR` / `DAQ_DATA_DADDR` commands.
* **ACT-CAP is unreachable**: it decodes a CSR write off the data channel
  (`dretire && dtype == CSR_READ_WRITE && daddr == 0x0B10`,
  `rtl/preproc/ct_L23_preproc_act_cap.sv`). With no data beat there is
  nothing to decode, and the doorbell-store workaround that a
  store-exposing core allows has no store beat to convert here.

The per-core comparison is tabulated in
[`../../../examples/kv260/README.md`](../../../examples/kv260/README.md),
section "What each core's trace ingress can and cannot carry".
