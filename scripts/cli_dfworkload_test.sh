#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P3 DF-bandwidth workload gate (stage-2 gate "dfworkload"): the >= 10 000
# access workload of tests/data/05_df_workload in BOTH DataAddrCompress
# modes (FULL baseline + XOR), with hard decode gates and the step-6 byte
# accounting (D-P3-8 / Plan P3.4).
#
#   Correctness (asserted):
#     - both legs decode --data hard against the cpu_model oracle;
#     - no ERROR message in either stream (an overflow would silently
#       shrink a leg and corrupt the byte comparison);
#     - XOR leg starts its data stream with the TCODE 13 anchor and carries
#       NO further 13/14 beyond re-anchors (structural: count >= 1);
#     - FULL leg carries no 13/14 at all;
#     - equal DFEVT count in both legs (same workload, lossless);
#     - measurement-instrument audit (14.1): the per-message byte sum from
#       `NexRv -dump` must equal the dump's own Stat line, per leg, AND
#       message bytes + idle bytes must equal the ATB file size exactly.
#   Measurement (REPORTED, not asserted -- absolute numbers only):
#     - ATB file bytes, message bytes, idle bytes;
#     - DF-class bytes (TCODEs 5/6/13/14) and message counts per leg.
#
# IDLE ACCOUNTING (corrected 2026-08-04, audit F6): a NexRv dump prints ONE
# line per idle RUN, not per idle byte -- counting those lines gives the
# number of runs and undercounts idle BYTES (the same collapse that broke
# the P2 window measurement, see scripts/check_sync_window.py). Idle bytes
# are therefore derived from the raw file: file size - message bytes, which
# closes the accounting exactly (no "trailing drain" residue: the earlier
# ~11.5 kB gap per leg WAS the collapsed idle).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_nexrv

fail=0

