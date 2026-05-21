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

.PHONY: help rdl sim sim-basic sim-interrupts sim-stress sim-sync-indirect sim-data-basic sim-overflow sim-hsi-csr-cap sim-hsi-csr-sync sim-combined lint format doc clean

## help: List available targets.
help:
	@echo "C-Trace — available make targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^## / { sub(/^## /,""); print "  " $$0 }' $(MAKEFILE_LIST)
	@echo ""

## rdl:    Regenerate rdl/gen/*.sv from rdl/*.rdl (via scripts/gen_rdl.sh).
rdl:
	$(NOT_IMPL)

## sim:    Run all top-level testbenches; sim phase + NexRv decode check per test.
sim: sim-basic sim-interrupts sim-stress sim-sync-indirect sim-data-basic sim-overflow sim-hsi-csr-cap sim-hsi-csr-sync sim-combined

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

## sim-stress: tests/instruction/03_stress_sync_resourcefull — sim + NexRv decode.
##              Long branch stream that forces many periodic syncs and many
##              ResourceFull (HIST_OVERFLOW) messages; the decoded PC stream
##              must match the cpu_model exactly.
sim-stress: | bld
	@cd bld && abc -sim ../tests/instruction/03_stress_sync_resourcefull/stress_sync_resourcefull_tb.abc
	@scripts/decode_and_check.sh --pc --disabled stress_sync_resourcefull_tb

## sim-sync-indirect: tests/instruction/04_sync_indirect_collapse — sim + NexRv decode (HARD).
##              Regression gate for the IBH / sync-coincident-branch ICNT collapse:
##              a conditional branch carrying a sync reason (e.g. the
##              EXIT_FROM_SYS_RST on the first instruction) used to lose its HIST
##              bit, shifting the first overflow and collapsing the following
##              indirect branch's ICNT. Decoded PC stream must match the cpu_model.
sim-sync-indirect: | bld
	@cd bld && abc -sim ../tests/instruction/04_sync_indirect_collapse/sync_indirect_collapse_tb.abc
	@scripts/decode_and_check.sh --pc --disabled sync_indirect_collapse_tb

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
##              and verifies the decoded command + payload on the AXIS sink
##              in-sim (self-checking; $fatal on mismatch).
sim-hsi-csr-cap: | bld
	@cd bld && abc -sim ../tests/hsi/01_csr_cap/csr_cap_tb.abc

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
