#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Red mutation cross-checks for the P3 formatter properties (P-FMT-1..5).
# No historical defect commit exists for the DF-compression family, so each
# property family is shown red under a deliberate single-line defect on a
# BUILD-LOCAL copy of the DUT source (run.sh MUTATE hook; the tree is never
# touched -- pattern from formal/preproc_sync/run_red.sh):
#   M-A reference upkeep broken : the RefDaddr/flag update loses its
#                                 msg_fire emission gate (advances on every
#                                 offered DF, also during stalls). The
#                                 mutated line drives BOTH RefDaddr and
#                                 DfReanchor, so the cheapest counterexample
#                                 is the contract mirror (A_fmt4_pend_mirror,
#                                 model line 697: a DF offered during a stall
#                                 consumes the flag without an emission) --
#                                 the solver is free to pick a witness that
#                                 re-seats RefDaddr on its own value, which
#                                 leaves A_fmt2_ref_stable satisfied. Target
#                                 family is therefore reference upkeep OR its
#                                 mirror; M-C below pins the reference family
#                                 on its own.
#   M-B sticky re-anchor removed: the T2(a)/(c) set on sync/ERROR emission
#                                 is deleted -- after an ERROR the next DF
#                                 would XOR against an invalidated reference
#                                 -> must fail in the sticky family
#                                    (A_fmt4_pend_mirror, w_pend mirror)
#   M-C reference ungated only  : the gate is removed from the RefDaddr
#                                 assignment ALONE (DfReanchor keeps it), so
#                                 the mirror stays intact and only the
#                                 reference family can see the defect
#                                 (A_fmt2_ref_stable / _seated, A_fmt1,
#                                 p_ref_q / p_daddr_q relations).
#   M-D tcode direction swapped : df_sync_tcode maps READ->13 / WRITE->14
#                                 -> A_fmt1_tcode_dir (the decoder would
#                                 flip every re-anchored access direction)
#   M-E compress gate dropped   : df_sync_now loses df_compress_active, so
#                                 a FULL-mode stream would emit 13/14
#                                 (a wire-format break for every decoder
#                                 that did not negotiate compression)
#                                 -> A_fmt3_full_no_upgrade
#   M-F XOR replaced by the      : the "compressed" UADDR carries the FULL
#       full address              address -- the decoder would XOR it
#                                 against its reference and reconstruct
#                                 garbage -> A_fmt5_xor_value
#   M-G reference re-seated with : RefDaddr stores the transmitted DELTA
#       the delta                  instead of the address -> the XOR chain
#                                 drifts from the second access on
#                                 -> A_fmt2_ref_seated
#   M-H sync beat seats the      : only the 13/14 beat seats wrongly, the
#       delta                      plain XOR beats stay correct
#                                 -> A_fmt1_ref_eq_addr
#
# Isolation (masks, red runs ONLY -- see wrapper.sv): yosys reports ONE
# failing assertion per run. Two of the properties above are strictly
# IMPLIED by a neighbour that is checked in the same cycle and therefore
# always fires first:
#   A_fmt3_full_no_upgrade  <=  A_fmt4_reanchor_upgrade (the equality)
#   A_fmt1_ref_eq_addr      <=  A_fmt2_ref_seated (p_dfsync_q => p_dfemit_q,
#                                                  identical consequent)
# Their red runs therefore compile the generalization out
# (SV2V_DEFS=-DRED_MASK_FMT4UPG / -DRED_MASK_FMT2SEATED) so the reported
# FAIL is provably the target itself. The green run never sets a define.
# Each red run maps EVERY failing line of the generated model back to the
# wrapper source (the line PLUS its guard line -- two of the asserts are
# textually identical and differ only in their guard), so the FAIL is
# provably on the target property (a defect that trips an unrelated
# property is reported as such).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED_DONE=0
run_mut () { # $1 name, $2 perl expr, $3 target-token regex, $4 family label, [$5 sv2v defines]
	local name="$1" expr="$2" tokens="$3" family="$4" defs="${5:-}"
	# RED_ONLY='<regex>' re-runs a subset (each BMC costs ~10 min; a tool
	# hiccup in one mutation must not force the whole suite again).
	if [ -n "${RED_ONLY:-}" ] && ! echo "$name" | grep -qE "${RED_ONLY}"; then
		echo "== red mutation $name -- SKIPPED (RED_ONLY=${RED_ONLY})"
		return 0
	fi
	local log="$SCRIPT_DIR/build/red_$name.log"
	echo "== red mutation $name (expect FAIL on bmc; target: $family${defs:+; isolation $defs})"
	if MUTATE="$expr" SV2V_DEFS="$defs" bash "$SCRIPT_DIR/run.sh" bmc > "$log" 2>&1; then
		echo "ERROR: mutation $name PASSED -- property does not see the defect."
		exit 1
	fi
	if ! grep -q "DONE (FAIL" "$log"; then
		echo "ERROR: mutation $name ended without a proper FAIL (tool error?):"
		tail -5 "$log"
		exit 1
	fi
	# Map every reported failing assert back to the assert source (sv2v
	# strips comments, so match on the property's signal tokens). The GUARD
	# line is included: A_fmt2_ref_seated and A_fmt1_ref_eq_addr are
	# textually identical and differ only in their guard.
	local hit=0 line src
	while read -r line; do
		[ -n "$line" ] || continue
		src=$(sed -n "$((line > 1 ? line - 1 : line)),${line}p" \
			"$SCRIPT_DIR/build/nexus_formatter_formal.v" | tr '\n\t' '  ')
		printf '   failing assert (line %s): %s\n' "$line" "$src"
		if echo "$src" | grep -qE "$tokens"; then hit=1; fi
	done < <(grep "Assert failed in" "$log" | grep -oE 'formal\.v:[0-9]+' | cut -d: -f2 | sort -un)
	if [ "$hit" -ne 1 ]; then
		echo "ERROR: mutation $name failed OUTSIDE its target property ($family: $tokens)."
		exit 1
	fi
	grep -E "DONE \(FAIL" "$log" | head -1
	RED_DONE=$((RED_DONE + 1))
}

