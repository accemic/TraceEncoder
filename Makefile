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

.PHONY: help rdl sim sim-basic sim-overflow lint format doc clean

## help: List available targets.
help:
	@echo "C-Trace — available make targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^## / { sub(/^## /,""); print "  " $$0 }' $(MAKEFILE_LIST)
	@echo ""

## rdl:    Regenerate rdl/gen/*.sv from rdl/*.rdl (via scripts/gen_rdl.sh).
rdl:
	$(NOT_IMPL)

## sim:    Run all top-level testbenches under tests/ via abc -sim (artifacts in bld/).
sim: | bld
	@cd bld && \
	  for tb in ../tests/instruction/01_basic/basic_tb.abc \
	            ../tests/overflow/01_run_overflow_reset/run_overflow_reset_tb.abc; do \
	    echo "==> abc -sim $$tb"; \
	    abc -sim $$tb || exit $$?; \
	  done

## sim-basic: Run only tests/instruction/01_basic/.
sim-basic: | bld
	@cd bld && abc -sim ../tests/instruction/01_basic/basic_tb.abc

## sim-overflow: Run only tests/overflow/01_run_overflow_reset/.
sim-overflow: | bld
	@cd bld && abc -sim ../tests/overflow/01_run_overflow_reset/run_overflow_reset_tb.abc

bld:
	@mkdir -p bld

## lint:   Run verible-verilog-lint over rtl/ and tests/.
lint:
	$(NOT_IMPL)

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
