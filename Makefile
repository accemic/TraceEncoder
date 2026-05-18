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

.PHONY: help rdl sim lint format doc clean

## help: List available targets.
help:
	@echo "C-Trace — available make targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^## / { sub(/^## /,""); print "  " $$0 }' $(MAKEFILE_LIST)
	@echo ""

## rdl:    Regenerate rdl/gen/*.sv from rdl/*.rdl (via scripts/gen_rdl.sh).
rdl:
	$(NOT_IMPL)

## sim:    Run all testbenches (per-module under rtl/<module>/test/, system tests under tests/).
sim:
	$(NOT_IMPL)

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
