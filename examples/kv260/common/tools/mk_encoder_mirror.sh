#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# mk_encoder_mirror.sh -- build a MIRROR of this repository's encoder tree with
# a different button state, under bld/. The Bash port of the predecessor repository's
# sim/rocket/mk_ctte_m4.ps1 and sim/cva6_rv64/mk_ctte64.ps1, merged into one
# tool (the two differed only in "with profile" vs "without").
#
#   bash examples/kv260/common/tools/mk_encoder_mirror.sh --dest <dir> \
#        [--profile slimfull_gold] [--xlen 64] [--ctx-width 22] \
#        [--slicer-steps N] [--force] [--src <repo-root>]
#
# The two mirrors the KV260 examples ask for, verbatim:
#
#   # cva6_2 + rocket2  (bld/m4_rocket_2hart/ctte_slim64)
#   ... --dest bld/m4_rocket_2hart/ctte_slim64 --profile slimfull_gold \
#       --xlen 64 --ctx-width 22
#   # cva6_linux64 + `rocket_linux -tclargs 0 64`  (bld/w1_rv64_decode/ctte_xlen64)
#   ... --dest bld/w1_rv64_decode/ctte_xlen64 --xlen 64
#
# WHY A MIRROR AND NOT A SWITCH -- three reasons, none of them taste:
#
#  1. CT_XLEN is a `localparam` in rtl/pkg/ct_pkg.sv, not a `define: the
#     address width is a synthesis parameter of the netlist, not a runtime
#     mode. There is no -generic that turns it.
#  2. The repository's own rtl/ is the RV32 tree and SIX other examples build
#     against it (mbv, duo, trio, tgc5b2_axis_wp, cva6_linux, and rocket_linux's
#     32-bit branch). Flipping it is not a switch, it is a change to six other
#     demonstrators.
#  3. Parallel work. mk_ctte_m4.ps1 named the reason: a synthesis against a tree
#     somebody is editing proves nothing, because the netlist is not
#     reproducible and the measured number cannot be attributed. This tool
#     therefore only ever READS the working tree.
#
# WHAT THE PROFILE DRAGS ALONG. A profile (scripts/ct_profiles.sh) flips ~20
# switches AND needs a CSR regblock generated to match -- without it the storage
# for switched-off fields stays in the netlist and the "slim" area comes out too
# large. So a profile mirror also carries rdl/, and scripts/gen_rdl_profile.py
# runs in its OUT-OF-TREE mode (--pkg/--rdl-dir/--out-dir). The generator is
# invoked from the WORKING TREE, not from the copy: its pinned-venv search finds
# .venv-rdl-win only relative to the tree it lives in.
#
# PROVENANCE IS A CONTRACT, not decoration. The consuming Tcl flows open the
# file by literal name and print it into the build console:
#   CTTE_M4_PROVENANCE.txt   <- cva6_2, rocket2, synth_rocket2_ooc, synth_cva6_2_*
#   CTTE_XLEN_PROVENANCE.txt <- rocket_linux, cva6_linux64, synth_cva6_linux64_ooc
# The default therefore follows the profile (with = M4, without = XLEN);
# --prov-name overrides it if a flow ever wants the other name.
#
# Exit: 0 = mirror ready (freshly built or cache hit), 1 = anything else.
set -uo pipefail

die () { echo "### ERROR: $*" >&2; exit 1; }

SRC="" DEST="" PROFILE="" XLEN=64 CTXW=0 STEPS=0 FORCE=0 PROVNAME=""
while [ $# -gt 0 ]; do
	case "$1" in
		--src)          SRC="$2"; shift 2;;
		--dest)         DEST="$2"; shift 2;;
		--profile)      PROFILE="$2"; shift 2;;
		--xlen)         XLEN="$2"; shift 2;;
		--ctx-width)    CTXW="$2"; shift 2;;
		--slicer-steps) STEPS="$2"; shift 2;;
		--prov-name)    PROVNAME="$2"; shift 2;;
		--force)        FORCE=1; shift;;
		-h|--help)      sed -n '5,21p' "$0"; exit 0;;
		*)              die "unknown argument $1 (try --help)";;
	esac
