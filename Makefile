# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# CEDARtools.TraceEncoder (CTTE) top-level Makefile.

.DEFAULT_GOAL := help
SHELL := /bin/bash

# Coverage. `make coverage` re-runs the whole suite with this set to
# `--coverage`, so every `abc ... -sim` below builds with Verilator line
# coverage and drops a coverage_<top>.dat in its work dir. Plain `make sim`
# leaves it empty, so the suite runs uninstrumented (instrumentation is
# slower). scripts/coverage_report.sh then merges all the data into one rate.
ABC_COV ?=
COV_DIR := bld/coverage

# Windows/MSYS2: the Verilator binary reports its data directory as an
# MSYS-internal POSIX path (/ucrt64/share/verilator) that the Windows process
# itself cannot open, so every `abc -sim` aborts with "Cannot find
# verilated_std.sv". Derive a native path from the binary location instead.
# On Linux this stays empty and Verilator's built-in default applies.
ifeq ($(OS),Windows_NT)
VERILATOR_ROOT ?= $(shell d=$$(command -v verilator 2>/dev/null); \
                          [ -n "$$d" ] && cd "$$(dirname "$$d")/../share/verilator" 2>/dev/null && pwd -W 2>/dev/null)
export VERILATOR_ROOT
endif

# ------------------------------------------------------------ toolchain ----
# Every sim target below runs `abc`, and abc is a Python program whose shebang
# is `#!/usr/bin/env python3`. This Makefile ASSUMED that name resolves to an
# interpreter. On Windows it usually does not: `python3` and `python` on PATH
# are the Microsoft Store stubs, which print an installation hint and run
# nothing. `make sim` then reported 19 FAIL out of 19 on a healthy tree
# (measured 2026-08-12) -- and the hint that says why scrolls past inside the
# per-test output, so the summary a reader keeps is "the encoder is broken".
#
# scripts/ct_env.sh already heals all three spellings (bld/pyshim wrappers,
# ct_need_python) and locates the abc driver (ct_need_abc). Two halves use it:
#
#   $(ABC)      establishes the toolchain IN THE RECIPE that needs it. Every
#               recipe line is its own shell, so this has to happen per line;
#               $(ABC) is the single definition they all spell out.
#   CT_ENV_OK   a parse-time PROBE, whose only consumer is the ct-tools gate
#               below. It reports; it does not repair.
#
# The probe deliberately does NOT export a repaired PATH back into make, which
# was the first version of this block and is wrong on Windows: make here is a
# NATIVE program whose PATH is `C:\...;C:\...`, while the PATH bash reports is
# `/c/...:/c/...`. Exporting the latter made make's own CreateProcess lookup
# fail -- measured 2026-08-13, `make help` died with
#     process_begin: CreateProcess(NULL, awk ...) failed
# on a host where awk is right there. A fix that breaks a working target is
# not a fix.
#
# `bash -c` explicitly: ct_env.sh needs bash (BASH_SOURCE, local) and $(shell)
# is not guaranteed to use one -- on a host whose /bin/sh is dash, an implicit
# shell would fail HERE and report a toolchain problem on a healthy machine.
# stderr is kept (bld/ct_env.log) instead of printed: the diagnosis belongs to
# the target that needs the tool, not to `make help`.
CT_ENV_LOG := bld/ct_env.log
CT_ENV_OK := $(shell mkdir -p bld 2>/dev/null; \
	bash -c '. "$(CURDIR)/scripts/ct_env.sh" && ct_need_abc' \
	>/dev/null 2>$(CT_ENV_LOG) && echo ok)
ABC := . "$(CURDIR)/scripts/ct_env.sh" && ct_need_abc && abc

# The same disease, one layer over: the twelve `check-*` drift guards each
# carried their own copy of
#
#     PY=""; for c in py python3 python; do command -v "$$c" ... done; \
#     "$${PY:-python}" scripts/check_<x>.py
#
# which tests PRESENCE, not function, and falls back to bare `python`. On
# Windows both `python3` and `python` on PATH are the Microsoft Store stub:
# present, and it runs nothing. Measured 2026-08-13 on this host with `py`
# taken off PATH:
#
#     make check-xsim
#     Python was not found; run without arguments to install ...
#     make: *** [Makefile:476: check-xsim] Error 49
#
# (the stub answers in the host locale -- the line above is the English wording
# of the message this host actually printed)
#
# "Error 49" from a drift guard reads as DRIFT -- a verdict about an RTL/doc
# consistency nobody checked. ct_need_python (scripts/ct_env.sh) probes the
# FUNCTION (`-c ""`), heals all three spellings via bld/pyshim, and dies with
# 78 when there is no interpreter at all. One definition, twelve users.
PY := . "$(CURDIR)/scripts/ct_env.sh" && ct_need_python && python3

.PHONY: rdl-soc rdl-kv260 rdl-html sim-tgc5b-soc sim-examples help rdl ct-tools sim sim-basic sim-interrupts sim-stress sim-periodic-sync sim-exceptions sim-sync-quota-bytes sim-sync-quota-msgs sim-data-basic sim-data-split sim-addr-compress sim-data-sync sim-df-workload sim-df-workload-full sim-df-drop sim-trig-regs sim-te-sync-req sim-overrun-recovery sim-hsi-csr-cap sim-combined coverage lint check-flags check-discovery check-profile-deps check-core-xlen check-xsim check-negative-legs check-micro-csr check-swwel-census check-publication check-drawio check-doc-evidence check-evidence-stamp check-sim-fmt check-orphan-gates check-sva-channel check-rdl-encode doc-check clean bld-bootstrap bld-refresh

## help: List available targets.
help:
	@echo "CEDARtools.TraceEncoder — available make targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^## / { sub(/^## /,""); print "  " $$0 }' $(MAKEFILE_LIST)
	@echo ""

## rdl:    Regenerate the PeakRDL-derived SystemVerilog (via scripts/gen_rdl.sh).
##          Outputs rtl/pkg/ct_cs_cpuif*.sv + tests/lib/ct_cs_cpuif_wb_helper.sv.
##          Toolchain pinned in rdl/requirements.txt (auto-installed into a
##          local .venv-rdl/). Commit the RDL change + regenerated SV together.
rdl:
	@scripts/gen_rdl.sh

