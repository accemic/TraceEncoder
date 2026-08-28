#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P3 DF-address-compression gate (stage-2 gate "dfcompress"): XOR mode +
# TCODE 13/14 re-anchors + WARL negatives + mode-0 (FULL) neutrality.
#
#   [mode0] data_basic + data_split run with DataAddrCompress=FULL (reset):
#     their streams must carry NO 13/14 message and keep the REF_DF md5
#     anchors (data-only streams carry no config message, so these hashes
#     are stable against CAPS growth -- unlike combined, which is anchored
#     by its decode gates only; re-mint policy: bld/ref_df_mint.log).
#   [xor] test 03 (addr_compress): data-only XOR stream. WARL probes
#     ($fatal) ran in-sim; offline --data + --ctxp + --sync 2, the exact
#     data-TCODE sequence (13,5,5,5,6,6,6,6,14,5 -- derivation in the TB
#     header), NO off-window address anywhere in the stream (negative gate
#     "no DF while DataTracing=0" AND the P3-F1 DataTracing-edge alignment
#     guard, both directions -- see the TB header), no ERROR in the stream,
#     decoder auto-enabled via STREAM EVIDENCE (a data-only stream has no
#     config message), and a -dfxor CLI re-decode reproduces the identical
#     event list (third mode source).
#   [ovf] test 04 (data_sync): combined stream + overflow. Soft --pc/--data
#     (the storm loses bytes by design), --overflow HARD; then the HARD
#     P3 gates: first DF after every ERROR is 13/14 (T2c re-anchor), the
#     decoded data events form an order-preserving subsequence of the
#     oracle (XOR reconstruction never invents an address, even across the
#     loss episode), decoder auto-enabled via TCODE-58 ENAB.21, and
#     --tsmono --sync 4 in a separate non-soft invocation (13/14 carry an
#     ABSOLUTE timestamp; a delta mis-booked as absolute steps backwards).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_nexrv

fail=0

# REF_DF anchors (minted 2026-08-04 pre-P3 @ a7465ef, bld/ref_df_mint.log;
# byte-identity of the FULL-mode data-only streams is part of the P3
# byte-neutrality promise).
REF_DATA_BASIC_MD5="9ae1fddd2333680a2d11124c3515caee"
REF_SPLIT_LOAD_MD5="6d953a1e0a05217f30abcb734c4108fd"

