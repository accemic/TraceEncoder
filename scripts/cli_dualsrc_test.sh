#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Two encoders, two SrcIDs, one funnel -- and the merged stream taken apart
# again. The unit-level gate for the multi-source separation that, until
# 2026-08-19, existed only at whole-SoC level.
#
# WHY THIS GATE EXISTS. An internal audit analysis (2026-08-19, not part of
# this repository; cited below as "L") found two holes at once (§5): NO
# testbench in this repository instantiated two encoders with different
# trTeInstFeatures.SrcID, and SrcBits = 2 -- the width
# duo, trio, rocket2 and cva6_2 all run -- appeared in no test at all. The one
# existing proof of separation was a demonstrator (duo), where a failure can
# come from a dozen places.
#
# WHY THE TWO PROGRAMS DIFFER, and why that is the entire point. The board
# capture that prompted this work (c2_rv32.bin) ran the SAME image at the SAME
# address on both cores: over 106 222 messages the two halves differed in
# exactly ONE bit each -- the SRC bit. A decoder that evaluates SRC perfectly
# and one that ignores it produce IDENTICAL results on such a capture, so it
# can neither confirm nor refute separation (L §3.3/§3.4). Here the two sources
# run different programs at disjoint addresses, so every mix-up shows up as a
# PC sequence that belongs to nobody.
#
# THE LEGS, in the order they are checked:
#   S1  the merged stream is a well-formed Nexus stream (0 error messages)
#   S2  both SRC values are present, and the config message of each source
#       carries ITS OWN {SrcID, SrcBits} (P0 = 0x2 / 0x12 at SrcBits = 2)
#   S3  the funnel really interleaved -- floor on the number of source changes
#       between consecutive messages (an interleaving that stopped happening
#       would make the separation trivially true)
#   S4  each half of the MERGED stream decodes to the reference PC sequence of
#       ITS OWN source, line for line (the actual separation claim)
#   S5  falsifiability, not assumed but shown: the two reference sequences are
#       different and their address ranges are disjoint, AND decoding one
#       source against the OTHER source's PCInfo must FAIL
#   S6  equivalence: the merged stream filtered by SRC decodes byte-identically
#       to what that encoder produced on its own -- merge + split is lossless
#   S7  the multi-target decode (-target 0 ... -target 1 ...), i.e. exactly the
#       command line the duo/cva6_2 board gates run, yields both sequences
#
# The RTL assertions of ct_L1_funnel (packet-continuation, ATDATA/ATID/ATBYTES)
# run along with the simulation; ct_xsim's SVA channel makes any of them red.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=dual_src_tb
ct_need_prj "$tb" "tests/instruction/39_dual_src/${tb}.abc" || exit $?

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
cd "$xd"
rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
xvlog --relax -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 \
	|| { echo "FAIL xvlog"; grep -i error xvlog.log | head; exit 4; }