# ct-tools (internal, no help entry): the gate in front of every simulation
# target. It does not run a tool, it refuses to start when the toolchain above
# could not be established -- and it refuses in the one wording that keeps the
# two cases apart:
#
#   "a test failed"        -> the encoder or the testbench is wrong
#   "TOOL / nothing ran"   -> this machine cannot run the test at all
#
# The exit code is 78 (CT_E_TOOL, scripts/ct_env.sh), the code
# scripts/run_gates.sh reports as `TOOL  <gate>` and `make bld-bootstrap`
# already returns. make itself always exits 2 for a failed recipe, so the 78
# is carried by make's own "Error 78" line plus the TOOL: message -- not
# silently, and never as a pass: the recipe FAILS, it does not skip.
ct-tools:
ifeq ($(CT_ENV_OK),)
	@echo "TOOL: the simulation toolchain could not be established -- nothing was run."
	@echo "  This is NOT a test failure. scripts/ct_env.sh reports:"
	@sed 's/^/    /' $(CT_ENV_LOG) 2>/dev/null || echo "    (no $(CT_ENV_LOG))"
	@echo "  Fix the tool, or set CT_PYTHON_BIN / CT_ABC_BIN, then re-run."
	@exit 78
endif

## rdl-soc: Regenerate the example SoC peripheral regblock from its rdl/ct_soc.rdl
##          (via scripts/gen_rdl_soc.sh) -> examples/kv260/common/tgc5b/pkg/ct_soc_regs*.sv.
##          Same pinned toolchain as `rdl`. Commit RDL + regenerated SV together.
rdl-soc:
	@scripts/gen_rdl_soc.sh

## rdl-kv260: Regenerate the unified KV260 example-SoC CTRL block from
##          examples/kv260/common/rdl/ct_kv260_ctrl.rdl via
##          examples/kv260/common/rdl/gen_rdl_kv260.sh ->
##          examples/kv260/common/ct_kv260_ctrl_regs*.sv. Same pinned
##          toolchain as `rdl`. Commit RDL + regenerated SV together.
rdl-kv260:
	@examples/kv260/common/rdl/gen_rdl_kv260.sh

## rdl-html: Render the browsable HTML register reference (via
##          scripts/gen_rdl_html.sh) -> bld/rdl-html/: the KV260 example-SoC
##          app map (absolute devmem addresses, encoder CSRs included), the
##          bare encoder CSR map, and the unified KV260 CTRL window
##          (examples/kv260/common/rdl/). Same pinned toolchain as `rdl`.
rdl-html:
	@scripts/gen_rdl_html.sh

## sim:    Run all top-level testbenches and print a PASS/FAIL summary.
##          Every test runs even if an earlier one fails. Tests listed in
##          SIM_XFAIL are known-failing regression gates (for an unfixed
##          encoder bug): they run and are shown as XFAIL, but do not fail
##          `make sim`. The run exits non-zero iff a normal test FAILs or an
##          XFAIL test unexpectedly passes (XPASS — fix landed; promote it out
##          of SIM_XFAIL). Run one test with its own `make sim-<name>`.
SIM_ALL   := basic interrupts stress periodic-sync exceptions sync-quota-bytes sync-quota-msgs data-basic data-split addr-compress data-sync df-workload df-workload-full df-drop trig-regs te-sync-req overrun-recovery hsi-csr-cap combined
# Empty: every test in SIM_ALL is expected to pass. Add a name here (with a
# comment naming the defect it gates) only while an encoder fix is pending —
# the test then runs and is reported as XFAIL instead of failing the suite.
SIM_XFAIL :=

# The worked integrations under examples/ -- run by `make sim-examples`, kept
# out of SIM_ALL so `make sim` stays the encoder's own regression suite.
SIM_EXAMPLES := tgc5b-soc ddr-sink-window axis-wp-shim tgc5b2-axis-soc ctte-smoke rvcfi-units rvcfi-e2e

sim: ct-tools
	@rm -f bld/.decode_skipped
	@overall=0; declare -A st; xfail=" $(SIM_XFAIL) "; \
	declare -A dir=( \
		[basic]=instruction/01_basic \
		[interrupts]=instruction/02_interrupts \
		[stress]=instruction/03_stress \
		[periodic-sync]=instruction/04_periodic_sync \
		[exceptions]=instruction/05_exceptions \
		[sync-quota-bytes]=instruction/29_sync_quota_bytes \
		[sync-quota-msgs]=instruction/30_sync_quota_msgs \
		[data-basic]=data/01_basic \
		[data-split]=data/02_split_load \
		[addr-compress]=data/03_addr_compress \
		[data-sync]=data/04_data_sync \
		[df-workload]=data/05_df_workload \
		[df-workload-full]=data/05_df_workload \
		[df-drop]=data/06_df_drop \
		[trig-regs]=instruction/32_trig_regs \
		[te-sync-req]=instruction/33_te_sync_req \
		[overrun-recovery]=overflow/01_overrun_recovery \
		[hsi-csr-cap]=hsi/01_csr_cap \
		[combined]=combined/01_all ); \
	for t in $(SIM_ALL); do \
		printf '\n===================== tests/%s =====================\n' "$${dir[$$t]}"; \
		if $(MAKE) --no-print-directory sim-$$t; then res=PASS; else res=FAIL; fi; \
		if [[ "$$xfail" == *" $$t "* ]]; then \
			if [ "$$res" = FAIL ]; then st[$$t]=XFAIL; else st[$$t]=XPASS; overall=1; fi; \
		else \
			st[$$t]=$$res; if [ "$$res" = FAIL ]; then overall=1; fi; \
		fi; \
	done; \
	printf '\n======================= make sim summary =======================\n'; \
	cat=""; \
	for t in $(SIM_ALL); do \
		d="$${dir[$$t]}"; c="$${d%%/*}"; sub="$${d#*/}"; \
		if [ "$$c" != "$$cat" ]; then printf '  tests/%s/\n' "$$c"; cat="$$c"; fi; \
		printf '    %-5s %s\n' "$${st[$$t]}" "$$sub"; \
	done; \
	printf '================================================================\n'; \
	skipped=0; \
	if [ -f bld/.decode_skipped ]; then \
		skipped=$$(sort -u bld/.decode_skipped | wc -l); \
		printf '  NOTE: no reference decoder -- %d test(s) SIMULATED but NOT decoded:\n' "$$skipped"; \
		sort -u bld/.decode_skipped | sed 's/^/          /'; \
		printf '        provision CTTD (py scripts/fetch_cttd.py) for a decode verdict.\n'; \
		printf '================================================================\n'; \
	fi; \
	if [ $$overall -eq 0 ]; then \
		if [ $$skipped -gt 0 ]; then \
			printf '  RESULT: PASS  (SIMULATION ONLY -- decode verdict skipped for %d test(s))\n\n' "$$skipped"; \
		elif [ -n "$(SIM_XFAIL)" ]; then \
			printf '  RESULT: PASS  (XFAIL, expected: %s)\n\n' "$(SIM_XFAIL)"; \
		else \
			printf '  RESULT: PASS\n\n'; \
		fi; \
	else \
		printf '  RESULT: FAIL — %s\n\n' "$$(for t in $(SIM_ALL); do if [ "$${st[$$t]}" = FAIL ] || [ "$${st[$$t]}" = XPASS ]; then printf 'tests/%s(%s) ' "$${dir[$$t]}" "$${st[$$t]}"; fi; done)"; \
		exit 1; \
	fi