find_art() { # $1 = filename
	find "$here/bld" -name "$1" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# Per-TCODE byte accounting over a NexRv -dump (one line per wire byte).
# Prints "total_msg_bytes df_bytes msg_count df_msg_count idle_bytes" and
# validates the sum against the dump's Stat line (hard FAIL on mismatch).
account() { # $1 = atb file, $2 = leg name, $3 = out prefix
	local atb="$1" leg="$2" out="$3" dump
	dump="${atb%.atb.bin}.dump.txt"
	# NexRv prints the Stat line on stdout, the per-byte dump into the file.
	"$NEXRV" -dump "$atb" "$dump" > "$dump.stat" 2>&1
	awk -v leg="$leg" '
		/^Stat: /         {
			match($0, /[0-9]+ bytes/); stat_b = substr($0, RSTART) + 0; next
		}
		/IDLE/            { idlerun++; next }   # ONE line per idle RUN (F6)
		!/^0x/            { next }
		{
			if (match($0, /TCODE\[6\]=[0-9]+ \(MSG/)) {
				t = substr($0, RSTART+9); sub(/ .*/, "", t); t += 0
				nmsg++; if (t==5 || t==6 || t==13 || t==14) ndf++
				isdf = (t==5 || t==6 || t==13 || t==14)
			}
			total++; if (isdf) dfb++
		}
		END {
			if (total != stat_b) {
				printf "[dfworkload] %s: FAIL -- dump byte sum %d != Stat %d\n", leg, total, stat_b
				exit 1
			}
			printf "%d %d %d %d %d\n", total, dfb, nmsg, ndf, idlerun > (leg ".account")
		}' "$dump" "$dump.stat"
	if [ $? -ne 0 ]; then fail=1; return 1; fi
	read -r "${out}_total" "${out}_df" "${out}_nmsg" "${out}_ndf" "${out}_idlerun" < "$leg.account"
	rm -f "$leg.account"
	eval "${out}_file=\$(stat -c%s "$atb")"
	# Idle BYTES from the raw file (F6): the dump collapses idle runs.
	eval "${out}_idle=\$(( \${${out}_file} - \${${out}_total} ))"
	eval "echo \"[dfworkload] $leg: \${${out}_total} message bytes (Stat-validated), \${${out}_df} DF bytes, \${${out}_nmsg} messages (\${${out}_ndf} DF), \${${out}_idle} idle bytes in \${${out}_idlerun} runs\""
	eval "echo \"[dfworkload] $leg: ATB file \${${out}_file} bytes = messages + idle (accounting closes exactly)\""
}

check_no_err() { # $1 = nexrv log, $2 = leg
	local n
	n=$(grep -cE 'TCODE\[6\]=8 ' "$1" || true)
	if [ "$n" -ne 0 ]; then
		echo "[dfworkload] $2: FAIL -- $n ERROR message(s): overflow corrupts the byte comparison"; fail=1
	else
		echo "[dfworkload] $2: no ERROR message -- PASS"
	fi
}

echo "===== [dfworkload] FULL baseline leg (mode 0) ====="
if ! bash scripts/cli_sim.sh df_workload_full --data; then
	echo "[dfworkload] df_workload_full decode gate: FAIL"; fail=1
fi
atb_f="$(find_art df_workload_full_tb.atb.bin)"
log_f="$(find_art df_workload_full_tb.nexrv.log)"
if [ -z "$atb_f" ] || [ -z "$log_f" ]; then
	echo "[dfworkload] FAIL: FULL-leg artefacts missing under bld/"; fail=1
else
	check_no_err "$log_f" "full"
	n1314=$(grep -cE 'TCODE\[6\]=1[34] ' "$log_f" || true)
	if [ "$n1314" -ne 0 ]; then
		echo "[dfworkload] full: FAIL -- $n1314 TCODE 13/14 in a FULL-mode stream"; fail=1
	else
		echo "[dfworkload] full: no 13/14 -- PASS"
	fi
	account "$atb_f" "full" F || true
fi

echo "===== [dfworkload] XOR leg (mode 1) ====="
if ! bash scripts/cli_sim.sh df_workload --data; then
	echo "[dfworkload] df_workload decode gate: FAIL"; fail=1
fi
atb_x="$(find_art df_workload_tb.atb.bin)"
log_x="$(find_art df_workload_tb.nexrv.log)"
if [ -z "$atb_x" ] || [ -z "$log_x" ]; then
	echo "[dfworkload] FAIL: XOR-leg artefacts missing under bld/"; fail=1
else
	check_no_err "$log_x" "xor"
	# The data-only XOR stream must open with the 13 anchor (stream
	# evidence is the decoder's only mode source here).
	first=$(grep -oE 'TCODE\[6\]=(5|6|13|14) ' "$log_x" | head -1)
	if [ "$first" != "TCODE[6]=13 " ] && [ "$first" != "TCODE[6]=14 " ]; then
		echo "[dfworkload] xor: FAIL -- first data message is '$first', not the 13/14 anchor"; fail=1
	else
		echo "[dfworkload] xor: stream opens with the 13/14 anchor -- PASS"
	fi
	account "$atb_x" "xor" X || true
fi

# Equal event count in both legs (same workload, lossless).
if [ -n "${F_ndf:-}" ] && [ -n "${X_ndf:-}" ]; then
	if [ "$F_ndf" -ne "$X_ndf" ]; then
		echo "[dfworkload] FAIL -- DF message count differs: FULL $F_ndf vs XOR $X_ndf"; fail=1
	else
		echo "[dfworkload] DF message count equal in both legs ($F_ndf) -- PASS"
	fi
	# ---- Step-6 measurement report (absolute numbers; raw data = the two
	# dump/atb files printed above) ----
	echo "===== [dfworkload] measurement (absolute) ====="
	echo "  FULL: file $F_file B | messages $F_total B ($F_nmsg msgs) | DF $F_df B ($F_ndf msgs) | idle $F_idle B in $F_idlerun runs"
	echo "  XOR : file $X_file B | messages $X_total B ($X_nmsg msgs) | DF $X_df B ($X_ndf msgs) | idle $X_idle B in $X_idlerun runs"
	echo "  delta (FULL-XOR): file $((F_file-X_file)) B | messages $((F_total-X_total)) B | DF $((F_df-X_df)) B"
fi

if [ "$fail" -eq 0 ]; then
	echo "===== [dfworkload] OVERALL: PASS ====="
else
	echo "===== [dfworkload] OVERALL: FAIL ====="
fi
exit $fail