# Latest sim artefact of a TB under bld/ (newest wins, cli_sim.sh layout).
find_art() { # $1 = filename
	find "$here/bld" -name "$1" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

check_no_1314() { # $1 = nexrv log, $2 = leg name
	local n
	n=$(grep -cE 'TCODE\[6\]=1[34] ' "$1" || true)
	if [ "$n" -ne 0 ]; then
		echo "[dfcompress] $2: FAIL -- $n TCODE 13/14 message(s) in a FULL-mode stream"; fail=1
	else
		echo "[dfcompress] $2: no 13/14 in FULL mode -- PASS"
	fi
}

check_md5() { # $1 = atb file, $2 = expected md5, $3 = leg name
	local got
	got=$(md5sum "$1" | cut -d' ' -f1)
	if [ "$got" != "$2" ]; then
		echo "[dfcompress] $3: FAIL -- ATB md5 $got != REF_DF $2"; fail=1
	else
		echo "[dfcompress] $3: ATB md5 == REF_DF ($2) -- PASS"
	fi
}

echo "===== [dfcompress] mode0: data_basic (FULL, byte-neutral, no 13/14) ====="
if ! bash scripts/cli_sim.sh data_basic --ctxp; then
	echo "[dfcompress] data_basic decode gate: FAIL"; fail=1
fi
atb="$(find_art data_basic_tb.atb.bin)"
log="$(find_art data_basic_tb.nexrv.log)"
if [ -z "$atb" ] || [ -z "$log" ]; then
	echo "[dfcompress] FAIL: data_basic artefacts missing under bld/"; fail=1
else
	check_md5 "$atb" "$REF_DATA_BASIC_MD5" "data_basic"
	check_no_1314 "$log" "data_basic"
fi

echo "===== [dfcompress] mode0: data_split (FULL, byte-neutral, no 13/14) ====="
if ! bash scripts/cli_sim.sh data_split --pc --data; then
	echo "[dfcompress] data_split decode gate: FAIL"; fail=1
fi
atb="$(find_art split_load_tb.atb.bin)"
log="$(find_art split_load_tb.nexrv.log)"
if [ -z "$atb" ] || [ -z "$log" ]; then
	echo "[dfcompress] FAIL: split_load artefacts missing under bld/"; fail=1
else
	check_md5 "$atb" "$REF_SPLIT_LOAD_MD5" "data_split"
	check_no_1314 "$log" "data_split"
fi

echo "===== [dfcompress] xor: test 03 addr_compress (XOR, 13/14 re-anchors) ====="
if ! bash scripts/cli_sim.sh addr_compress --data --ctxp --sync 2; then
	echo "[dfcompress] addr_compress decode gate: FAIL"; fail=1
fi
log03="$(find_art addr_compress_tb.nexrv.log)"
atb03="$(find_art addr_compress_tb.atb.bin)"
if [ -z "$log03" ] || [ -z "$atb03" ]; then
	echo "[dfcompress] FAIL: addr_compress artefacts missing under bld/"; fail=1
else
	# Exact deterministic data-TCODE sequence (see the TB header): head
	# re-anchor 13 (initial DataTracing edge, first DF is a STORE), three
	# XOR stores, four XOR loads (the last one is the BLK+8 load right
	# before the un-quiesced OFF edge -- alignment guard (a): pre-fix it
	# was silently dropped and this sequence had only nine entries),
	# re-anchor 14 for the first post-ON-edge access with its full address,
	# one XOR store.
	# sed (not `grep -o '[0-9]+'`): a bare number grep would also extract
	# the field-width 6 of every "TCODE[6]=" prefix and interleave the
	# sequence with bogus 6s.
	seq=$(grep -oE 'TCODE\[6\]=(5|6|13|14) ' "$log03" | sed -E 's/TCODE\[6\]=([0-9]+) /\1/' | paste -sd, -)
	exp_seq="13,5,5,5,6,6,6,6,14,5"
	if [ "$seq" != "$exp_seq" ]; then
		echo "[dfcompress] addr_compress: FAIL -- data TCODE sequence '$seq' != '$exp_seq'"; fail=1
	else
		echo "[dfcompress] addr_compress: data TCODE sequence $seq -- PASS"
	fi
	# Negative gate: the two off-window accesses (unique bit patterns
	# 0xAAAA_0000 / 0xBBBB_0000, addresses that occur nowhere else) must
	# not appear ANYWHERE in the decode -- neither as a reconstructed DFEVT
	# nor as a raw field. Alignment guard (b): pre-fix the 0xBBBB_0000 load
	# leaked as the TCODE-14 re-anchor and the next access XOR'd against it.
	if grep -qiE 'aaaa0000|bbbb0000' "$log03"; then
		echo "[dfcompress] addr_compress: FAIL -- off-window address leaked onto the wire"; fail=1
		grep -inE 'aaaa0000|bbbb0000' "$log03" | head -5 || true
	else
		echo "[dfcompress] addr_compress: no off-window address in the stream (DataTracing=0 negative + edge alignment) -- PASS"
	fi
	if grep -qE 'TCODE\[6\]=8 ' "$log03"; then
		echo "[dfcompress] addr_compress: FAIL -- unexpected ERROR message in a clean stream"; fail=1
	fi
	# Decoder mode source: data-only stream => STREAM EVIDENCE (no config
	# message exists to autoconfigure from).
	if grep -q 'DF address XOR decode enabled (stream evidence)' "$log03"; then
		echo "[dfcompress] addr_compress: decoder auto-enable via stream evidence -- PASS"
	else
		echo "[dfcompress] addr_compress: FAIL -- stream-evidence auto-enable marker missing"; fail=1
	fi
	# Third mode source: an explicit -dfxor re-decode must yield the
	# identical event list (CLI flag path, needed for mid-stream captures).
	sim_dir="$(dirname "$atb03")"
	"$NEXRV" -deco "$atb03" -pcinfo "$sim_dir/addr_compress_tb.nexrv.info" \
		-pcout "$sim_dir/addr_compress_tb.dfxor.pcout" -full -dfxor \
		> "$sim_dir/addr_compress_tb.dfxor.log" 2>&1 || true
	awk '/^\. DFEVT /{ sub(/^\. DFEVT /, ""); print }' "$sim_dir/addr_compress_tb.dfxor.log" \
		> "$sim_dir/addr_compress_tb.dfxor.data"
	if diff -q "$sim_dir/addr_compress_tb.decoded.data" "$sim_dir/addr_compress_tb.dfxor.data" > /dev/null; then
		echo "[dfcompress] addr_compress: -dfxor CLI re-decode identical -- PASS"
	else
		echo "[dfcompress] addr_compress: FAIL -- -dfxor re-decode differs from auto-enabled decode"; fail=1
		diff -u "$sim_dir/addr_compress_tb.decoded.data" "$sim_dir/addr_compress_tb.dfxor.data" | head -10 || true
	fi
fi

echo "===== [dfcompress] ovf: test 04 data_sync (ERROR re-anchor, tsmono) ====="
if ! bash scripts/cli_sim.sh data_sync --soft --pc --data --overflow; then
	echo "[dfcompress] data_sync decode gate: FAIL"; fail=1
fi
log04="$(find_art data_sync_tb.nexrv.log)"
if [ -z "$log04" ]; then
	echo "[dfcompress] FAIL: data_sync artefacts missing under bld/"; fail=1
else
	sim_dir="$(dirname "$log04")"
	# HARD (not --soft): after every ERROR (TCODE 8) the NEXT data-trace
	# message must be the synchronizing 13/14 form -- a plain 5/6 first
	# would XOR against an invalidated reference (T2c contract).
	awk '
		/TCODE\[6\]=8 /       { pend = 1; n_err++ }
		/TCODE\[6\]=(5|6) /   { if (pend) { printf "  plain DF (line %d) after ERROR without 13/14 re-anchor\n", NR; bad = 1; pend = 0 } }
		/TCODE\[6\]=1[34] /   { if (pend) { n_reanchor++ }; pend = 0 }
		END {
			printf "[dfcompress] data_sync: %d ERROR message(s), %d followed by a 13/14 first-DF re-anchor\n", n_err, n_reanchor
			if (n_err == 0)      { print "[dfcompress] data_sync: FAIL -- no ERROR decoded (overflow leg vacuous)"; exit 1 }
			if (n_reanchor == 0) { print "[dfcompress] data_sync: FAIL -- no 13/14 re-anchor after any ERROR"; exit 1 }
			exit bad
		}' "$log04"
	if [ $? -ne 0 ]; then
		echo "[dfcompress] data_sync: ERROR->13/14 re-anchor gate: FAIL"; fail=1
	else
		echo "[dfcompress] data_sync: ERROR->13/14 re-anchor gate: PASS"
	fi
	# HARD: decoded data events are an order-preserving subsequence of the
	# oracle (losses allowed, invented/garbage addresses are not).
	exp_lf="$sim_dir/data_sync_tb.expected.data.lf"
	tr -d '\r' < "$sim_dir/data_sync_tb.expected.data" > "$exp_lf"
	# BEGIN{i=0}: without it the first use of i is the STRING subscript ""
	# (not "0"), so ex[i] misses element 0 and the matcher skips ahead --
	# awk array subscripts are strings, uninitialized i is "".
	if awk 'BEGIN { i = 0 }
			NR==FNR { ex[n++] = $0; next }
			{ while (i < n && ex[i] != $0) i++;
			  if (i >= n) { printf "  decoded event %d not in oracle order: %s\n", FNR, $0; exit 1 }
			  i++; m++ }
			END { printf "[dfcompress] data_sync: %d decoded data events, all an in-order oracle subsequence\n", m }' \
			"$exp_lf" "$sim_dir/data_sync_tb.decoded.data"; then
		echo "[dfcompress] data_sync: subsequence gate: PASS"
	else
		echo "[dfcompress] data_sync: subsequence gate: FAIL"; fail=1
	fi
	# Decoder mode source: combined stream => TCODE-58 ENAB.21 autoconfig.
	if grep -q 'DF address XOR decode enabled (ENAB.21, auto)' "$log04"; then
		echo "[dfcompress] data_sync: decoder auto-enable via ENAB.21 -- PASS"
	else
		echo "[dfcompress] data_sync: FAIL -- ENAB.21 autoconfig marker missing"; fail=1
	fi
fi
# HARD tsmono (separate invocation: --soft must not soften the timestamp
# gate). 13/14 carry an ABSOLUTE timestamp; the reconstructed time column
# must never step backwards. --sync 4: startup + periodic + recovery syncs
# plus the 13/14 re-anchors.
if scripts/decode_and_check.sh --tsmono --sync 4 data_sync_tb; then
	echo "[dfcompress] data_sync: tsmono/sync gate: PASS"
else
	echo "[dfcompress] data_sync: tsmono/sync gate: FAIL"; fail=1
fi

if [ "$fail" -eq 0 ]; then
	echo "===== [dfcompress] OVERALL: PASS ====="
else
	echo "===== [dfcompress] OVERALL: FAIL ====="
fi
exit $fail