## sim-basic: tests/instruction/01_basic — sim + CTTD decode + address match.
##              Exercises instruction-trace pause/resume; trace-off emits a
##              Program Trace Correlation Message (TCODE 33, EVCODE=Program
##              Trace Disabled). --pc checks the PC stream, --disabled the
##              trace-off message.
sim-basic: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/01_basic/basic_tb.abc
	@scripts/decode_and_check.sh --pc --disabled basic_tb

## sim-interrupts: tests/instruction/02_interrupts — sim + CTTD decode + address match.
sim-interrupts: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/02_interrupts/interrupts_tb.abc
	@scripts/decode_and_check.sh --pc --disabled interrupts_tb

## sim-stress: tests/instruction/03_stress — instruction-trace stress.
##              Merges the former 03 (periodic sync + HIST_OVERFLOW, direct
##              branches) and 04 (indirect branch right after a HIST flush) into
##              one scenario that also mixes inferable CALLs and RETURNs. It is a
##              regression gate for the branch-HIST sync-seed bug (periodic sync
##              on a TAKEN branch seeded a stranded HIST bit -> "hist bits
##              pending"); see the seed guard in rtl/ct_L2_msg_gen.sv.
sim-stress: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/03_stress/stress_tb.abc
	@scripts/decode_and_check.sh --pc stress_tb

## sim-periodic-sync: tests/instruction/04_periodic_sync — periodic-sync HIST loss.
##              Regression gate for the cf_sync_hist_flush_hold path in
##              rtl/ct_L2_msg_gen.sv (lines 87–99, 165–172). The
##              NEXUS_MSG_PROGRAM_TRACE_SYNC (TCODE 9) wire format carries
##              SYNC + ICNT + FADDR only — NO HIST. Without the pre-flush, a
##              periodic sync in BRANCH_HIST mode would clear Hist as part of
##              the sync reset and the decoder would lose every conditional
##              branch direction accumulated since the previous HIST flush.
##              The encoder holds the sync eTIP back one cycle and emits a
##              ResourceFull RCODE=1 first when HistCount > 1. This test
##              drives a 2-L + 1-BD loop (3 retires/iter) with a 16-cycle
##              periodic-sync window so syncs reliably fall on a linear
##              retire with Hist populated — the exact regime that exposes
##              the bug on hardware (earlier board captures taken with a
##              predecessor integration that pre-dates this fix). A clean
##              decode here confirms the pre-flush still fires.
sim-periodic-sync: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/04_periodic_sync/periodic_sync_tb.abc
	@scripts/decode_and_check.sh --pc periodic_sync_tb

## sim-exceptions: tests/instruction/05_exceptions — synchronous exceptions,
##              including the illegal-instruction shape where the faulting
##              instruction NEVER retires (iretire=0) but its iaddr/ilastsize
##              are still communicated. Exercises the iretire=0 EXCEPTION_TRAP
##              count_halfwords branch (uncovered by 02_interrupts, which uses
##              iretire=1) and an iretire=0 exception right after a taken branch.
sim-exceptions: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/05_exceptions/exceptions_tb.abc
	@scripts/decode_and_check.sh --pc --disabled exceptions_tb

## sim-sync-quota-bytes: tests/instruction/29_sync_quota_bytes — byte-quota sync
##              (P2). InstSyncMode=4 (TRACE_BYTES), InstSyncMax=2 -> 64-B quota
##              window, driven over ALTERNATING compressibility (long linear
##              runs vs. uninferable-jump storms) — exactly the workload shape
##              where instruction-count sync (mode 6) gives no byte guarantee.
##              --pc checks losslessness; --sync 7 the guaranteed sync floor
##              (derivation in the TB header). The hard window bound
##              (max distance <= 2^(Max+4) + Delta, measured on RAW ATB
##              bytes — the scale the quota is defined on) is checked by
##              scripts/check_sync_window.py via scripts/cli_syncquota_test.sh
##              (Delta derivation documented there).
sim-sync-quota-bytes: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/29_sync_quota_bytes/sync_quota_bytes_tb.abc
	@scripts/decode_and_check.sh --pc --sync 7 sync_quota_bytes_tb

## sim-sync-quota-msgs: tests/instruction/30_sync_quota_msgs — message-quota sync
##              (P2, collision design D8). InstSyncMode=1 (TRACE_MSG), Max=0 ->
##              16-message quota window, colliding with an ACT-CAP CF_SYNC and
##              an (architecturally ignored, mode-gated) ATB sync request. The
##              TB itself $fatals unless trTeSyncStatus.SyncReqSource reads 3
##              (SYNC_REQ_QUOTA) at test end. --pc checks losslessness;
##              --sync 4 the guaranteed floor (derivation in the TB header).
sim-sync-quota-msgs: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/30_sync_quota_msgs/sync_quota_msgs_tb.abc
	@scripts/decode_and_check.sh --pc --sync 4 sync_quota_msgs_tb

## sim-data-basic: tests/data/01_basic — sim + CTTD data-trace check.
##                  Instruction trace is OFF in this scenario; verification
##                  compares the cpu_model's load/store sequence (address,
##                  size AND data value) against the CTTD CTXP export
##                  (MEMREAD_n / MEMWRITE_n records).
sim-data-basic: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/data/01_basic/data_basic_tb.abc
	@scripts/decode_and_check.sh --ctxp data_basic_tb

## sim-data-split: tests/data/02_split_load — SPLIT_DATA_ACCESS=1 leg
##              (STOREs at dretire, LOADs at lresp; pending-overwrite path).
##              --pc + --data round-trip; the data oracle encodes the
##              split-load contract (the lresp-less 0x8000_0300 load is
##              overwritten and never emits). Not --ctxp: split-load MEM
##              record values come from the TB-driven lresp data, which
##              cpu_model cannot see (rationale in the TB header).
sim-data-split: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/data/02_split_load/split_load_tb.abc
	@scripts/decode_and_check.sh --pc --data split_load_tb

## sim-addr-compress: tests/data/03_addr_compress — P3 DF address XOR
##              compression, data-only stream. WARL negative probes run
##              in-sim ($fatal); offline: --data + --ctxp (reconstructed
##              FULL addresses + values) + --sync 2 (the two 13/14
##              re-anchors count as synchronizing messages). The
##              TCODE-sequence structure checks live in
##              scripts/cli_dfcompress_test.sh.
sim-addr-compress: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/data/03_addr_compress/addr_compress_tb.abc
	@scripts/decode_and_check.sh --data --ctxp --sync 2 addr_compress_tb

