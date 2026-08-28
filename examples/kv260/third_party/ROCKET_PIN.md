<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# rocket_ref -- vendoring pin

Not vendored in this repository (by design: reference
core sources are pinned by commit, not copied into the tree) and **not
fetchable by a simple `git clone`** -- it is a *generated* Verilog blob (see
"Generation" below). Consumed by the `rocket_linux` (1-hart) and `rocket2`
(2-hart) KV260 examples via `rocket_tci_to_ctte_tip` in
[`../../../rtl/adapters/rocket/`](../../../rtl/adapters/rocket/), which
expects the generated `RocketSystem` top's `trace_core_N_*` ports.

Migrated from an internal predecessor repository
(2026-08-17).

A vendored **Verilog generat** of a Rocket-Chip **RV64IMAC without an FPU**
with RISC-V Processor-Trace-v1.0 ingress enabled
(`enableTraceCoreIngress=true`) and the `TraceCoreInterface` routed out to
the `RocketSystem` top-level ports. Produced via
`eugene-tarassov/vivado-risc-v`. Accemic-internal, license permissive (MIT +
Apache-2.0 + BSD-3, see the pinned tree's own `LICENSE.*`); does not collide
with CERN-OHL-S -- Rocket stays outside the encoder core.

**Two generats exist side by side:**

| Generat | Config | Harts | Context sideband | Consumed by |
|---|---|---|---|---|
| 1-hart | `Rocket64t1` | 1 | no | `rocket_linux` (`rocket_soc_synth_wrap.sv`) |
| 2-hart | `Rocket64t2` | 2 | yes (`trace_core_N_context`) | `rocket2` (`rocket2_soc_synth_wrap.sv`) |

## Sources + pin (both generats, same superrepo/rocket-chip pin)

| Source | Commit |
|---|---|
| `github.com/eugene-tarassov/vivado-risc-v` (`master`) | `e01cf19f650b5b9d35a26314d3e8a8e13fed469f` ("BootROM version changed to 3.10", after release v3.9.0) |
| Submodule `rocket-chip` (`github.com/ucb-bar/rocket-chip`) | `f517abbf41abb65cea37421d3559f9739efd00a9` |
| Submodule `ethernet/verilog-ethernet` | `baac5f8d811d43853d59d69957975ead8bbed088` |
| Submodule `generators/gemmini` (+ `software/libgemmini`) | `709bc56b6dd859fc2b1a9027a96a0b5be6ad7ed6` (+ `d873aa8b8f39a01bca225044970745632816ce3d`) |
| Submodule `generators/riscv-boom` | `b4283f3c07e1833d50d695dc3fc2b2734726b598` |
| Submodule `generators/sifive-cache` | `8e157c808c8ba019b6fdb42232c4e6ac6b11b439` |
| Submodule `generators/testchipip` | `c94c1e3fa9f7437a3e95f63181cf0f54b8650b3a` |
| rocket-chip `dependencies/cde` | `52768c97a27b254c0cc0ac9401feb55b29e18c28` |
| rocket-chip `dependencies/chisel` | `e3bcc90db37f1aec9f8048813f4f0666098d9bee` |
| rocket-chip `dependencies/diplomacy` | `edf375300d99a4c260a214d7c1553de0040771d7` |
| rocket-chip `dependencies/hardfloat` (+ softfloat/testfloat) | `d93aa570806013dea479a92ba9bb33d1f2d4f69f` (+ `5c06db33fc1e2130f67c045327b0ec949032df1d`, `06b20075dd3c1a5d0dd007a93643282832221612`) |

Not initialized (not needed to generate `system-<board>.v`):
`bare-metal/coremark`, `bare-metal/dhrystone`, `linux-stable`, `opensbi`,
`u-boot`.

## `Rocket64t1` (1-hart, `rocket_linux`)

```scala
class Rocket64t1 extends Config(
  new WithTraceCorePorts ++          // ExposeTraceCorePorts=true -> top ports
  new WithTraceCoreIngressEnabled ++ // RocketCoreConfig(enableTraceCoreIngress=true)
  new WithoutFPU ++
  new WithNBreakpoints(8) ++
  new WithNBigCores(1)    ++
  new RocketBaseConfig)
```

- RV64IMAC, no FPU: DTS ISA string `rv64imaczicsr_zifencei_zihpm_xrocket`,
  `mmu-type = "riscv,sv39"`; **0** hits for
  `FPU|FPUFMAPipe|DivSqrt|MulAddRecFN|hardfloat|fpu` in the generat.
- `retireWidth = 1` -> `iretire` port width 1.
- `RocketBaseConfig`: bootrom `workspace/bootrom.img`, ExtMem 14 GiB from
  `0x8000_0000`, 8 external IRQs, EdgeDataBits 64, CoherentBusTopology, DTS
  compatible `freechips,rocketchip-vivado`.

**Trace ports on the top module** (actively driven, not tied off):
```verilog
output        trace_core_0_group_0_iretire,
output [63:0] trace_core_0_group_0_iaddr,
output [3:0]  trace_core_0_group_0_itype,
output        trace_core_0_group_0_ilastsize,
output [3:0]  trace_core_0_priv,
output [63:0] trace_core_0_tval,
output [63:0] trace_core_0_cause,
output [63:0] trace_core_0_time
```
`itype` is 4-bit (E-Trace vocabulary 0..15); mapping to the 3-bit TIP codes
is done in the shim (`rocket_tci_to_ctte_tip`).

**Board vehicle `nexys-video`:** only the RTL generat is used, not its
Vivado BD/bitstream flow. Board-dependent in the generat: the embedded
bootrom (`module TLROM`) contains the compiled `bootrom/` including a DTB
from `system-nexys-video.dts` (memory node 512 MiB @`0x8000_0000`,
`clock-frequency` 50 MHz / `timebase-frequency` 500 kHz). Core, bus and
trace-path RTL are board-agnostic.

**Known caveats (pre-adapter characterization):**
1. `TraceCoreIngress` maps `trap_return -> ITReturn (13)` instead of the
   expected `ITExcReturn (3)` -- suspected upstream defect, verify in sim.
2. `iretire := valid` with `valid = wb_valid || wb_xcpt`, i.e. **trap beats
   carry `iretire=1`** -- needs a clamp in the shim (same pattern as
   `cva6_iti_to_ctte_tip.sv`).
3. The generat itself was never simulated/run in the predecessor repository -- its own
   gate was a generation/structure gate only (ports/ISA/FPU via grep + a
   clean generation log).

## `Rocket64t2` (2-hart, `rocket2`)

Same source pin as `Rocket64t1` (superrepo + rocket-chip, all submodule
hashes as above); one additional patch layer.

```scala
class Rocket64t2 extends Config(
  new WithTraceCorePorts ++
  new WithTraceCoreContextEnabled ++ // NEW: RocketCoreConfig(enableTraceCoreContext=true)
  new WithTraceCoreIngressEnabled ++
  new WithoutFPU ++
  new WithNBreakpoints(8) ++
  new WithNBigCores(2)    ++         // the only other difference vs. Rocket64t1
  new RocketBaseConfig)
```

`Rocket64t1` itself stays unchanged and is regenerated byte-identically from
the same patched sources.

### The `satp` context sideband -- what it carries, and what it does not

`trace_core_N_context[63:0]` = `csr.io.ptbr.asUInt`, the `satp` register
image: `[63:60] MODE`, `[59:44] ASID`, `[43:0] PPN`.

> **The ASID field is structurally 0 on this pin.** `ASIdBits` is a CDE
> `Field[Int]` with default 0 that neither the superrepo nor the rocket-chip
> subsystem overrides, and at `asIdBits == 0` `CSR.scala` clamps
> `reg_satp.asid` hard to 0 -- in the generat the slice is the literal
> `16'h0`, while `MODE` and `PPN` come from live registers. Raising
> `ASIdBits` is not a one-line change: rocket-chip's TLB does not tag entries
> by ASID at all, so enabling it without also teaching the TLB to flush on
> context switch would leave stale translations after Linux activates its
> ASID allocator. **The ownership key that actually works today is
> `satp.PPN`** -- the root page-table address is unique per address space and
> written by Linux on every context switch; `MODE` additionally separates
> Bare from Sv39. This is exactly the key `rocket_tci_to_ctte_tip`'s
> `TCI_CONTEXT_WIDTH`/`SATP_PPN_LIVE_WIDTH` parameters consume (measured live
> width 22 bit on this generat) -- see the shim's own header and
> `rocket2_soc_synth_wrap.sv`'s "Context width clamp" section for why it is
> self-securing (no live context before the first `satp` write; a filter may
> only arm after it).

### Patch stack (in order; all four patch files live in `patches/` of the
upstream generation tree, not vendored here)