done

here="$(cd "$(dirname "$0")/../../../.." && pwd)"   # common/tools -> repository root
[ -n "$SRC" ] || SRC="$here"
SRC="$(cd "$SRC" 2>/dev/null && pwd)" || die "--src does not exist"
[ -n "$DEST" ] || die "--dest is required"

[ -d "$SRC/rtl" ] || die "$SRC/rtl missing"
[ -d "$SRC/rdl" ] || die "$SRC/rdl missing"
[ "$XLEN" = "32" ] || [ "$XLEN" = "64" ] || die "--xlen must be 32 or 64 (was $XLEN)"
# 44 = NEXUS_MSG_PROCESS_WIDTH; above that the composer would silently narrow,
# so ct_encoder rejects it during elaboration. Reject it here, where the caller
# still sees it, instead of hours later in a synthesis log.
[ "$CTXW" -ge 0 ] 2>/dev/null && [ "$CTXW" -le 44 ] || die "--ctx-width 0 (leave) or 1..44 (was $CTXW)"

if [ -n "$PROFILE" ]; then
	# shellcheck disable=SC1091
	. "$SRC/scripts/ct_profiles.sh" || die "cannot source $SRC/scripts/ct_profiles.sh"
	case " $(ct_profile_names) " in
		*" $PROFILE "*) ;;
		*) die "unknown profile $PROFILE (have: $(ct_profile_names))";;
	esac
fi
if [ -z "$PROVNAME" ]; then
	if [ -n "$PROFILE" ]; then PROVNAME=CTTE_M4_PROVENANCE.txt
	else                       PROVNAME=CTTE_XLEN_PROVENANCE.txt
	fi
fi

commit="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"; [ -n "$commit" ] || commit=unknown
dirty="$(git -C "$SRC" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

mkdir -p "$DEST" || die "cannot create $DEST"
DEST="$(cd "$DEST" && pwd)"
prov="$DEST/$PROVNAME"
want="src=$SRC
commit=$commit
dirty_files=$dirty
profile=$PROFILE
xlen=$XLEN
ctxwidth=$CTXW
slicersteps=$STEPS"

# A cache hit requires an EXACT match of the whole request. A mirror that
# answers to a different button state than the caller asked for is worse than
# no mirror at all -- it builds, and the wrong encoder only shows up at the
# board, where it reads as "decoder broken".
if [ -f "$prov" ] && [ "$FORCE" -eq 0 ]; then
	if [ "$(head -7 "$prov")" = "$want" ] && [ -f "$DEST/rtl/pkg/ct_pkg.sv" ]; then
		echo "### MIRROR_CACHED $DEST (commit $commit, profile=${PROFILE:-<tree>}, CT_XLEN=$XLEN, CTX=$CTXW)"
		exit 0
	fi
fi

# --- 1. copy (mirror semantics: delete first, so it is not a collecting bin) -
rm -rf "$DEST/rtl" || die "cannot clear $DEST/rtl"
cp -a "$SRC/rtl" "$DEST/rtl" || die "copying rtl/ failed"
if [ -n "$PROFILE" ]; then
	rm -rf "$DEST/rdl" || die "cannot clear $DEST/rdl"
	cp -a "$SRC/rdl" "$DEST/rdl" || die "copying rdl/ failed"
fi
pkg="$DEST/rtl/pkg/ct_pkg.sv"
[ -f "$pkg" ] || die "$pkg missing after the copy"

# --- 2. profile (the working tree's own definitions, applied to the COPY) ----
if [ -n "$PROFILE" ]; then
	ct_profile_in "$pkg" "$PROFILE" || die "ct_profile_in $PROFILE failed"
fi