## sim-data-sync: tests/data/04_data_sync — P3 13/14 re-anchor contract in a
##              combined stream with overflow: T2(a) CF_SYNC re-anchor and
##              T2(c) ERROR re-anchor, timestamps ON. Soft PC/data (the
##              storm intentionally loses bytes), --overflow HARD; the hard
##              first-DF-after-ERROR + subsequence + --tsmono gates run in
##              scripts/cli_dfcompress_test.sh.
sim-data-sync: ct-tools | bld
	@mkdir -p bld/data_sync_tb.vsim
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim ../tests/data/04_data_sync/data_sync_tb.abc \
		2>&1 | tee data_sync_tb.vsim/data_sync_tb.sim.log
	@scripts/decode_and_check.sh --soft --pc --data --overflow data_sync_tb

## sim-df-workload: tests/data/05_df_workload — P3 step-6 bandwidth workload,
##              XOR leg: 10 336 deterministic data accesses (sequential +
##              scattered + stack mix), data-only stream, hard --data
##              oracle compare. The FULL/XOR byte accounting and the
##              cross-leg gates live in scripts/cli_dfworkload_test.sh.
sim-df-workload: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/data/05_df_workload/df_workload_tb.abc
	@scripts/decode_and_check.sh --data df_workload_tb

## sim-df-workload-full: tests/data/05_df_workload — the DataAddrCompress=FULL
##              baseline leg of the same workload (identical access
##              sequence, uncompressed DF addresses).
sim-df-workload-full: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/data/05_df_workload/df_workload_full_tb.abc
	@scripts/decode_and_check.sh --data df_workload_full_tb

## sim-df-drop: tests/data/06_df_drop — P7 data-trace drop policy
##              (`trTeDataControl.DataDropEna`) + the G12 overflow status
##              bits. The status contract (set / RW1C / clear-on-enable) is
##              self-checking in sim ($fatal). `abc -sim` cannot pass
##              plusargs, so the DROP leg is the testbench DEFAULT: this
##              target verifies that the instruction trace survived the drop
##              episode intact (--pc HARD — that is the whole point of the
##              policy) and that the loss was announced (--overflow). The
##              OFF/DROP contrast and the marker shape (ONE Error, ECODE
##              0x02, NO SYNC=7) live in scripts/cli_dfdrop_test.sh.
sim-df-drop: ct-tools | bld
	@mkdir -p bld/df_drop_tb.vsim
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim ../tests/data/06_df_drop/df_drop_tb.abc \
		2>&1 | tee df_drop_tb.vsim/df_drop_tb.sim.log
	@scripts/decode_and_check.sh --pc --overflow df_drop_tb

## sim-trig-regs: tests/instruction/32_trig_regs — P7 TCI trigger
##              configuration registers (te 0x050/0x054/0x058). The WARL and
##              "trigger does not exist" negatives are self-checking in sim
##              ($fatal) and run in EVERY leg, so the testbench default (all
##              trigger actions at their reset value) already exercises them;
##              --pc additionally checks that the reset configuration is
##              behaviourally inert. The six-leg action matrix lives in
##              scripts/cli_trigregs_test.sh.
sim-trig-regs: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/32_trig_regs/trig_regs_tb.abc
	@scripts/decode_and_check.sh --pc --sync 1 trig_regs_tb

## sim-te-sync-req: tests/instruction/33_te_sync_req — P8 explicit sync
##              request over the TE register (trTeControl.InstSyncReq). The
##              write-1/read-0 field contract and the SyncReqSource read-backs
##              are self-checking in sim ($fatal) in EVERY leg; the default
##              (no request at all) is the negative leg, so --pc here checks
##              that a build with the feature compiled IN traces exactly as
##              before while nobody writes the bit. The ten-leg matrix
##              (request, activity control, two- and three-write bursts,
##              CF_SYNC collision, quota -- inside and after the window --,
##              overflow) lives in scripts/cli_tesyncreq_test.sh.
sim-te-sync-req: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/instruction/33_te_sync_req/te_sync_req_tb.abc
	@scripts/decode_and_check.sh --pc te_sync_req_tb

## sim-overrun-recovery: tests/overflow/01_overrun_recovery — sim + CTTD
##              decode (soft). Combined regression for the full overrun
##              lifecycle: ATB stall + dense CF storm with interleaved data
##              accesses triggers the composer's QueueOverrun injection; the
##              test then verifies (a) post-recovery decodability (the
##              scenarios_a3 IBH desync signature, hot-checked by an
##              uninferable indirect jump after the FIFO_OVERRUN sync), AND
##              (b) the soft-reset recovery path (ct_cs_rst toggled, encoder
##              re-programmed, fresh CF + data activity decode cleanly).
##              Soft mode: heavy overrun cascade intentionally loses bytes
##              so PC + data divergence is reported but not failed.
##              --overflow is HARD: the encoder MUST emit a
##              NEXUS_MSG_ERROR(QueueOverrun) — otherwise the ovf_injector
##              path never fired and the test is meaningless.
sim-overrun-recovery: ct-tools | bld
	@mkdir -p bld/overrun_recovery_tb.vsim
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim ../tests/overflow/01_overrun_recovery/overrun_recovery_tb.abc \
		2>&1 | tee overrun_recovery_tb.vsim/overrun_recovery_tb.sim.log
	@scripts/decode_and_check.sh --soft --pc --data --overflow --disabled overrun_recovery_tb

## sim-hsi-csr-cap: tests/hsi/01_csr_cap — ACT-CAP CSR-based instrumentation.
##              Fires the full ACT-CAP command set via the ACT-CAP CSR (0x0B10):
##              every DAQ_* command routed to BOTH sinks (AXIS_NEXUS), plus one
##              CF_SYNC (Nexus only). The AXIS beat (command + payload) is
##              verified in-sim (self-checking; $fatal on mismatch). Offline:
##                --ctxp     : the CTTD CTXP export of the DAQ records
##                             (DAQ_DATA / DAQ_COUNTER / DAQ_LAST_PC / SYNC /
##                             MEMx_n) matches the cpu_model's expected.ctxp.
##                --sync 2   : >= 2 sync messages (startup + CF_SYNC).
sim-hsi-csr-cap: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/hsi/01_csr_cap/csr_cap_tb.abc
	@scripts/decode_and_check.sh --ctxp --sync 2 csr_cap_tb

