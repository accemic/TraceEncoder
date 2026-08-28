#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Formal gate: ct_L23_preproc_sync (P-SYNC-1..7).
#   usage: ./run.sh                 # all tasks
#          ./run.sh prove live      # selected tasks
# RTL_DIR=<path> overrides the RTL root (red counter-proof worktrees);
# MUTATE='<perl expr>' applies a build-local mutation to the DUT source
# ct_L23_preproc_sync.sv (red mutation cross-checks, see run_red.sh);
# MUTATE_PACER='<perl expr>' does the same for rtl/pkg/ct_sync_req_pacer.sv,
# which is real source in the proof cone (the launch pacing, P-SYNC-9/10/12).
# SV2V_DEFS='-DRED_MASK_...' adds sv2v defines. RED-RUN USE ONLY: a mask
# switches OFF a property whose shallower counterexample would hide the one a
# given mutation targets. A green run passes NO defines -- neither this
# script's own invocation nor ci/run_stage2b_formal.sh ever sets it (same
# convention as formal/nexus_formatter/run.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

RTL="${RTL_DIR:-$SCRIPT_DIR/../../rtl}"
mkdir -p "$SCRIPT_DIR/build"

# Optional red-check mutation on a build-local copy of the DUT source
# (never touches the tree; pattern from formal/mseo_mdo/run.sh).
SRC_DUT="$RTL/preproc/ct_L23_preproc_sync.sv"
if [ -n "${MUTATE:-}" ]; then
	perl -0pe "$MUTATE" "$SRC_DUT" > "$SCRIPT_DIR/build/mut_preproc_sync.sv"
	if cmp -s "$SRC_DUT" "$SCRIPT_DIR/build/mut_preproc_sync.sv"; then
		echo "ERROR: MUTATE expression did not change the source" >&2
		exit 2
	fi
	SRC_DUT="$SCRIPT_DIR/build/mut_preproc_sync.sv"
fi

# The same hook for the CSR-side launch pacing: it is real source in the cone,
# so a property ABOUT it needs a red counter-proof against it (B-N1).
SRC_PACER="$RTL/pkg/ct_sync_req_pacer.sv"
if [ -n "${MUTATE_PACER:-}" ]; then
	perl -0pe "$MUTATE_PACER" "$SRC_PACER" > "$SCRIPT_DIR/build/mut_sync_req_pacer.sv"
	if cmp -s "$SRC_PACER" "$SCRIPT_DIR/build/mut_sync_req_pacer.sv"; then
		echo "ERROR: MUTATE_PACER expression did not change the source" >&2
		exit 2
	fi
	SRC_PACER="$SCRIPT_DIR/build/mut_sync_req_pacer.sv"
fi

# MUTATE_WRAPPER: the same hook for the WRAPPER, i.e. for the ENVIRONMENT
# rather than the design (V1, 2026-08-09). The other two hooks falsify a
# property by breaking the DUT; this one falsifies the *proof set-up* by
# adding or removing an assumption, which is the only way to demonstrate the
# failure mode a mutation cannot reach: an over-constrained environment.
#
# A contradictory (or merely too narrow) `assume` does not turn anything red.
# It shrinks the reachable state space, and every `assert` over the part that
# is gone holds trivially -- a proof about nothing, reported as PASS. D1
# removed exactly such an assumption (ASM-SYNC-4, `cnt_tiphalfword.add == '0`,
# contradicted on every retiring beat once the half-word counter drives that
# port) and could not show what it had prevented, because nothing in the
# suite could put it back. Now something can: the vacuity counter-proof in
# formal/README.md re-inserts ASM-SYNC-4 through this hook and measures which
# tasks notice.
if [ -n "${MUTATE_WRAPPER:-}" ]; then
	perl -0pe "$MUTATE_WRAPPER" "$SCRIPT_DIR/wrapper.sv" > "$SCRIPT_DIR/build/mut_wrapper.sv"
	if cmp -s "$SCRIPT_DIR/wrapper.sv" "$SCRIPT_DIR/build/mut_wrapper.sv"; then
		echo "ERROR: MUTATE_WRAPPER expression did not change the wrapper" >&2
		exit 2
	fi
	SRC_WRAPPER="$SCRIPT_DIR/build/mut_wrapper.sv"
else
	SRC_WRAPPER="$SCRIPT_DIR/wrapper.sv"
fi

# sed 1: `uwire` -> `wire` (yosys has no uwire).
# sed 2: strip sv2v's wrapper-module-name prefixes on parent-scope
#        references — yosys silently leaves module-name-rooted hierarchical
#        references unbound (found via free-signal CEX in the ovf_injector
#        gate); the stripped form binds lexically. See formal/README.md.
# shellcheck disable=SC2086 -- SV2V_DEFS is a deliberate word list
sv2v -E Assert ${SV2V_DEFS:-} \
	"$RTL/pkg/nexus_vendor_riscv_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_types_pkg.sv" \
	"$RTL/pkg/ct_pkg.sv" \
	"$RTL/pkg/tip_pkg.sv" \
	"$RTL/external/common/counter.sv" \
	"$RTL/external/common/signal_cdc.sv" \
	"$RTL/external/common/signal_ack_lock_fsm.sv" \
	"$RTL/external/common/strobe_cdc.sv" \
	"$RTL/external/common/vector_cdc2.sv" \
	"$RTL/pkg/tip_if.sv" \
	"$RTL/pkg/ct_preproc_if.sv" \
	"$RTL/pkg/ct_cs_if.sv" \
	"$SRC_PACER" \
	"$SRC_DUT" \
	"$SRC_WRAPPER" \
	| sed -e 's/\buwire\b/wire/g' -e 's/\bf_preproc_check\.//g' -e 's/\bf_live\.//g' -e 's/\bf_quota\.//g' -e 's/\bf_tereq\.//g' -e 's/\bf_reqcoll\.//g' -e 's/\bf_tereqrst\.//g' \
	> "$SCRIPT_DIR/build/preproc_sync_formal.v"

cd "$SCRIPT_DIR"
sby -f preproc_sync.sby "$@"