# --- 3. widths (localparam, not a define) -----------------------------------
grep -qE 'localparam int unsigned CT_XLEN = [0-9]+;' "$pkg" || die "CT_XLEN not found in $pkg"
sed -i -E "s/(localparam int unsigned CT_XLEN = )[0-9]+;/\1$XLEN;/" "$pkg"
if [ "$CTXW" -gt 0 ]; then
	grep -qE 'localparam int unsigned CT_CONTEXT_WIDTH = [0-9]+;' "$pkg" || die "CT_CONTEXT_WIDTH not found"
	sed -i -E "s/(localparam int unsigned CT_CONTEXT_WIDTH = )[0-9]+;/\1$CTXW;/" "$pkg"
fi
if [ "$STEPS" -gt 0 ]; then
	grep -qE 'localparam int unsigned CT_SLICER_STEPS = [0-9]+;' "$pkg" || die "CT_SLICER_STEPS not found"
	sed -i -E "s/(localparam int unsigned CT_SLICER_STEPS = )[0-9]+;/\1$STEPS;/" "$pkg"
fi

# --- 4. CSR regblock, generated to match the profile ------------------------
if [ -n "$PROFILE" ]; then
	gen="$SRC/scripts/gen_rdl_profile.py"
	[ -f "$gen" ] || die "$gen missing"
	py "$gen" --pkg "$pkg" --rdl-dir "$DEST/rdl" --out-dir "$DEST/rtl/pkg" 2>&1 | sed 's/^/    /'
	[ "${PIPESTATUS[0]}" -eq 0 ] || die "gen_rdl_profile.py failed"
fi

# --- 5. read back, do not assume (lesson W1/R4a) ----------------------------
KEYS="CT_XLEN CT_CONTEXT_WIDTH CT_EN_FILTERS CT_EN_FILTER_SYNC CT_EN_OWNERSHIP
CT_EN_NTRACE CT_EN_ETRACE CT_EN_DATA_TRACE CT_EN_DAQ CT_EN_ACT
CT_COMPACT_PACKER CT_ETIP_CDC_SLIM CT_EN_ETIP_WATERMARK CT_EN_TIMESTAMP
CT_SINGLE_CLOCK CT_SLICER_STEPS CT_TS_WIDTH CT_ETIP_SERIALIZE CT_MICRO_CSR"

read_sw () {
	sed -nE "s/^[[:space:]]*localparam[[:space:]]+(bit|int unsigned)[[:space:]]+$1[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;.*/\2/p" "$pkg" | head -1
}

got="$(read_sw CT_XLEN)"
[ "$got" = "$XLEN" ] || die "CT_XLEN patch had no effect (tree says $got)"
if [ "$CTXW" -gt 0 ]; then
	got="$(read_sw CT_CONTEXT_WIDTH)"
	[ "$got" = "$CTXW" ] || die "CT_CONTEXT_WIDTH patch had no effect (tree says $got)"
fi
if [ "$STEPS" -gt 0 ]; then
	got="$(read_sw CT_SLICER_STEPS)"
	[ "$got" = "$STEPS" ] || die "CT_SLICER_STEPS patch had no effect (tree says $got)"
fi
# CT_XLEN=64 forbids the E-Trace backend (ct_encoder $fatal, X2b not
# implemented). Catching that here costs a second; catching it in synthesis
# costs a Vivado run, and the message there blames the wrong module.
if [ "$XLEN" = "64" ] && [ "$(read_sw CT_EN_ETRACE)" = "1" ]; then
	die "CT_XLEN=64 requires CT_EN_ETRACE=0 -- use an N-Trace profile"
fi

md5="$(md5sum "$pkg" | cut -d' ' -f1)"
printf '%s\nct_pkg_md5=%s\ncreated=%s\n' "$want" "$md5" "$(date '+%Y-%m-%d %H:%M:%S')" > "$prov"

echo "### MIRROR_OK $DEST"
echo "    commit=$commit dirty=$dirty profile=${PROFILE:-<tree>} ct_pkg.md5=$md5"
echo "    provenance=$PROVNAME"
for k in $KEYS; do printf '    %-24s = %s\n' "$k" "$(read_sw "$k")"; done
exit 0
