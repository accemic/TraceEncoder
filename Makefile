# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# CEDARtools.TraceEncoder top-level Makefile.

.DEFAULT_GOAL := help
SHELL := /bin/bash

# Coverage. `make coverage` re-runs the whole suite with this set to
# `--coverage`, so every `abc ... -sim` below builds with Verilator line
# coverage and drops a coverage_<top>.dat in its work dir. Plain `make sim`
# leaves it empty, so the suite runs uninstrumented (instrumentation is
# slower). scripts/coverage_report.sh then merges all the data into one rate.
ABC_COV ?=
COV_DIR := bld/coverage

.PHONY: help rdl sim sim-basic sim-interrupts sim-stress sim-periodic-sync sim-exceptions sim-data-basic sim-overrun-recovery sim-hsi-csr-cap sim-combined coverage lint clean

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

## sim:    Run all top-level testbenches and print a PASS/FAIL summary.
##          Every test runs even if an earlier one fails. Tests listed in
##          SIM_XFAIL are known-failing regression gates (for an unfixed
##          encoder bug): they run and are shown as XFAIL, but do not fail
##          `make sim`. The run exits non-zero iff a normal test FAILs or an
##          XFAIL test unexpectedly passes (XPASS — fix landed; promote it out
##          of SIM_XFAIL). Run one test with its own `make sim-<name>`.
SIM_ALL   := basic interrupts stress periodic-sync exceptions data-basic overrun-recovery hsi-csr-cap combined
# overrun-recovery: known-failing — the soft-overflow desync drops the trailing
# Program Trace Disabled correlation message (--disabled check). Under
# investigation; remove from SIM_XFAIL once the encoder fix lands (an XPASS here
# will flag that for you).
SIM_XFAIL := overrun-recovery

