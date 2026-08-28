<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# cva6_ref -- vendoring pin

Not vendored in this repository (by design: reference
core sources are pinned by commit, not copied into the tree). Fetch with
[`./fetch.sh`](fetch.sh); consumed by the `cva6_linux`, `cva6_linux64` and
`cva6_2` KV260 examples via `cva6_trace_wrap` in
[`../../../rtl/adapters/cva6/`](../../../rtl/adapters/cva6/).

Migrated from an internal predecessor repository
(2026-08-17).

OpenHW Group CVA6 (license: Solderpad 0.51 / Apache-2.0, see the pinned
tree's own `LICENSE*`).

| Source | Commit |
|---|---|
| `github.com/openhwgroup/cva6` (`master`) | `a3dc2c5e7835b25dc8437eee3e956ab12857ead7` |
| Submodule `core/cvfpu` | `3eb6afeab2cb33f7d8689222955d0171aeb3a801` |
| Submodule `core/cache_subsystem/hpdcache` | `b25a1605f5bb1719046e372b0acad3ca9cb7ff42` |

**Included subset:** `core/` (incl. cvfpu, hpdcache), `vendor/pulp-platform/*`
(common_cells, axi, fpga-support, tech_cells_generic, axi_riscv_atomics),
`common/`, `corev_apu/instr_tracing/ITI/` (**`cva6_iti`** -- the E-Trace
v2.0.2 ingress, PR #2927) plus its README. **Not included:** the corev_apu
SoC, `verif/`, the rv_tracer/Encapsulator (reference only), documentation.

**Target configs used by the KV260 examples:**
- `cv32a60x` (`core/include/cv32a60x_config_pkg.sv`, used by `cva6_2` in its
  RV32 build): XLEN=32, NrCommitPorts=1, RVC=1 (SW built without the C
  extension), RVF=0, MmuPresent=0, RVS/RVU=0 (M-only), DCacheType=HPDCACHE_WT.
- `cv32a6_ima_sv32_fpga` (`cva6_linux`): RV32 with MMU (S/U modes), used for
  the single-core Linux boot.
- `cv64a6_imac_sv39_ctrace` (`cva6_linux64`, `cva6_2` RV64 build): new
  FPU-less RV64 config, see delta D6 below.

## Local deltas against upstream

1. **D1 -- `core/cva6_rvfi.sv`: ITI trap visibility.** Upstream is
   `valid_iti = commit_ack`; with `ex_commit_valid`, `commit_ack` does not
   fire, so no exception/interrupt event ever reached `cva6_iti` (measured:
   0 EXC/0 INT beats on ecall + illegal instruction + timer IRQ, only the 68
   retire beats arrived). Delta: port 0 additionally becomes valid on
   `commit_instr_valid[0] && ex_commit_valid && !commit_drop[0]`; the itype
   classification (EXC/INT) is done by the `itype_detector` itself. Trap
   beats carry `iretire=0`, set in the shim (`cva6_iti_to_ctte_tip`).
   **Upstream-worthy** (a bug class adjacent to PR #3010, not covered there).
2. **D2 -- `ITI/cva6_iti/itype_detector.sv`: interrupt priority.** Upstream
   checks `exception` before `interrupt`; `ex_valid` is also set on
   interrupts, so every interrupt was classified as `EXC` (measured: timer
   IRQ as itype=1/cause=7 instead of itype=2). Delta: order swapped
   (`interrupt` first; distinguished via the mcause MSB). **Upstream-worthy.**
3. **D3 -- `core/include/cv32a60x_config_pkg.sv`: `TechnoCut 1->0`.**
   Upstream's `cv32a60x` sets `TechnoCut=1`, routing icache SRAMs through
   `tc_sram_wrapper_cache_techno` (an ASIC-swap shell whose content sits in
   `translate_off`) -- a black box for FPGA implementation (DRC INBB-3). `0`
   instantiates `tc_sram` directly (Vivado BRAM inference); simulation
   behavior is unchanged (the `translate_off` path instantiated the same
   `tc_sram`). FPGA-specific, not upstream-worthy (the shell is intentional
   for ASIC flows there).
4. **D4 -- `core/cva6_mmu/cva6_mmu.sv`: reversed part-select at XLEN=32.**
   Line 400 uses `fetch_vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.GPLEN]`. At RV32,
   `VLEN = 32` but `GPLEN = 34` (`build_config_pkg.sv:37`), so the
   part-select `[31:34]` runs **backwards** and XSIM aborts elaboration
   (`VRFC 10-1219 part-select direction is opposite`). The term is dead per
   `CVA6Cfg.IS_XLEN64` but is still elaborated. Delta: clamp the lower bound
   via a `localparam GPLEN_LO` (RV64 unchanged; RV32 becomes `[31:31]` in an
   unreachable expression). **Upstream-worthy** -- hits any RV32
   configuration WITH an MMU, i.e. exactly the Linux class; invisible in the
   M-only `cv32a60x` because the MMU is generated away there.
5. **D5 -- `core/include/cv32a6_ima_sv32_fpga_config_pkg.sv`: address regions
   moved to the KV260.** Upstream describes the Genesys2 board here
   (`ExecuteRegion` = `0x8000_0000` +1 GiB plus bootrom/DM, `CachedRegion`
   likewise). On the KV260 the CVA6 window sits in the reserved PS-DDR range
   at `0x6400_0000`; with the upstream rules that memory is simply not
   executable (first fetch takes an Instruction Access Fault, mcause 1,
   `itype 1` at `iaddr = 0x64000000` in the ITI log). Delta: Execute/Cached
   moved to `0x6400_0000` +64 MiB, NonIdempotent set to the peripheral window
   `0x0200_0000..0x1000_1000` (CLINT/UART: no speculative accesses to
   registers with side effects). **Not upstream-worthy** -- pure platform
   configuration, like D3.
   - **D5 addendum (region length follows the guest RAM):** the region
     lengths were later grown to `0x0C00_0000` (192 MiB, matching the guest
     RAM), then the `CachedRegionLength` specifically was walked back to a
     conservative `0x0400_0000` (64 MiB) after cacheable memory above
     `0x6800_0000` correlated with a board hang within ~5 s (cache-line
     bursts on the PS HP port); `ExecuteRegionLength` stayed at 192 MiB. The
     correlation is empirical, not proven. **Correspondence rule:** this
     length, `DRAM_SIZE` in `cva6_linux_soc_top`/`cva6_linux64_soc_top`, the
     `memory` node in the matching `sw/<top>/*.dts`, and the
     `reserved-memory` window must change together.
6. **D6 -- `core/include/cv64a6_imac_sv39_ctrace_config_pkg.sv`: new FPU-less
   RV64 config.** Not a patch to an upstream file but an additional config
   (copied from `cv64a6_imafdc_sv39_config_pkg.sv`): RVF/RVD=0 (cvfpu
   generated away), CvxifEn=0, BExt=0 and ZKN=0 (`build_config_pkg.sv:70`
   otherwise forces `RVB=1` back on), NrCommitPorts=1 (the single-port
   contract of `cva6_trace_wrap`/the ITI shim), address regions on the KV260
   window analogous to D5 (Execute/Cached `0x6400_0000` +`0x0C00_0000`,
   NonIdempotent `0x0200_0000` +`0x0E00_1000`). **Re-evaluate the cached
   length against the D5 addendum's 64 MiB board-tested value before any
   bitstream** -- the config as written carries 192 MiB. Not upstream-worthy
   (an Accemic integration configuration, like D5).

7. **D7 -- `counter.sv` name clash, resolved by two `sed` steps rather than
   a patch.** Two transformations that `fetch.sh` performs and that were
   missing from this list until 2026-08-21 -- which made the list wrong
   rather than incomplete: someone comparing the patch series against the
   fetched tree would have found changes with no delta behind them.
   - `core/cache_subsystem/counter.sv` is **staged as a copy** named
     `pulp_counter.sv`, module and `endmodule :` label renamed
     (`fetch.sh:45-50`). The reason is a name clash: the PULP `axi` vendor
     tree brings its own `counter`, and the file list excludes
     `counter.sv`.
   - `axi_err_slv.sv` and `axi_burst_splitter.sv` are **retargeted in
     place** from `counter #` to `pulp_counter #` (`fetch.sh:55-61`).
   Neither is a patch file, on purpose: both are mechanical renames that a
   context diff would break on at every upstream bump, while the `sed`
   expressions survive it. The price is that they are invisible in
   `patches/cva6/` -- hence this entry. **Note `axi_burst_splitter.sv`
   carries BOTH**: this rename and patch `06`, which are unrelated (the
   patch adds the XSIM guard, see the ID note below).

**A note on delta IDs, so nobody trusts them too far.** The IDs are not
unique across all the places they appear. Patch `06-axi_burst_splitter.patch`
labels its change "D6 (Accemic)" -- meaning the XSIM `default disable iff`
guard -- while D6 in *this* list is the FPU-less RV64 config package. The
same duplication exists for D3. The IDs were assigned in two different
contexts and never reconciled; renaming them now would mean editing patch
text that has to stay byte-compatible with the already-patched tree, or
`fetch.sh` fails its reverse check and exits 3. **When quoting a delta, name
the file, not just the ID.**

**Correspondence rule (repeated, binding for every KV260 CVA6 example):**
the cached-region length, this example's `DRAM_SIZE` parameter, the guest
`.dts` `memory` node and the `reserved-memory` window are one fact recorded
in four places -- change them together.
