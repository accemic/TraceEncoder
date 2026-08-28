#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Formal gate: eTIP slot bound of ct_L23_preproc_composer_etip (P-SLOT-1).
#   usage: ./run.sh              # all tasks
#          ./run.sh bmc0         # selected task
# RTL_DIR=<path> overrides the RTL root; MUTATE='<perl expr>' applies a
# build-local mutation to the DUT source (red cross-checks, see run_red.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

RTL="${RTL_DIR:-$SCRIPT_DIR/../../rtl}"
mkdir -p "$SCRIPT_DIR/build"

SRC_DUT="$RTL/preproc/ct_L23_preproc_composer_etip.sv"

# ----------------------------------------------------------------------
# Drift guard for the property's OWN soundness: `msg_id_next` must be wide
# enough to COUNT every allocation site, otherwise the counter wraps and an
# exceeded bound slips past a_p4_slot_bound unnoticed (the checker would
# then be as silent as the defect it guards). ct_pkg::ETIP_SLOT_SITES is the
# declared number of sites; this counts the real ones. A new arm that is not
# reflected in the package constant fails the gate here, not in the field.
# ----------------------------------------------------------------------
SITES=$(grep -c 'msg_id_next[[:space:]]*=[[:space:]]*msg_id_next[[:space:]]*+[[:space:]]*1' "$SRC_DUT")
DECL=$(grep -oE 'ETIP_SLOT_SITES[[:space:]]*=[[:space:]]*[0-9]+' "$RTL/pkg/ct_pkg.sv" | grep -oE '[0-9]+$')
if [ -z "$DECL" ]; then
	echo "ERROR: ct_pkg::ETIP_SLOT_SITES not found" >&2
	exit 2
fi
if [ "$SITES" -gt "$DECL" ]; then
	echo "ERROR: composer has $SITES slot allocation sites, ct_pkg::ETIP_SLOT_SITES says $DECL" >&2
	exit 2
fi
echo "[slot-sites] $SITES allocation site(s) <= ct_pkg::ETIP_SLOT_SITES = $DECL"

# Optional red-check mutation on a build-local copy of the DUT source
# (never touches the tree; pattern from formal/preproc_sync/run.sh).
if [ -n "${MUTATE:-}" ]; then
	perl -0pe "$MUTATE" "$SRC_DUT" > "$SCRIPT_DIR/build/mut_composer_etip.sv"
	if cmp -s "$SRC_DUT" "$SCRIPT_DIR/build/mut_composer_etip.sv"; then
		echo "ERROR: MUTATE expression did not change the source" >&2
		exit 2
	fi
	SRC_DUT="$SCRIPT_DIR/build/mut_composer_etip.sv"
fi

# source_if.sv / sink_if.sv carry a modport function import
# (`import have_available`) that sv2v cannot parse; nothing in this model
# calls it. Strip the modport entry mechanically (build-local copies, RTL
# untouched) -- same treatment as formal/msg_gen/run.sh.
# The cvsource_if2/cvsink_if underrun checks additionally use the clocking
# form `@(posedge clk iff !rst)`, which sv2v does not parse; the qualifier
# only gates a $display/$stop that this build removes anyway.
# fifo1clk_fwft's UNUSED shift-register style branch initialises its pointer
# with an indexed assignment pattern (`'{ A_BITS: 0, default: 1 }`) that the
# yosys front end does not parse. The composer instantiates the memory style,
# but yosys still parses the other generate branch. Rewrite the literal into
# the equivalent concatenation. The `(* RAM_STYLE = STYLE *)` attribute takes
# a parameter as its value, which yosys rejects ("non-constant value") -- it
# is a Vivado implementation hint with no formal meaning. Both are build-local
# copies; the RTL is untouched.
for f in fifo1clk_fwft fifo2clk_fwft; do
	perl -0pe "s/'\\{ A_BITS: 0, default: 1 \\}/{1'b0, {A_BITS{1'b1}}}/g;
	           s/\\(\\*\\s*RAM_STYLE\\s*=\\s*STYLE\\s*\\*\\)//g" \
		"$RTL/external/memory/fifo/$f.sv" \
		> "$SCRIPT_DIR/build/${f}_patched.sv"
done

# ----------------------------------------------------------------------
# ASM-SLOT-2, the bounded-shape abstraction (same pattern as ASM-MDO-3 in
# formal/mseo_mdo): the eTIP PAYLOAD widths, the CVS queue depth, the
# return-stack depth and the timestamp width are cut down in build-local
# COPIES of the two packages. `msg_id_next` -- the only signal this gate
# reasons about -- has no data dependence on any of them: its thirteen
# guards read tip.*, act_cap_st.*, sync.reason, the two qualifiers, cs_tip.*
# and this module's own control registers, never a payload field, never a
# queue entry. Without the cut the flattened model carries 128 queue entries
# of 6 x 293 bit and yosys' PROC_MUX pass does not terminate in useful time
# (measured: > 13 GB RSS, no progress).
# The feature ENABLES (CT_EN_*), ETIP_PAR_MSG and ETIP_SLOT_SITES are NOT
# touched -- those are the subject of the proof.
perl -0pe '
	s/^(\tlocalparam int unsigned CT_RET_STACK_DEPTH\s*=\s*)\d+/${1}2/m;
	s/^(\tlocalparam int unsigned CT_TS_WIDTH\s*=\s*)\d+/${1}2/m;
	s/^(\tlocalparam int unsigned CT_FIFO_HIST_BINS\s*=\s*)\d+/${1}2/m;
	s/^(\tlocalparam int unsigned CT_DF_DROP_WATERMARK\s*=\s*).*;/${1}1;/m;
	s/^(\tlocalparam MAX_DAQ_DATA_ELEMENTS\s*=\s*)\s*\d+/${1}1/m;
	s/^(\tlocalparam ETIP_CVS_FIFO_DEPTH\s*=\s*).*;/${1}4;/m;