xelab --relax --debug off "xil_defaultlib.${tb}" xil_defaultlib.glbl \
	-s "${tb}_snap" -log xelab.log >/dev/null 2>&1 \
	|| { echo "FAIL xelab"; grep -i error xelab.log | head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

echo "########## ${tb} (xsim)"
ct_xsim "xsim_${tb}.log" "${tb}_snap" -tclbatch _runall.tcl \
	|| { echo "FAIL: xsim leg unusable (reason above)"; exit 6; }
grep -aE '^\[dual_src_tb\]' "xsim_${tb}.log" | head -8

verdict=0
chk () { # $1 = label, $2 = actual, $3 = expected
	if [ "$2" = "$3" ]; then printf '%-52s: PASS (%s)\n' "$1" "$2"
	else printf '%-52s: FAIL (got %s, want %s)\n' "$1" "$2" "$3"; verdict=1; fi
}
chk_ge () { # $1 = label, $2 = actual, $3 = floor
	if [ "${2:-0}" -ge "$3" ]; then printf '%-52s: PASS (%s >= %s)\n' "$1" "$2" "$3"
	else printf '%-52s: FAIL (%s < %s)\n' "$1" "${2:-0}" "$3"; verdict=1; fi
}

# PC column of a -full decode log, normalised the way the other gates do it.
pcs_of_log () { grep -aE '[0-9]+ PC: 0x' "$1" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' \
	| sed -E 's/^0x0*/0x/; s/^0x$/0x0/' | tr 'A-F' 'a-f'; }
norm_file () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }

echo "======================================================"
# --- S1: the merged stream is a well-formed Nexus stream -------------------
"$NEXRV" -dump "${tb}.merged.bin" dump_msg.txt -src 2 -msg > dump_msg.log 2>&1 || true
"$NEXRV" -dump "${tb}.merged.bin" dump_all.txt -src 2      > dump_all.log 2>&1 || true
stat_line="$(grep -a '^Stat:' dump_msg.log | tail -1)"
echo "merged stream: ${stat_line:-<no Stat line>}"
chk "S1 merged stream has 0 error messages" \
	"$(grep -ac '0 error messages' dump_msg.log || true)" 1

n_msg=$(grep -acE 'TCODE\[6\]=' dump_msg.txt || true)
chk_ge "S1 messages in the merged stream" "$n_msg" "${MIN_MSGS:-40}"

# --- S2: both sources are on the wire, each with ITS OWN identity ----------
n_src0=$(grep -acE 'SRC\[2\]=0x0' dump_all.txt || true)
n_src1=$(grep -acE 'SRC\[2\]=0x1' dump_all.txt || true)
chk_ge "S2 messages carrying SRC=0" "$n_src0" "${MIN_PER_SRC:-15}"
chk_ge "S2 messages carrying SRC=1" "$n_src1" "${MIN_PER_SRC:-15}"
# The config message repeats {SrcID, SrcBits} as P0 -- 12'd0/12'd1 at SrcBits=2
# gives 0x2 and 0x12. That is the encoder's own statement about its identity,
# independent of the SRC field the decoder just parsed (L §3.2).
chk "S2 config of source 0 says {SrcID=0,SrcBits=2}" \
	"$(grep -ac 'P0\[6\]=0x2 ' dump_all.txt || true)" 1
chk "S2 config of source 1 says {SrcID=1,SrcBits=2}" \
	"$(grep -ac 'P0\[6\]=0x12 ' dump_all.txt || true)" 1

# --- S3: the funnel really interleaved ------------------------------------
grep -oaE 'SRC\[2\]=0x[01]' dump_all.txt | sed 's/.*=0x//' > src_seq.txt
n_alt=$(awk 'NR>1 && $0!=p {n++} {p=$0} END {print n+0}' src_seq.txt)
chk_ge "S3 source changes between consecutive messages" "$n_alt" "${MIN_ALT:-30}"

# --- S4: each half decodes to ITS OWN reference sequence -------------------
for s in 0 1; do
	"$NEXRV" -deco "${tb}.merged.bin" -pcinfo "${tb}.src${s}.info" \
		-pcout "split${s}.pco" -src 2 -srcfilter "$s" -full > "deco_split${s}.log" 2>&1
	pcs_of_log "deco_split${s}.log" > "split${s}.pcs"
	norm_file "${tb}.src${s}.expected.pcs" > "exp${s}.pcs"
	n_got=$(grep -c . "split${s}.pcs" || true)
	n_exp=$(grep -c . "exp${s}.pcs" || true)
	if [ "$n_got" -gt 0 ] && cmp -s "split${s}.pcs" "exp${s}.pcs"; then
		printf '%-52s: PASS (%s PCs)\n' "S4 merged|SRC=$s == reference of source $s" "$n_got"
	else
		printf '%-52s: FAIL (got %s PCs, reference %s)\n' \
			"S4 merged|SRC=$s == reference of source $s" "$n_got" "$n_exp"
		diff "split${s}.pcs" "exp${s}.pcs" | head -4
		verdict=1
	fi
done

# --- S5: the test CAN fail ------------------------------------------------
# (a) the two references really are different programs at disjoint addresses.
if cmp -s exp0.pcs exp1.pcs; then
	printf '%-52s: FAIL (identical -- the whole gate would be vacuous)\n' \
		"S5 the two reference sequences differ"
	verdict=1
else
	printf '%-52s: PASS\n' "S5 the two reference sequences differ"
fi
n_shared=$(sort -u exp0.pcs > _e0.u; sort -u exp1.pcs > _e1.u; comm -12 _e0.u _e1.u | grep -c . || true)
chk "S5 address ranges are disjoint (shared PCs)" "$n_shared" 0
# (b) the cross decode must FAIL. Decoding source 0's messages against source
#     1's program is the "sources got mixed up" case; if that came out green,
#     nothing above would mean anything.
for s in 0 1; do
	o=$(( 1 - s ))
	"$NEXRV" -deco "${tb}.merged.bin" -pcinfo "${tb}.src${o}.info" \
		-pcout "cross${s}.pco" -src 2 -srcfilter "$s" -full > "deco_cross${s}.log" 2>&1
	rc=$?
	pcs_of_log "deco_cross${s}.log" > "cross${s}.pcs"
	if [ "$rc" -ne 0 ] || ! cmp -s "cross${s}.pcs" "exp${o}.pcs"; then
		printf '%-52s: PASS (rc=%s)\n' "S5 SRC=$s against the PCInfo of source $o fails" "$rc"
	else
		printf '%-52s: FAIL -- it decoded cleanly, so the two\n' \
			"S5 SRC=$s against the PCInfo of source $o fails"
		printf '%-52s  programs are not distinguishable\n' ""
		verdict=1
	fi
done

# --- S6: merge + split is lossless ----------------------------------------
for s in 0 1; do
	"$NEXRV" -deco "${tb}.src${s}.bin" -pcinfo "${tb}.src${s}.info" \
		-pcout "alone${s}.pco" -src 2 -full > "deco_alone${s}.log" 2>&1
	if cmp -s "split${s}.pco" "alone${s}.pco"; then
		printf '%-52s: PASS\n' "S6 merged|SRC=$s pcout == encoder $s alone, byte-identical"
	else
		printf '%-52s: FAIL\n' "S6 merged|SRC=$s pcout == encoder $s alone, byte-identical"
		verdict=1
	fi
done

# --- S7: the multi-target decode the board gates use ----------------------
"$NEXRV" -deco "${tb}.merged.bin" -src 2 \
	-target 0 -pcinfo "${tb}.src0.info" -pcout mt0.pco \
	-target 1 -pcinfo "${tb}.src1.info" -pcout mt1.pco -stat > deco_mt.log 2>&1
chk "S7 multi-target run says Decoded OK" \
	"$(grep -ac 'Decoded OK' deco_mt.log || true)" 1
for s in 0 1; do
	# -pcout is binary; -conv turns it back into a PC list using the same
	# PCInfo, which is how the sequence becomes comparable.
	"$NEXRV" -conv -pcinfo "${tb}.src${s}.info" -pconly "mt${s}.pco" \
		-pcseq "mt${s}.pcs.raw" > "conv${s}.log" 2>&1
	sed -E 's/,.*$//' "mt${s}.pcs.raw" | sed -E 's/^0x0*/0x/; s/^0x$/0x0/' \
		| tr 'A-F' 'a-f' > "mt${s}.pcs"
	n_got=$(grep -c . "mt${s}.pcs" || true)
	if [ "$n_got" -gt 0 ] && cmp -s "mt${s}.pcs" "exp${s}.pcs"; then
		printf '%-52s: PASS (%s PCs)\n' "S7 -target $s == reference of source $s" "$n_got"
	else
		printf '%-52s: FAIL (got %s PCs)\n' "S7 -target $s == reference of source $s" "$n_got"
		diff "mt${s}.pcs" "exp${s}.pcs" | head -4
		verdict=1
	fi
done

echo "======================================================"
if [ "$verdict" -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $verdict