| # | File | Target repo | Content |
|---|---|---|---|
| 1 | `vivado-risc-v_rocket64t1.patch` | superrepo | `ExposeTraceCorePorts` field, `WithTraceCorePorts`, `WithTraceCoreIngressEnabled`, `Rocket64t1`, `trace_core_*` export in `RocketSystemModuleImp` |
| 2 | `rocket-chip_trace_ingress_export.patch` | rocket-chip | `RocketTile.traceCoreParams` override + `traceCoreSourceNode.bundle := core.io.trace_core_ingress.get` |
| 3 | `rocket-chip_trace_core_context.patch` | rocket-chip | `TraceCoreParams.hasContext` + `TraceCoreInterface.context`; `RocketCoreParams.enableTraceCoreContext`; driver `context := csr.io.ptbr.asUInt`; passthrough in the tile override |
| 4 | `vivado-risc-v_rocket64t2.patch` | superrepo | `WithTraceCoreContextEnabled` + `class Rocket64t2` |

## Generation (reproducible; requires a WSL2/Linux sbt+FIRRTL toolchain,
not automated by `fetch.sh` in this repository)

```
# inside a Linux (WSL2) environment with the patched vivado-risc-v checkout:
cd /root/vivado-risc-v
make CONFIG=rocket64t1 BOARD=nexys-video workspace/rocket64t1/system-nexys-video.v
make CONFIG=rocket64t2 BOARD=nexys-video workspace/rocket64t2/system-nexys-video.v
```

