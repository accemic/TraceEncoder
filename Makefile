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

.PHONY: help rdl sim sim-basic sim-interrupts sim-stress sim-data-basic sim-overflow lint format doc clean

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
sim: sim-basic sim-interrupts sim-stress sim-data-basic sim-overflow

## sim-basic: tests/instruction/01_basic — sim + NexRv decode + address match.
sim-basic: | bld
	@cd bld && abc -sim ../tests/instruction/01_basic/basic_tb.abc
	@scripts/decode_and_check.sh basic_tb

## sim-interrupts: tests/instruction/02_interrupts — sim + NexRv decode + address match.
sim-interrupts: | bld
	@cd bld && abc -sim ../tests/instruction/02_interrupts/interrupts_tb.abc
	@scripts/decode_and_check.sh interrupts_tb

## sim-stress: tests/instruction/03_stress_sync_resourcefull — sim + NexRv decode.
##              Long branch stream that forces many periodic syncs and many
##              ResourceFull (HIST_OVERFLOW) messages; the decoded PC stream
##              must match the cpu_model exactly.
sim-stress: | bld
	@cd bld && abc -sim ../tests/instruction/03_stress_sync_resourcefull/stress_sync_resourcefull_tb.abc
	@scripts/decode_and_check.sh stress_sync_resourcefull_tb

## sim-data-basic: tests/data/01_basic — sim + NexRv data-trace check.
##                  Instruction trace is OFF in this scenario; verification
##                  compares the cpu_model's load/store sequence against
##                  the NexRv-decoded DataRead/DataWrite messages.
sim-data-basic: | bld
	@cd bld && abc -sim ../tests/data/01_basic/data_basic_tb.abc
	@scripts/decode_and_check_data.sh data_basic_tb

## sim-overflow: tests/overflow/01_run_overflow_reset — sim + NexRv decode (soft).
##                Soft mode: overflow tests intentionally lose trace bytes
##                during the stall window, so address mismatches are
##                reported but not treated as test failures.
sim-overflow: | bld
	@cd bld && abc -sim ../tests/overflow/01_run_overflow_reset/run_overflow_reset_tb.abc
	@scripts/decode_and_check.sh --soft run_overflow_reset_tb

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