## sim-combined: tests/combined/01_all — instruction + data + ACT-CAP sync.
##              Mixed workload (linear, branch, call/return, varied
##              loads/stores, ACT-CAP CF_SYNC) with the timestamp unit ON.
##              One CTTD decode, five checks:
##                --pc       : reconstructed PC stream matches the model.
##                --data     : DataRead/DataWrite sequence matches.
##                --sync 3   : >= 3 sync messages (startup + mid CF_SYNC + final).
##                --disabled : trace-off correlation message present.
##                --tsmono   : reconstructed absolute timestamps never step back
##                             (guards the CSR-induced ACT-CAP sync timestamp).
##              (Not --ctxp: with instruction AND data tracing both on, the
##              data-trace messages flush ahead of the buffered instruction
##              messages, so the CTXP record order is not program order — a
##              strict line diff does not apply. The pure-memory data/01_basic
##              and the DAQ hsi/01_csr_cap tests use --ctxp. --tsmono only reads
##              the per-record timestamp column, which advances regardless of
##              record interleaving, so it applies here.)
sim-combined: ct-tools | bld
	@cd bld && $(ABC) $(ABC_COV) -sim ../tests/combined/01_all/combined_tb.abc
	@scripts/decode_and_check.sh --pc --data --sync 3 --disabled --tsmono combined_tb

## sim-tgc5b-soc: examples/kv260/common/tgc5b — the shared TGC5B library wired
##          into a full SoC (MINRES TGC5B core + CEDARtools.TraceEncoder + RAM
##          + timer/INTC) running the committed hello_trace program. This is the
##          regression bench for RTL that EIGHT kv260 examples synthesise, which
##          is why it outlived the tgc5b_soc example it came from. Confirms the
##          real core drives the encoder and it emits a decodable N-Trace
##          synchronization message (hard check). The exact golden PC
##          cross-check is reported (--soft) — see
##          examples/kv260/common/tgc5b/README.md.
sim-tgc5b-soc: ct-tools | bld
	@cp examples/kv260/common/tgc5b/prog/hello_trace.hex    examples/kv260/common/tgc5b/prog/prog.hex
	@cp examples/kv260/common/tgc5b/prog/hello_trace.pcinfo examples/kv260/common/tgc5b/prog/prog.pcinfo
	@cd bld && $(ABC) $(ABC_COV) -sim ../examples/kv260/common/tgc5b/test/ct_soc_tb.abc
	@scripts/decode_and_check.sh --sync 1 ct_soc_tb
	@scripts/decode_and_check.sh --soft --pc ct_soc_tb || true

## sim-examples: Run every worked integration under examples/ and print a
##          PASS/FAIL summary — the list is the SIM_EXAMPLES variable above,
##          not a fixed set named here: naming it twice is how the two got to
##          disagree, and a line number is just a slower way to disagree. Needs
##          only abc + a simulator (the program artifacts are committed, so no
##          RISC-V toolchain), which is why CI runs this next to `make sim`.
sim-examples:
	@if [ -z "$(strip $(SIM_EXAMPLES))" ]; then \
		echo 'sim-examples: SIM_EXAMPLES is empty -- refusing to report PASS over'; \
		echo '  an empty list. That is exactly how an earlier merge produced a green'; \
		echo '  verdict for a run that executed nothing: the variable sat in a'; \
		echo '  conflicted hunk, -X ours dropped it, and a loop over nothing left'; \
		echo '  overall=0.'; \
		exit 1; \
	fi
	@overall=0; declare -A st; \
	for t in $(SIM_EXAMPLES); do \
		printf '\n===================== examples: sim-%s =====================\n' "$$t"; \
		if $(MAKE) --no-print-directory sim-$$t; then st[$$t]=PASS; else st[$$t]=FAIL; overall=1; fi; \
	done; \
	printf '\n=================== make sim-examples summary ==================\n'; \
	for t in $(SIM_EXAMPLES); do printf '    %-5s sim-%s\n' "$${st[$$t]}" "$$t"; done; \
	printf '===============================================================\n'; \
	if [ $$overall -eq 0 ]; then \
		printf '  RESULT: PASS\n\n'; \
	else \
		printf '  RESULT: FAIL — %s\n\n' "$$(for t in $(SIM_EXAMPLES); do if [ "$${st[$$t]}" = FAIL ]; then printf 'sim-%s ' "$$t"; fi; done)"; \
		exit 1; \
	fi

## coverage: Re-run the whole suite under Verilator line coverage, merge every
##            test's data, and print one suite-wide line-coverage rate. Also
##            writes bld/coverage/: merged.info (lcov), an HTML report, and a
##            shields endpoint JSON (coverage-badge.json) ready for a badge.
##            The suite still runs even if a test FAILs, so the rate reflects
##            whatever data was produced (failures are reported, not swallowed).
coverage: ct-tools
	@$(MAKE) --no-print-directory sim ABC_COV=--coverage \
		|| echo "  (note: a test FAILed — coverage computed from the data produced)"
	@scripts/coverage_report.sh $(COV_DIR)

bld:
	@mkdir -p bld

## lint:   Run the flag + discovery drift guards, then verible-verilog-lint
##          over rtl/ and tests/ (rules in .rules.verible_lint).
lint:
	@$(MAKE) --no-print-directory check-flags
	@$(MAKE) --no-print-directory check-discovery
	@$(MAKE) --no-print-directory check-profile-deps
	@$(MAKE) --no-print-directory check-core-xlen
	@$(MAKE) --no-print-directory check-xsim
	@$(MAKE) --no-print-directory check-negative-legs
	@$(MAKE) --no-print-directory check-micro-csr
	@$(MAKE) --no-print-directory check-swwel-census
	@$(MAKE) --no-print-directory check-doc-evidence
	@$(MAKE) --no-print-directory check-evidence-stamp
	@$(MAKE) --no-print-directory check-sim-fmt
	@$(MAKE) --no-print-directory check-orphan-gates
	@$(MAKE) --no-print-directory check-sva-channel
	@$(MAKE) --no-print-directory check-publication
	@$(MAKE) --no-print-directory check-drawio
	@scripts/lint.sh

## check-drawio: Every doc drawing is its own editable source -- the draw.io
##          XML rides inside the .drawio.png / .drawio.svg, and no sibling
##          .drawio file duplicates it. Two copies of one drawing drift;
##          an image exported without draw.io's -e loses the drawing while
##          still looking correct.
check-drawio:
	@$(PY) scripts/check_drawio_embedded.py

