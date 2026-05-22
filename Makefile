# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# C-Trace top-level Makefile.
#
# Umbrella entry-points for the abc-flow + PeakRDL + Verible toolchain.
# Every target is currently a stub. Real implementations land alongside
# the RTL/RDL ports in a follow-up change.

.DEFAULT_GOAL := help
SHELL := /bin/bash

NOT_IMPL = @echo "[$@] not implemented yet — skeleton release. See CLAUDE.md."

.PHONY: help rdl sim sim-basic sim-interrupts sim-stress sim-data-basic sim-overflow sim-hsi-csr-cap sim-hsi-csr-sync sim-combined lint format doc clean

## help: List available targets.
help:
	@echo "C-Trace — available make targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^## / { sub(/^## /,""); print "  " $$0 }' $(MAKEFILE_LIST)
	@echo ""

## rdl:    Regenerate rdl/gen/*.sv from rdl/*.rdl (via scripts/gen_rdl.sh).
rdl:
	$(NOT_IMPL)

## sim:    Run all top-level testbenches and print a PASS/FAIL summary.
##          Every test runs even if an earlier one fails. Tests listed in
##          SIM_XFAIL are known-failing regression gates (for an unfixed
##          encoder bug): they run and are shown as XFAIL, but do not fail
##          `make sim`. The run exits non-zero iff a normal test FAILs or an
##          XFAIL test unexpectedly passes (XPASS — fix landed; promote it out
##          of SIM_XFAIL). Run one test with its own `make sim-<name>`.
SIM_ALL   := basic interrupts stress data-basic overflow hsi-csr-cap hsi-csr-sync combined
SIM_XFAIL :=

sim:
	@overall=0; declare -A st; xfail=" $(SIM_XFAIL) "; \
	declare -A dir=( \
		[basic]=instruction/01_basic \
		[interrupts]=instruction/02_interrupts \
		[stress]=instruction/03_stress \
		[data-basic]=data/01_basic \
		[overflow]=overflow/01_run_overflow_reset \
		[hsi-csr-cap]=hsi/01_csr_cap \
		[hsi-csr-sync]=hsi/02_csr_sync \
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
	@cd bld && abc -sim ../tests/instruction/01_basic/basic_tb.abc
	@scripts/decode_and_check.sh --pc --disabled basic_tb

## sim-interrupts: tests/instruction/02_interrupts — sim + NexRv decode + address match.
sim-interrupts: | bld
	@cd bld && abc -sim ../tests/instruction/02_interrupts/interrupts_tb.abc
	@scripts/decode_and_check.sh --pc --disabled interrupts_tb

## sim-stress: tests/instruction/03_stress — instruction-trace stress.
##              Merges the former 03 (periodic sync + HIST_OVERFLOW, direct
##              branches) and 04 (indirect branch right after a HIST flush) into
##              one scenario that also mixes inferable CALLs and RETURNs. It is a
##              regression gate for the branch-HIST sync-seed bug (periodic sync
##              on a TAKEN branch seeded a stranded HIST bit -> "hist bits
##              pending"); see the seed guard in rtl/ct_L2_msg_gen.sv.
sim-stress: | bld
	@cd bld && abc -sim ../tests/instruction/03_stress/stress_tb.abc
	@scripts/decode_and_check.sh --pc stress_tb

## sim-data-basic: tests/data/01_basic — sim + NexRv data-trace check.
##                  Instruction trace is OFF in this scenario; verification
##                  compares the cpu_model's load/store sequence against
##                  the NexRv-decoded DataRead/DataWrite messages.
sim-data-basic: | bld
	@cd bld && abc -sim ../tests/data/01_basic/data_basic_tb.abc
	@scripts/decode_and_check.sh --data data_basic_tb

## sim-overflow: tests/overflow/01_run_overflow_reset — sim + NexRv decode (soft).
##                Soft mode: overflow tests intentionally lose trace bytes
##                during the stall window, so address mismatches are
##                reported but not treated as test failures.
sim-overflow: | bld
	@cd bld && abc -sim ../tests/overflow/01_run_overflow_reset/run_overflow_reset_tb.abc
	@scripts/decode_and_check.sh --soft --pc run_overflow_reset_tb

## sim-hsi-csr-cap: tests/hsi/01_csr_cap — ACT-CAP CSR-based instrumentation.
##              Drives a DAQ_DIRECT_DATA command via the ACT-CAP CSR (0x0B10)
##              routed to BOTH sinks (AXIS_NEXUS). The AXIS beat (command +
##              payload) is verified in-sim (self-checking; $fatal on mismatch);
##              the DAQ message also lands on the ATB as a Nexus DataAcquisition
##              (vendor TCODE 7), and the captured csr_cap_tb.atb.bin is checked
##              non-empty here. Full DAQ-to-CTXP decode is deferred to NexRv.
sim-hsi-csr-cap: | bld
	@cd bld && abc -sim ../tests/hsi/01_csr_cap/csr_cap_tb.abc
	@atb=$$(find bld -name csr_cap_tb.atb.bin -printf '%T@ %p\n' 2>/dev/null \
		| sort -rn | head -1 | cut -d' ' -f2-); \
	if [ -s "$$atb" ]; then \
		echo "[hsi-csr-cap] ATB capture non-empty: $$atb ($$(wc -c < "$$atb") bytes)"; \
	else \
		echo "[hsi-csr-cap] FAIL — ATB capture missing or empty (csr_cap_tb.atb.bin)"; \
		exit 1; \
	fi

## sim-hsi-csr-sync: tests/hsi/02_csr_sync — ACT-CAP CF_SYNC instruction sync.
##              Issues ACT_CAP_ST_CF_SYNC via the ACT-CAP CSR (0x0B10) and
##              checks (offline NexRv) that an extra instruction-sync message
##              is emitted (>= 2 syncs: startup + CF_SYNC).
sim-hsi-csr-sync: | bld
	@cd bld && abc -sim ../tests/hsi/02_csr_sync/csr_sync_tb.abc
	@scripts/decode_and_check.sh --sync 2 csr_sync_tb

## sim-combined: tests/combined/01_all — instruction + data + ACT-CAP sync.
##              Mixed workload (linear, branch, call/return, varied
##              loads/stores, ACT-CAP CF_SYNC). One NexRv decode, four checks:
##                --pc       : reconstructed PC stream matches the model.
##                --data     : DataRead/DataWrite sequence matches.
##                --sync 3   : >= 3 sync messages (startup + mid CF_SYNC + final).
##                --disabled : trace-off correlation message present.
sim-combined: | bld
	@cd bld && abc -sim ../tests/combined/01_all/combined_tb.abc
	@scripts/decode_and_check.sh --pc --data --sync 3 --disabled combined_tb

bld:
	@mkdir -p bld

## lint:   Run verible-verilog-lint over rtl/ and tests/ (rules in .rules.verible_lint).
lint:
	@scripts/lint.sh

## format: Run verible-verilog-format in-place over rtl/ and tests/.
format:
	$(NOT_IMPL)

## doc:    Build documentation (TBD).
doc:
	$(NOT_IMPL)

## clean:  Remove generated artifacts (bld/, sim logs, etc.).
clean:
	rm -rf bld/
	@echo "[clean] removed bld/"