' "$RTL/pkg/ct_pkg.sv" > "$SCRIPT_DIR/build/ct_pkg_small.sv"

perl -0pe '
	s/^(\tlocalparam int ETIP_DF_DATA_W\s*=\s*).*;/${1}2;/m;
	s/^(\tlocalparam int ETIP_DF_ADDR_W\s*=\s*).*;/${1}2;/m;
	s/^(\tlocalparam int ETIP_DAQ_ELEM_W\s*=\s*).*;/${1}2;/m;
	s/^(\tlocalparam int ETIP_DAQ_ADDR_W\s*=\s*).*;/${1}2;/m;
	s/^(\tlocalparam int ETIP_OWN_PROC_W\s*=\s*)[^;]*;/${1}2;/m;
	s/^(\tlocalparam int ETIP_WPHIT_W\s*=\s*)[^;]*;/${1}2;/m;
' "$RTL/pkg/ct_etip_pkg.sv" > "$SCRIPT_DIR/build/ct_etip_pkg_small.sv"

# PROBE ONLY: SLOT_BOUND=<n> overrides ETIP_PAR_MSG in the build-local
# package copy. Used to LOCATE the true worst case (raise until the property
# holds); the committed formula must then produce that number by itself.
if [ -n "${SLOT_BOUND:-}" ]; then
	perl -0pi -e "s/^(\\tlocalparam ETIP_PAR_MSG\\s*=).*?;\\n/\${1} $SLOT_BOUND;\\n/ms" \
		"$SCRIPT_DIR/build/ct_pkg_small.sv"
	grep -q "localparam ETIP_PAR_MSG *= $SLOT_BOUND;" "$SCRIPT_DIR/build/ct_pkg_small.sv" \
		|| { echo "ERROR: SLOT_BOUND override did not take" >&2; exit 2; }
	echo "[probe] ETIP_PAR_MSG forced to $SLOT_BOUND"
fi

# PROFILE=<name>: build against a profile-flipped package copy instead of the
# committed full profile (scripts/gen_rdl_profile.py style switch list).
if [ -n "${SLOT_SWITCHES:-}" ]; then
	for sw in $SLOT_SWITCHES; do
		name="${sw%=*}"; val="${sw#*=}"
		perl -0pi -e "s/^(\\tlocalparam bit +$name\\s*=\\s*)[01];/\${1}$val;/m" \
			"$SCRIPT_DIR/build/ct_pkg_small.sv"
	done
	echo "[profile] $SLOT_SWITCHES"
fi

for f in ct_pkg_small ct_etip_pkg_small; do
	if cmp -s "$SCRIPT_DIR/build/$f.sv" "$RTL/pkg/${f%_small}.sv"; then
		echo "ERROR: ASM-SLOT-2 rewrite of $f did not change anything" >&2
		exit 2
	fi
done

# math_pkg ends in a parameterised class (`array_math`) that sv2v cannot
# parse; the FIFOs only import its plain functions min/gray2bin.
perl -0pe 's/\n\tclass array_math.*?\n\tendclass\n//s' \
	"$RTL/external/common/math_pkg.sv" \
	> "$SCRIPT_DIR/build/math_pkg_patched.sv"