mkdir -p "$SCRIPT_DIR/build"

run_mut MA_ref_upkeep \
	's/if \(msg_fire && df_is_df && df_compress_active\) begin/if (df_is_df && df_compress_active) begin/' \
	'p_ref_q|p_daddr_q|w_pend|f_reanchor' \
	'reference upkeep or its contract mirror'

run_mut MB_sticky_removed \
	's/if \(msg_fire && \(tcode_is_sync \|\| \(trace_msg\.tcode == NEXUS_MSG_ERROR\)\)\) begin\s*\n\s*DfReanchor <= 1.b1;\s*\n\s*end/\n/s' \
	'w_pend|f_reanchor' \
	'sticky re-anchor mirror'

run_mut MC_ref_ungated \
	's/if \(msg_fire && df_is_df && df_compress_active\) begin\n(\s*)RefDaddr(\s*)<= (df_daq\.addr_idtag\[ADDR_WIDTH-1:0\];)\n/if (df_is_df && df_compress_active) begin\n$1RefDaddr$2<= $3\n\t\t\t\tend\n\t\t\t\tif (msg_fire && df_is_df && df_compress_active) begin\n/' \
	'p_ref_q|p_daddr_q' \
	'reference upkeep (P-FMT-2)'

run_mut MD_tcode_dir_swapped \
	's/\? NEXUS_MSG_DATA_TRACE_READ_SYNC\n(\s*): NEXUS_MSG_DATA_TRACE_WRITE_SYNC/? NEXUS_MSG_DATA_TRACE_WRITE_SYNC\n$1: NEXUS_MSG_DATA_TRACE_READ_SYNC/s' \
	'f_dut_sync_tc' \
	'A_fmt1_tcode_dir (13/14 direction)'

run_mut MF_xor_full_addr \
	"s/: GetDaddrXor\\(df_daq\\.addr_idtag, RefDaddr\\);/: df_daq.addr_idtag[ADDR_WIDTH-1:0];/s" \
	'f_dut_xor' \
	'A_fmt5_xor_value (delta value)'

run_mut MG_ref_seated_delta \
	's/RefDaddr(\s*)<= df_daq\.addr_idtag\[ADDR_WIDTH-1:0\];/RefDaddr$1<= daddr_xor;/s' \
	'p_dfemit_q.*f_refdaddr == p_daddr_q' \
	'A_fmt2_ref_seated (re-seat on emission)'

run_mut ME_full_upgrade \
	's/df_sync_now = df_compress_active && DfReanchor && df_is_df;/df_sync_now = DfReanchor \&\& df_is_df;/s' \
	'!f_compress.*!f_dut_sync_now' \
	'A_fmt3_full_no_upgrade (FULL mode never upgrades)' \
	'-DRED_MASK_FMT4UPG'

run_mut MH_sync_beat_seats_delta \
	's/RefDaddr(\s*)<= df_daq\.addr_idtag\[ADDR_WIDTH-1:0\];/RefDaddr$1<= DfReanchor ? daddr_xor : df_daq.addr_idtag[ADDR_WIDTH-1:0];/s' \
	'p_dfsync_q.*f_refdaddr == p_daddr_q' \
	'A_fmt1_ref_eq_addr (re-anchor invariant)' \
	'-DRED_MASK_FMT2SEATED'

echo "RED MUTATION CROSS-CHECKS OK ($RED_DONE/${RED_TOTAL:-8} red where they must be${RED_ONLY:+; subset RED_ONLY=$RED_ONLY})."