Toolchain: OpenJDK 17.0.19, sbt 1.3.13 (`-Xmx12G -Xss8M`), Scala 2.12.10
(sbt) / 2.13 (design), FIRRTL-SFC (`--compiler verilog --custom-transforms
firrtl.passes.InlineInstances --target:fpga`). Bootrom cross-compiler:
prebuilt `riscv64-unknown-elf` from a vivado-risc-v release asset
(`-march=rv64imac -mabi=lp64`).

## Open item for whoever next touches these examples

The generated `system-nexys-video.v` (`RocketSystem` top) is a build
prerequisite this example's `.abc`/TCL flow references by module name but
does not vendor or fetch; obtaining it (via the generation recipe above, on
a host with the WSL2/sbt toolchain) is a manual step outside this
migration's and this script's scope.

## Where the generat actually is (2026-08-18)

The generated blob is **not fetchable** (see above). Without
`system-nexys-video.v` (8 818 498 bytes) the `rocket_linux` and `rocket2`
bitstream flows cannot run at all: `run_rocket_bitstream.tcl` extracts the boot
ROM from it before anything is synthesized.

It is therefore **committed** at
`examples/kv260/third_party/rocket_ref/system-nexys-video.v` (plus the two-hart
variant under `rocket64t2/` and the upstream LICENSE files).

**That is a deliberate exception to how every other reference core is handled
here** (maintainer decision, 2026-08-19). CVA6 is fetched, not committed, because
`third_party/fetch.sh` can get it. This one cannot be fetched *and* cannot be
regenerated from this repository: the recipe above needs four patches that
live upstream and a Linux sbt/FIRRTL toolchain. Keeping it out therefore did
not mean "fetch it yourself", it meant **two of the ten examples were
unbuildable** for anyone who did not already have the file — while the
tutorial's build matrix listed them as building with one command. 17.6 MB is
a cheap price for a matrix that is true.

Licences of the generat, all permissive and all redistributable:
BSD-3-Clause (Regents of the University of California, rocket-chip),
Apache-2.0 (SiFive), MIT (vivado-risc-v), plus the chisel-jtag terms. The
upstream texts sit next to the file as `LICENSE.Berkeley`, `LICENSE.SiFive`,
`LICENSE.jtag` and `LICENSE.vivado-risc-v.md`, byte-identical to delivery;
`REUSE.toml` carries the SPDX expression for the generat itself.