# Third substitution (V1, 2026-08-09): drop the `var` keyword in front of a
# `type(...)` variable declaration. IEEE 1800-2023 6.8 REQUIRES it there --
# a declaration whose type comes from a type reference has no implicit data
# type to derive the lifetime class from -- and rtl/external/stream/cvs_fifo.sv
# carries it since 953857f05, which is what makes yosys-slang accept the
# encoder in the open ASIC flow. sv2v 0.0.13 does not implement that form and
# dies with "Parse error: unexpected statement token", so this gate has been
# red since that commit (finding V1-F2: the commit verified xvlog and
# yosys-slang, the two front ends it was about, and sv2v -- the one this gate
# needs -- was not among them). The strip is BUILD-LOCAL: the tree keeps the
# LRM-correct spelling, and `automatic type(...)` is what sv2v accepts and
# what the file said before 953857f05, so the formal model is unchanged.
for f in source_if sink_if cvsink_if cvsource_if cvsource_if2 cvs_fifo; do
	perl -0pe 's/,\s*\n\s*import\s+have_available//g;
	           s/posedge\s+clk\s+iff\s+![A-Za-z_][A-Za-z_0-9]*/posedge clk/g;
	           s/\bvar\s+(automatic\s+)?(type\s*\()/${1}${2}/g' \
		"$RTL/external/stream/$f.sv" \
		> "$SCRIPT_DIR/build/${f}_patched.sv"
done

# Read the strip back. A silent no-op here would not fail loudly: sv2v would
# abort with a parse error 40 lines further down and the cause would be one
# indirection away. If the source ever spells the declaration differently,
# this says so at the spot where it is fixed.
for f in source_if sink_if cvsink_if cvsource_if cvsource_if2 cvs_fifo; do
	if grep -qE '\bvar\s+(automatic\s+)?type\s*\(' "$SCRIPT_DIR/build/${f}_patched.sv"; then
		echo "ERROR: $f: the \`var <type()>\` strip did not take -- sv2v cannot parse that form" >&2
		grep -nE '\bvar\s+(automatic\s+)?type\s*\(' "$SCRIPT_DIR/build/${f}_patched.sv" >&2
		exit 2
	fi
done

# -D SYNTHESIS drops the module's `ifndef SYNTHESIS` block: the concurrent
# SVA properties I1-I5/I9/I10 (yosys' free front end has no SVA -- they are
# covered by the simulation battery and their own mutation cross-checks) and
# the $display telemetry. The IMMEDIATE assertion a_p4_slot_bound sits
# OUTSIDE that block and is the property under test.
#
# sed rationale: see formal/README.md (uwire downgrade + sv2v upward-
# reference prefix strip). The perl pass removes the `else $error/$fatal`
# action blocks after immediate assertions -- yosys parses the assertion but
# not its action block; the check itself remains.
sv2v -E Assert -D SYNTHESIS \
	"$RTL/pkg/nexus_vendor_riscv_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_pkg.sv" \
	"$RTL/pkg/ct_cs_cpuif_types_pkg.sv" \
	"$SCRIPT_DIR/build/ct_pkg_small.sv" \
	"$RTL/pkg/tip_pkg.sv" \
	"$SCRIPT_DIR/build/ct_etip_pkg_small.sv" \
	"$SCRIPT_DIR/build/math_pkg_patched.sv" \
	"$RTL/external/common/counter.sv" \
	"$RTL/external/common/signal_cdc.sv" \
	"$RTL/external/common/signal_ack_lock_fsm.sv" \
	"$RTL/external/common/vector_cdc2.sv" \
	"$SCRIPT_DIR/build/fifo1clk_fwft_patched.sv" \
	"$SCRIPT_DIR/build/fifo2clk_fwft_patched.sv" \
	"$SCRIPT_DIR/build/sink_if_patched.sv" \
	"$SCRIPT_DIR/build/cvsink_if_patched.sv" \
	"$SCRIPT_DIR/build/cvsource_if_patched.sv" \
	"$SCRIPT_DIR/build/cvsource_if2_patched.sv" \
	"$SCRIPT_DIR/build/cvs_fifo_patched.sv" \
	"$RTL/external/stream/cvs_fifo2.sv" \
	"$RTL/external/stream/cvs_cdc_fifo2.sv" \
	"$RTL/external/stream/ovf_injector.sv" \
	"$RTL/pkg/tip_if.sv" \
	"$RTL/pkg/ct_preproc_if.sv" \
	"$RTL/pkg/ct_act_cap_if.sv" \
	"$RTL/pkg/ct_perfcnt_if.sv" \
	"$RTL/pkg/ct_cs_if.sv" \
	"$SCRIPT_DIR/build/source_if_patched.sv" \
	"$SRC_DUT" \
	"$SCRIPT_DIR/wrapper.sv" \
	| sed -e 's/\buwire\b/wire/g' -e 's/\bf_slot_env\.//g' -e 's/\bf_slots0\.//g' -e 's/\bf_slots1\.//g' \
	| perl "$SCRIPT_DIR/strip_assert_actions.pl" \
	> "$SCRIPT_DIR/build/composer_slots_formal.v"

# SLOT_MINUS1=1 (red cross-check R-TIGHT): shrink the bound by exactly one
# slot, whatever the formula produces. Done on the GENERATED model so the
# check stays formula-agnostic -- a second, hand-maintained copy of the
# formula here would drift away from ct_pkg.sv without anyone noticing, which
# is the failure mode this whole gate exists to prevent.
if [ "${SLOT_MINUS1:-0}" = "1" ]; then
	perl -0pi -e 's/(localparam ct_pkg_ETIP_PAR_MSG = )(.*?);/${1}(${2}) - 1;/s' \
		"$SCRIPT_DIR/build/composer_slots_formal.v"
	grep -q "localparam ct_pkg_ETIP_PAR_MSG = (.*) - 1;" \
		"$SCRIPT_DIR/build/composer_slots_formal.v" \
		|| { echo "ERROR: SLOT_MINUS1 rewrite did not take" >&2; exit 2; }
	echo "[red] ETIP_PAR_MSG reduced by one slot"
fi

cd "$SCRIPT_DIR"
sby -f composer_slots.sby "$@"