sim:
	@overall=0; declare -A st; xfail=" $(SIM_XFAIL) "; \
	declare -A dir=( \
		[basic]=instruction/01_basic \
		[interrupts]=instruction/02_interrupts \
		[stress]=instruction/03_stress \
		[periodic-sync]=instruction/04_periodic_sync \
		[exceptions]=instruction/05_exceptions \
		[data-basic]=data/01_basic \
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
	if [ $$overall -eq 0 ]; then \
		if [ -n "$(SIM_XFAIL)" ]; then \
			printf '  RESULT: PASS  (XFAIL, expected: %s)\n\n' "$(SIM_XFAIL)"; \
		else \
			printf '  RESULT: PASS\n\n'; \
		fi; \
	else \
		printf '  RESULT: FAIL — %s\n\n' "$$(for t in $(SIM_ALL); do if [ "$${st[$$t]}" = FAIL ] || [ "$${st[$$t]}" = XPASS ]; then printf 'tests/%s(%s) ' "$${dir[$$t]}" "$${st[$$t]}"; fi; done)"; \
		exit 1; \
	fi

## sim-basic: tests/instruction/01_basic — sim + NexRv decode + address match.
##              Exercises instruction-trace pause/resume; trace-off emits a
##              Program Trace Correlation Message (TCODE 33, EVCODE=Program
##              Trace Disabled). --pc checks the PC stream, --disabled the
##              trace-off message.
sim-basic: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/instruction/01_basic/basic_tb.abc
	@scripts/decode_and_check.sh --pc --disabled basic_tb

## sim-interrupts: tests/instruction/02_interrupts — sim + NexRv decode + address match.
sim-interrupts: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/instruction/02_interrupts/interrupts_tb.abc
	@scripts/decode_and_check.sh --pc --disabled interrupts_tb

## sim-stress: tests/instruction/03_stress — instruction-trace stress.
##              Merges the former 03 (periodic sync + HIST_OVERFLOW, direct
##              branches) and 04 (indirect branch right after a HIST flush) into
##              one scenario that also mixes inferable CALLs and RETURNs. It is a
##              regression gate for the branch-HIST sync-seed bug (periodic sync
##              on a TAKEN branch seeded a stranded HIST bit -> "hist bits
##              pending"); see the seed guard in rtl/ct_L2_msg_gen.sv.
sim-stress: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/instruction/03_stress/stress_tb.abc
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
##              the bug on hardware (scenarios_a3 / roberts captures, where
##              the trace_fs-vendored encoder pre-dates this fix). A clean
##              decode here confirms the pre-flush still fires.
sim-periodic-sync: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/instruction/04_periodic_sync/periodic_sync_tb.abc
	@scripts/decode_and_check.sh --pc periodic_sync_tb

## sim-exceptions: tests/instruction/05_exceptions — synchronous exceptions,
##              including the illegal-instruction shape where the faulting
##              instruction NEVER retires (iretire=0) but its iaddr/ilastsize
##              are still communicated. Exercises the iretire=0 EXCEPTION_TRAP
##              count_halfwords branch (uncovered by 02_interrupts, which uses
##              iretire=1) and an iretire=0 exception right after a taken branch.
sim-exceptions: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/instruction/05_exceptions/exceptions_tb.abc
	@scripts/decode_and_check.sh --pc --disabled exceptions_tb

## sim-data-basic: tests/data/01_basic — sim + NexRv data-trace check.
##                  Instruction trace is OFF in this scenario; verification
##                  compares the cpu_model's load/store sequence (address,
##                  size AND data value) against the NexRv CTXP export
##                  (MEMREAD_n / MEMWRITE_n records).
sim-data-basic: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/data/01_basic/data_basic_tb.abc
	@scripts/decode_and_check.sh --ctxp data_basic_tb

## sim-overrun-recovery: tests/overflow/01_overrun_recovery — sim + NexRv
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
sim-overrun-recovery: | bld
	@mkdir -p bld/overrun_recovery_tb.vsim
	@set -o pipefail; cd bld && abc $(ABC_COV) -sim ../tests/overflow/01_overrun_recovery/overrun_recovery_tb.abc \
		2>&1 | tee overrun_recovery_tb.vsim/overrun_recovery_tb.sim.log
	@scripts/decode_and_check.sh --soft --pc --data --overflow --disabled overrun_recovery_tb

## sim-hsi-csr-cap: tests/hsi/01_csr_cap — ACT-CAP CSR-based instrumentation.
##              Fires the full ACT-CAP command set via the ACT-CAP CSR (0x0B10):
##              every DAQ_* command routed to BOTH sinks (AXIS_NEXUS), plus one
##              CF_SYNC (Nexus only). The AXIS beat (command + payload) is
##              verified in-sim (self-checking; $fatal on mismatch). Offline:
##                --ctxp     : the NexRv CTXP export of the DAQ records
##                             (DAQ_DATA / DAQ_COUNTER / DAQ_LAST_PC / SYNC /
##                             MEMx_n) matches the cpu_model's expected.ctxp.
##                --sync 2   : >= 2 sync messages (startup + CF_SYNC).
sim-hsi-csr-cap: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/hsi/01_csr_cap/csr_cap_tb.abc
	@scripts/decode_and_check.sh --ctxp --sync 2 csr_cap_tb

## sim-combined: tests/combined/01_all — instruction + data + ACT-CAP sync.
##              Mixed workload (linear, branch, call/return, varied
##              loads/stores, ACT-CAP CF_SYNC) with the timestamp unit ON.
##              One NexRv decode, five checks:
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
sim-combined: | bld
	@cd bld && abc $(ABC_COV) -sim ../tests/combined/01_all/combined_tb.abc
	@scripts/decode_and_check.sh --pc --data --sync 3 --disabled --tsmono combined_tb

## coverage: Re-run the whole suite under Verilator line coverage, merge every
##            test's data, and print one suite-wide line-coverage rate. Also
##            writes bld/coverage/: merged.info (lcov), an HTML report, and a
##            shields endpoint JSON (coverage-badge.json) for the README badge.
##            The suite still runs even if a test FAILs, so the rate reflects
##            whatever data was produced (failures are reported, not swallowed).
coverage:
	@$(MAKE) --no-print-directory sim ABC_COV=--coverage \
		|| echo "  (note: a test FAILed — coverage computed from the data produced)"
	@scripts/coverage_report.sh $(COV_DIR)

bld:
	@mkdir -p bld

## lint:   Run verible-verilog-lint over rtl/ and tests/ (rules in .rules.verible_lint).
lint:
	@scripts/lint.sh


## clean:  Remove generated artifacts (bld/, sim logs, etc.).
clean:
	rm -rf bld/
	@echo "[clean] removed bld/"