## check-publication: The guards that decide whether this tree is fit to be
##          PUBLISHED, as opposed to fit to be simulated. They used to hang off
##          the internal CI stage-1 driver, which is why they had never run on
##          a public CI: no lab addresses or credentials in a tracked file,
##          English-only prose, every path a tutorial names resolves, nothing
##          points a public reader at a private host or a retired repository
##          name (and the version is the same everywhere it is stated, and
##          every README link resolves), the vendored-CVA6 delta list matches
##          what fetch.sh actually does, every SystemRDL enum a field
##          declares is also assigned to it (or exporters drop its values
##          silently), and the mbv CTRL map agrees with its RTL and the
##          shared sink window.
##          Python only -- no EDA tools, so this runs on any CI runner.
check-publication:
	@$(PY) scripts/check_no_lab_internals.py
	@$(PY) scripts/check_language.py
	@$(PY) scripts/check_tutorial_paths.py
	@$(PY) scripts/test_check_public_links.py
	@$(PY) scripts/check_public_links.py
	@$(PY) scripts/check_vendor_deltas.py
	@$(PY) scripts/check_rdl_encode.py
	@$(PY) examples/kv260/mbv/tools/check_regmap.py >/dev/null \
		&& echo "[check_regmap] OK (mbv CTRL map: header vs RTL vs sink window)" \
		|| { echo "[check_regmap] FAIL -- rerun: python3 examples/kv260/mbv/tools/check_regmap.py"; exit 1; }

## check-core-xlen: CORE_XLEN declaration guard (P0-07) — every ct_encoder
##          instantiation must DECLARE the attached hart's XLEN, and a
##          declaration derived from the netlist's own width (directly or via
##          a local parameter) must carry a waiver naming why that TIP has no
##          external core. Red on a missing or hollow declaration.
check-core-xlen:
	@$(PY) scripts/check_core_xlen.py

## check-flags: Feature-flag drift guard — cross-checks the CT_EN_* switches in
##          ct_pkg.sv, the RDL resets/offsets, the TCODE-58 CAPS map and the
##          two documented flag tables (doc/trace-format.adoc matrix,
##          doc/integration.adoc #feature-flags). Red on any drift.
check-flags:
	@$(PY) scripts/check_feature_flags.py

## check-discovery: Protocol-discovery drift guard — the protocol is a
##          synthesis parameter (P9), so trTeProtocolSel.Protocol and
##          trTeImpl.ProtocolMajor must stay read-only hardware mirrors:
##          `sw = r; hw = w;` in the RDL, driven from EN_ETRACE in the wb
##          shim, read back from hwif_in in BOTH register blocks (generated
##          and CF-slim micro). Red if an RDL regen makes them writable again.
check-discovery:
	@$(PY) scripts/check_protocol_discovery.py

## check-profile-deps: Profile-dependency drift guard — every
##          `CT_EN_x requires CT_EN_y` elaboration $fatal in the RTL must be
##          honoured by every profile script that switches CT_EN_y off.
##          Red if a new switch dependency is added without carrying it into
##          the profile selectors (it would abort elaboration in scripts the
##          feature author never runs).
check-profile-deps:
	@$(PY) scripts/check_profile_deps.py

## check-xsim: xsim-launch drift guard — xsim reports a failed engine start
##          only in its LOG and still exits 0, so a bare call followed by
##          `cp <tb>.atb.bin` silently promotes the PREVIOUS leg's dump.
##          Every caller must go through ct_xsim/ct_xsim_ok (scripts/ct_env.sh).
##          Red on a new bare xsim invocation.
check-xsim:
	@$(PY) scripts/check_xsim_guard.py

## check-negative-legs: compiled-out-negative bookkeeping — every build
##          switch with a CT_PROFILE_NO_* RDL override must have either a
##          compiled-out negative leg (`... ro`) or a WAIVED reason. Red on a
##          new switch that has neither, and on a leg whose verdict marker
##          disappeared.
check-negative-legs:
	@$(PY) scripts/check_negative_legs.py

## check-micro-csr: micro-CSR twin drift guard — the hand-written CF-slim
##          register block (rtl/pkg/ct_cs_micro.sv, CT_MICRO_CSR) must read
##          every field back at the SAME width as the generated block, and
##          every register it does NOT decode needs a waiver (an elaboration
##          $fatal, or a generated arm that is constant 0 anyway). Red on a
##          widened field the twin did not follow — P8 widened SyncReqSource
##          to three bits and the twin truncated it to two in silence.
check-micro-csr:
	@$(PY) scripts/check_micro_csr_twin.py

## check-swwel-census: Enable-lock intent guard — every CSR field the
##          generated block leaves writable at trTeControl.Enable=1 must be
##          named in the "Not gated (intentionally)" list of the RDL, and
##          every name in that list must exist and really be ungated. The
##          list used to name 10 of 31 ungated fields, so "not in the list"
##          said nothing — and hid the eight trTeInstFeatures.InstEn* bits
##          that both the register description and doc/integration.adoc
##          declared locked (U10 F-1).
check-swwel-census:
	@$(PY) scripts/check_swwel_census.py

## check-doc-evidence: every documented resource number needs a report a
##          reader can open. A doc section quoting CLB LUTs / flip-flops must
##          name a utilization report under verification/evidence/**, that file must
##          exist, and its numbers must be the ones in the table. Red on a
##          reference into gitignored bld/ and on a table written from a
##          different run than the report it names — the same defect twice,
##          one commit apart (P4 audit B-1, P8 closing audit B-N2).
check-doc-evidence:
	@$(PY) scripts/check_doc_evidence.py

## check-evidence-stamp: every gate verdict under verification/evidence/** must carry a
##          `# HEAD :` commit that is really in this branch's history, and a
##          verdict may not be older than the RTL it judges unless a newer
##          log supersedes it. Red on evidence from a rebased-away tree —
##          five such logs went unnoticed until an inventory found them
##          (P8 fix round).
check-evidence-stamp:
	@$(PY) scripts/check_evidence_stamp.py

## check-sim-fmt: every $$display/$$sformatf/... format argument in rtl/ and
##          tests/ must be a string LITERAL. Verilator (the .abc.config
##          default backend, i.e. `make sim`) does not substitute a
##          non-literal format — it prints the format string itself. That is
##          how every expected-PC file came to start with "0x%08x" while the
##          same testbench passed under XSIM (D1-F2).
check-sim-fmt:
	@$(PY) scripts/check_sim_fmt.py

## check-orphan-gates: every cli_*_test.sh must be reachable from
##          scripts/run_gates.sh, and every testbench must be named by some
##          script — or be listed, WITH a reason, in the frozen orphan
##          inventory of scripts/check_orphan_gates.py. A gate nobody starts
##          cannot go red; that class was found by accident twice
##          (P8 RC-2, D1-F6) before it was counted (V1: 9 gates, 16 tbs).
check-orphan-gates:
	@$(PY) scripts/check_orphan_gates.py

## check-sva-channel: xsim exits 0 even on $fatal, so a gate that does not read
##          its simulation log cannot see an assertion fire. V1 counted 25 of
##          29 xsim gates in that state. The check now lives once, inside
##          ct_xsim_ok (scripts/ct_env.sh); this guard keeps that the only
##          road -- including for `xelab -R`, whose -log is elaboration only.
check-sva-channel:
	@$(PY) scripts/check_sva_channel.py

