#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Decoder regression corpus: archived campaign captures must keep decoding to
# their recorded verdicts. A decoder change may never turn an old green
# capture red -- that is the whole point of keeping them.
#
#   bash scripts/run_corpus_regression.sh
#
# Corpus location: verification/corpus/*.tar.gz, each holding
#   trace.bin + prog.pcinfo + expect.txt
# where expect.txt is one line, either "DECODED_OK <n_instr>" or
# "EXPECT_FAIL <substring>".
#
# Needs the pinned CTTD reference decoder (py scripts/fetch_cttd.py). Without
# it this exits 78 (TOOL) -- "the decoder is missing" is not "the captures
# regressed", and the two must never print the same verdict.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_nexrv
fail=0

shopt -s nullglob
corpus=(verification/corpus/*.tar.gz)
if [ ${#corpus[@]} -eq 0 ]; then
	# Not a pass: an empty corpus verified nothing, and a run that verified
	# nothing must not be indistinguishable from a run that verified
	# everything.
	echo "ERROR: corpus empty (verification/corpus/) -- nothing to regress against." >&2
	exit 78
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for c in "${corpus[@]}"; do
	name="$(basename "$c" .tar.gz)"
	rm -rf "$work/$name"; mkdir -p "$work/$name"
	tar xzf "$c" -C "$work/$name"
	exp="$(cat "$work/$name/expect.txt")"
	"$NEXRV" -deco "$work/$name/trace.bin" -pcinfo "$work/$name/prog.pcinfo" \
	         -pcout "$work/$name/out.pcout" -stat ${DECO_FLAGS:--bp} \
	         > "$work/$name/deco.log" 2>&1
	case "$exp" in
		DECODED_OK*)
			want="${exp#DECODED_OK }"
			if grep -q "Decoded OK ($want instructions)" "$work/$name/deco.log"; then
				echo "  [PASS] $name (Decoded OK $want)"
			else
				echo "  [FAIL] $name: $(tail -2 "$work/$name/deco.log" | tr '\n' ' ')"
				fail=1
			fi ;;
		EXPECT_FAIL*)
			pat="${exp#EXPECT_FAIL }"
			if grep -q "$pat" "$work/$name/deco.log"; then
				echo "  [PASS] $name (expected abort: $pat)"
			else
				echo "  [FAIL] $name: expected abort '$pat' did not happen"
				fail=1
			fi ;;
		*) echo "  [FAIL] $name: unknown expect '$exp'"; fail=1 ;;
	esac
done

echo "========== CORPUS-SUMMARY: ${#corpus[@]} capture(s), $([ $fail -eq 0 ] && echo 'all green' || echo 'RED') =========="
exit $fail