## check-rdl-encode: SystemRDL enum-encoding guard — a field that DECLARES an
##          inline `enum` must also ASSIGN it (`encode = <type>;`). Without
##          the second half the file compiles, simulates and reads back
##          identically, but every exporter silently drops the value list:
##          no `typedef enum` from PeakRDL-regblock, no value table from
##          PeakRDL-html, `None` from `field.get_property("encode")` for
##          anything walking the model. Found that way on
##          sink_ctrl.pib_pattern (2026-08-24, reported from the doc repo).
##          A deliberate bare type anchor is allowed if it says so:
##          `// RDL-ENCODE-EXEMPT: <reason>` above the declaration.
check-rdl-encode:
	@$(PY) scripts/check_rdl_encode.py

## doc-check: asciidoctor smoke over doc/*.adoc — build errors are red,
##          warnings are printed but do not fail. Requires asciidoctor
##          (not part of CI stage 1; run locally / on doc changes).
doc-check:
	@AD=""; for c in asciidoctor asciidoctor.bat; do \
		command -v "$$c" >/dev/null 2>&1 && "$$c" --version >/dev/null 2>&1 && { AD="$$c"; break; }; \
	done; \
	[ -n "$$AD" ] || { echo "FAIL: no working asciidoctor on PATH"; exit 1; }; \
	fail=0; for f in doc/*.adoc; do \
		if "$$AD" --failure-level=ERROR -o /dev/null "$$f"; then \
			echo "  [PASS] $$f"; \
		else \
			echo "  [FAIL] $$f"; fail=1; \
		fi; \
	done; exit $$fail


## clean:  Remove generated artifacts (bld/, sim logs, etc.).
clean:
	rm -rf bld/
	@echo "[clean] removed bld/"

## bld-bootstrap: Generate the three xsim projects every cli_*_test.sh gate
##          clones (implicit_return_tb, repeated_history_tb,
##          overrun_recovery_tb). bld/ is gitignored, so a fresh clone or
##          `git worktree add` has none — the gates call this for themselves
##          (ct_need_prj in scripts/ct_env.sh), the target is for warming a
##          tree up before a long gate run. CT_PRJ_REFRESH=1 rebuilds them
##          even when they exist (after a change to a project's FILE LIST).
bld-bootstrap:
	@set -e; . scripts/ct_env.sh; \
	for tb in implicit_return_tb repeated_history_tb overrun_recovery_tb; do \
		ct_need_prj "$$tb" || exit $$?; \
	done; \
	echo "[bld-bootstrap] the three donor projects are in place"

## bld-refresh: bld-bootstrap with CT_PRJ_REFRESH=1 — regenerate the donor
##          projects even if they exist. Needed after a source file was added
##          to or removed from one of them (the .prj pins the file LIST; its
##          contents are recompiled on every run anyway).
bld-refresh:
	@set -e; export CT_PRJ_REFRESH=1; . scripts/ct_env.sh; \
	for tb in implicit_return_tb repeated_history_tb overrun_recovery_tb; do \
		ct_need_prj "$$tb" || exit $$?; \
	done; \
	echo "[bld-refresh] the three donor projects were regenerated"

# ---------------------------------------------------------------------------
# KV260 example simulations (package D3a). Appended as a block, and the only
# line touched above is SIM_EXAMPLES -- two other workers are editing this
# tree, and a target appended at the end cannot collide with a hunk in the
# middle of it.
#
# All three legs came from an internal predecessor repository, where they
# ran as PowerShell runners driving xvlog/xelab/xsim by hand. Here they are .abc graph nodes like every other
# testbench in this repository, so they run on the pinned default backend
# (.abc.config: verilator) with no runner script at all.
#
# The marker grep after each run is not decoration: `abc -sim` reports the
# SIMULATOR's exit status, and a testbench that ends early -- $finish in a
# branch that skipped the checks, a scenario that never started -- exits 0.
# The PASS marker is printed by the last line of the test sequence, so its
# ABSENCE is the only reliable statement that the sequence did not complete.
.PHONY: sim-ddr-sink-window sim-axis-wp-shim sim-tgc5b2-axis-soc sim-rvcfi-units sim-rvcfi-e2e

## sim-ddr-sink-window: examples/kv260/common/sim — unit gate for the DDR
##          sink's window guard (defect class B-C1-1): shrinking DDR_SIZE
##          below the running write offset must not produce a single burst
##          outside [base, base+size). Drives ct_soc_ddr_sink directly, which
##          is how the tops that wire the sink themselves (rocket*, cva6_2,
##          cva6_linux*) instantiate it -- they do not have the ct_trace_sinks
##          register interlock. Marker: U6_WINDOW_UNIT_PASS.
sim-ddr-sink-window: ct-tools | bld
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim \
		../examples/kv260/common/sim/tb_ddr_sink_window.abc 2>&1 \
		| tee tb_ddr_sink_window.simlog
	@grep -q 'U6_WINDOW_UNIT_PASS' bld/tb_ddr_sink_window.simlog || { \
		echo 'sim-ddr-sink-window: FAIL — marker U6_WINDOW_UNIT_PASS missing'; \
		echo '  (the run ended without completing the test sequence:'; \
		echo '   bld/tb_ddr_sink_window.simlog)'; exit 1; }
	@echo '[sim-ddr-sink-window] PASS (U6_WINDOW_UNIT_PASS)'

## sim-axis-wp-shim: examples/kv260/tgc5b2_axis_wp/sim — unit bench of
##          ct_axis_wp_shim (the AXIS watchpoint record packer), BOTH depth
##          legs: FIFO_DEPTH=256 (the product default) and 16 (stress —
##          frequent full/empty edges in the soak). Scenarios a..g: single
##          beat, back-to-back, stall/overflow/resume, tstrb/tid into W3,
##          12k-beat randomized soak, fill_level plausibility, drop_count
##          saturation. Green only if BOTH legs print their TB_PASS line.
sim-axis-wp-shim: ct-tools | bld
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim \
		../examples/kv260/tgc5b2_axis_wp/sim/tb_axis_wp_shim_d256.abc 2>&1 \
		| tee tb_axis_wp_shim_d256.simlog
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim \
		../examples/kv260/tgc5b2_axis_wp/sim/tb_axis_wp_shim_d16.abc 2>&1 \
		| tee tb_axis_wp_shim_d16.simlog
	@for d in 256 16; do \
		grep -q "TB_PASS (tb_axis_wp_shim DEPTH=$$d)" bld/tb_axis_wp_shim_d$$d.simlog || { \
			echo "sim-axis-wp-shim: FAIL — DEPTH=$$d leg printed no TB_PASS"; \
			echo "  (bld/tb_axis_wp_shim_d$$d.simlog)"; exit 1; }; \
	done
	@echo '[sim-axis-wp-shim] PASS (TB_PASS for DEPTH=256 and DEPTH=16)'

## sim-rvcfi-units: examples/kv260/tgc5b2_rvcfi -- unit + integration benches
##          of the runtime-verification demo: shared URAM memory, ACT-CAP
##          doorbell, console, adapter, SoC smoke. No RISC-V toolchain needed.
.PHONY: sim-rvcfi-units sim-rvcfi-e2e
sim-rvcfi-units: ct-tools | bld
	@for t in tb_shared_mem tb_doorbell tb_console tb_actcap_adapter tb_rvcfi_smoke; do 		( set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim 			../examples/kv260/tgc5b2_rvcfi/sim/$$t.abc 2>&1 | tee $$t.simlog ) || exit 1; 		grep -q "TB_PASS" bld/$$t.simlog || { 			echo "sim-rvcfi-units: FAIL -- $$t printed no TB_PASS (bld/$$t.simlog)"; exit 1; }; 	done
	@echo '[sim-rvcfi-units] PASS (5 benches)'

## sim-rvcfi-e2e: the six end-to-end mode legs (both cores run the committed
##          program images through the real load path) plus the analyser
##          verdicts. The verdict CLAIMS are checked mechanically per mode by
##          sim/run_verdicts.sh -- CLEAN where silence is the requirement,
##          the intended monitor where a finding is.
sim-rvcfi-e2e: ct-tools | bld
	@for t in m0 m1 m2 m3 m4 cap ddr; do		( set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim 			../examples/kv260/tgc5b2_rvcfi/sim/tb_rvcfi_e2e_$$t.abc 2>&1 			| tee tb_rvcfi_e2e_$$t.simlog ) || exit 1; 		grep -q "TB_PASS" bld/tb_rvcfi_e2e_$$t.simlog || { 			echo "sim-rvcfi-e2e: FAIL -- leg $$t printed no TB_PASS"; exit 1; }; 	done
	@$(MAKE) --no-print-directory -C examples/kv260/tgc5b2_rvcfi/board/rvmon
	@bash examples/kv260/tgc5b2_rvcfi/sim/run_verdicts.sh

## sim-tgc5b2-axis-soc: examples/kv260/tgc5b2_axis_wp/sim — the watchpoint
##          testbed's full chain: two TGC5B cores, each with its own encoder,
##          the AXIS watchpoint shims, the L1 funnel and the three-sink
##          subsystem (ring + DDR writer + PIB), driven through the AXI4-Lite
##          slave exactly as Linux devmem would. Two legs, both run:
##            C1a  defaults — 13 real watchpoints, no timestamp checks
##            C1b  FULL_WP/CHECK_TS — full oracle (851 hits per core, in
##                 order), timestamp monotonicity + cross-core bound, and the
##                 negative probe (a table commit while the encoder is
##                 enabled must move nothing)
##          Both legs also carry the DDR-sink accounting (D2) and the PIB
##          calibration/beat balance (T2). Green only if BOTH legs print
##          their ALL_PASS marker. This is the long one — the Verilator build
##          of the two cores plus two encoders dominates its run time.
sim-tgc5b2-axis-soc: ct-tools | bld
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim \
		../examples/kv260/tgc5b2_axis_wp/sim/tb_tgc5b2_axis_soc_c1a.abc 2>&1 \
		| tee tb_tgc5b2_axis_soc_c1a.simlog
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim \
		../examples/kv260/tgc5b2_axis_wp/sim/tb_tgc5b2_axis_soc_c1b.abc 2>&1 \
		| tee tb_tgc5b2_axis_soc_c1b.simlog
	@grep -q 'C1A_ALL_PASS' bld/tb_tgc5b2_axis_soc_c1a.simlog || { \
		echo 'sim-tgc5b2-axis-soc: FAIL — C1a leg printed no C1A_ALL_PASS'; \
		echo '  (bld/tb_tgc5b2_axis_soc_c1a.simlog)'; exit 1; }
	@grep -q 'C1B_ALL_PASS' bld/tb_tgc5b2_axis_soc_c1b.simlog || { \
		echo 'sim-tgc5b2-axis-soc: FAIL — C1b leg printed no C1B_ALL_PASS'; \
		echo '  (bld/tb_tgc5b2_axis_soc_c1b.simlog)'; exit 1; }
	@echo '[sim-tgc5b2-axis-soc] PASS (C1A_ALL_PASS + C1B_ALL_PASS)'

# ---------------------------------------------------------------------------
# MicroBlaze-V example simulations (package D3b). Appended as a block for the
# same reason D3a's block was: the only line touched further up is
# SIM_EXAMPLES, and a target at the end of the file cannot collide with a hunk
# in the middle of it while other workers edit this tree.
#
# Only ONE of the nine benches migrated by D3b is wired here. The other eight
# instantiate `mbv_ctrace_soc_wrapper` -- the wrapper Vivado's make_wrapper
# generates from the `mbv_ctrace_soc` block design at build time, around the
# ENCRYPTED MicroBlaze-V core -- and, through mbv_soc_synth_wrap, the Xilinx
# XPM macro `xpm_memory_tdpram`. Neither has an in-repo .sv source, by design,
# so no Verilator path can exist for them. They are migrated, documented and
# runnable under Vivado xsim inside a generated project; the recipe and the
# measured error are in examples/kv260/{mbv,duo,trio}/sim/README.md.
.PHONY: sim-ctte-smoke

## sim-ctte-smoke: examples/kv260/mbv/sim — the encoder ALONE (no core, no
##          adapter, no Xilinx IP): ct_encoder at CORE_XLEN=32 with a quiet
##          TIP and always-ready ATB/AXIS sinks, 5 us. Cheap elaboration +
##          time-0 smoke, and the bisector the MBV bring-up used in 2026-07 to
##          show that an xsim kernel FATAL came from the tool and not from the
##          integration (that probe fires only under `abc --sim-backend xsim`;
##          see the bench header). Marker: "[smoke] PASS".
sim-ctte-smoke: ct-tools | bld
	@set -o pipefail; cd bld && $(ABC) $(ABC_COV) -sim \
		../examples/kv260/mbv/sim/tb_ctte_smoke.abc 2>&1 \
		| tee tb_ctte_smoke.simlog
	@grep -q '\[smoke\] PASS' bld/tb_ctte_smoke.simlog || { \
		echo 'sim-ctte-smoke: FAIL — marker "[smoke] PASS" missing'; \
		echo '  (the run ended without completing the 5 us window:'; \
		echo '   bld/tb_ctte_smoke.simlog)'; exit 1; }
	@echo '[sim-ctte-smoke] PASS ([smoke] PASS)'
