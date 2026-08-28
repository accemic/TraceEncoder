#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# mbv_board_gate.sh -- KV260 board gate for the examples/kv260/mbv example:
# package the routed bitstream, deploy it, load+run the trace_test program on
# the real MicroBlaze-V core, capture the on-chip CTTE ring over devmem,
# decode it, and check the decoded PC sequence against a simulation oracle.
#
# Ported from the internal driver scripts that produced the 2026-08-17
# "PREFIX_PASS 26772/26772" gate result (predecessor commit bf81683):
#   vivado/kv260_app/board_run/board_seq.sh -- the exact on-board sequence,
#     copied verbatim below (only PL_MHZ and the run-duration sleep are
#     parametrized, as __PLMHZ__/__RUNSEC__).
#   vivado/kv260_app/mbv_board_trace.ps1    -- the PowerShell driver this
#     script replaces; same word<->bin/prog.hex conversion idioms, but
#     packaging/deploy now go through this repository's already-migrated
#     examples/kv260/common/board/{package_kv260_app.py,deploy_kv260_app.sh}
#     instead of the predecessor repository's package_and_deploy.ps1.
#
# Transport is workstation -> jump host -> board: the board only accepts ssh
# from the jump host (examples/kv260/common/board/deploy_kv260_app.sh already
# follows this; see also examples/kv260/README.md for the three general KV260
# deploy traps this flow avoids: never `scp -r` onto an existing remote dir,
# never touch the 0xA000_0000 aperture unless your own app owns the slot, and
# `xmutil listapps`, not fpga_manager state, is the ground truth for that).
#
# USAGE
#   examples/kv260/mbv/board/mbv_board_gate.sh --bit <routed.bit> [options]
#
# OPTIONS (all but --bit have defaults)
#   --bit <path>            routed .bit from the mbv example's fpga/ flow
#                            (required, also when --skip-deploy is given)
#   --board <ip>             board IP           (no default; or KV260_BOARD)
#   --jump <host>             jump host / ssh alias (no default; or KV260_JUMP)
#   --user <name>             board login user                 (ubuntu)
#   --sudo-pass <pw>          board sudo password, or $KV260_SUDO_PASS
#   --runsec <sec>            core run duration before capture (0.05 --
#                            0.3 s wraps the 1 MiB trace ring; a wrap fails
#                            the gate, see the WRAP check below)
#   --pl-mhz <mhz>            PL clock label, one of 68|75|100 (kv260_plclk.sh
#                            on the board decides; anything else aborts
#                            there with a clear message)         (75)
#   --oracle <retired.pcs>    simulation reference PC list (default:
#                            sw/build/trace_test.retired.pcs if present in
#                            this tree; otherwise this option is required --
#                            see README.md for where to get one today)
#   --work <dir>              working/output directory (default:
#                            examples/kv260/mbv/board/run/, gitignored)
#   --skip-deploy              reuse an already-deployed app: skip
#                            package_kv260_app.py and deploy_kv260_app.sh,
#                            go straight to the board load-run-capture
#                            sequence
#
# EXIT CODES: 0 pass -- 1 fail (board sequence / wrap / decode / PC verdict)
# -- 2 bad arguments -- whatever package_kv260_app.py / deploy_kv260_app.sh /
# ct_env.sh return on their own tool failures (3, 78, ...).
set -euo pipefail

# ---------------------------------------------------------------- paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MBV_DIR="$TE_ROOT/examples/kv260/mbv"
SW_DIR="$MBV_DIR/sw"
BUILD_DIR="$SW_DIR/build"
COMMON_BOARD="$TE_ROOT/examples/kv260/common/board"
PROG="trace_test"
APP="mbv_ctrace_kv260"

# `py` on Windows, `python3` elsewhere -- one idiom for every script in this
# repository, so a missing `py` on a Linux host falls back the same way everywhere.
PY="${PY:-py}"; command -v py >/dev/null 2>&1 || PY=python3

# --------------------------------------------------------------- args ------
BIT=""
BOARD="${KV260_BOARD:-}"
JUMP="${KV260_JUMP:-}"
USER_="ubuntu"
SUDO_PASS="${KV260_SUDO_PASS:-}"
RUNSEC="0.05"
PL_MHZ="75"
ORACLE=""
WORK="$SCRIPT_DIR/run"
SKIP_DEPLOY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--bit) BIT="$2"; shift 2;;
		--board) BOARD="$2"; shift 2;;
		--jump) JUMP="$2"; shift 2;;
		--user) USER_="$2"; shift 2;;
		--sudo-pass) SUDO_PASS="$2"; shift 2;;
		--runsec) RUNSEC="$2"; shift 2;;
		--pl-mhz) PL_MHZ="$2"; shift 2;;
		--oracle) ORACLE="$2"; shift 2;;
		--work) WORK="$2"; shift 2;;
		--skip-deploy) SKIP_DEPLOY=1; shift;;
		*) echo "mbv_board_gate: unknown argument $1" >&2; exit 2;;
	esac
done
[ -n "$BIT" ] || { echo "mbv_board_gate: --bit <routed.bit> required" >&2; exit 2; }

# Default oracle: the committed sim reference, if this tree has one yet (it
# does not as of the initial R1a port -- examples/kv260/mbv/sw/build/ only
# vendors toolchain outputs so far, see README.md).
if [ -z "$ORACLE" ]; then
	# refs/ first: sw/build/ is a THROW-AWAY directory (gitignored, `make clean`
	# wipes it), and the simulation reference is not a build output -- it is the
	# yardstick this gate is judged by. It lived only in the predecessor repository's archive
	# until 2026-08-18, so a fresh clone could not pass this gate at all.
	DEFAULT_ORACLE="$SCRIPT_DIR/refs/$PROG.retired.pcs"
	[ -f "$DEFAULT_ORACLE" ] || DEFAULT_ORACLE="$BUILD_DIR/$PROG.retired.pcs"
	if [ -f "$DEFAULT_ORACLE" ]; then
		ORACLE="$DEFAULT_ORACLE"
	else
		echo "mbv_board_gate: --oracle <retired.pcs> required ($DEFAULT_ORACLE not found)" >&2
		exit 2
	fi
fi
[ -f "$ORACLE" ] || { echo "mbv_board_gate: --oracle file not found: $ORACLE" >&2; exit 2; }

mkdir -p "$WORK"

# --------------------------------------------------------- decoder (cttd) --
# ct_env.sh resolves $NEXRV to the right cttd-* binary for this host (incl.
# the KV260's own aarch64 leg) and ct_need_nexrv proves it actually runs and
# knows the switches this script uses -- a missing/broken decoder must never
# read as a broken encoder (scripts/ct_env.sh header).
# shellcheck source=/dev/null
. "$TE_ROOT/scripts/ct_env.sh"
ct_need_nexrv

# ------------------------------------------------- 1. build the program ----
# Only the .bin (objcopy) and .dump (objdump) targets are needed here, and
# neither depends on the three oracle-generation Python helpers that are not
# yet vendored into this repository (examples/kv260/mbv/sw/README.md, "Known
# gap") -- `elf`/`dump`/`size`/`.bin` all build standalone.
PROG_BIN="$BUILD_DIR/$PROG.bin"
PROG_DUMP="$BUILD_DIR/$PROG.dump"
echo "### BUILD $PROG (sw/)"
( cd "$SW_DIR" && make "build/$PROG.bin" "build/$PROG.dump" )
[ -f "$PROG_BIN" ] || { echo "mbv_board_gate: $PROG_BIN missing after make" >&2; exit 1; }

# prog.hex: little-endian 32-bit words, one 8-hex-digit line each, NO "0x"
# prefix, LF-only -- board_seq.sh below reads it with `0x$w` and dies on a
# stray \r (the predecessor's mbv_board_trace.ps1 lesson L2).
"$PY" -c "
import sys
d = open(sys.argv[1], 'rb').read()
d += b'\x00' * ((-len(d)) % 4)
open(sys.argv[2], 'w', newline='\n').write(
    ''.join('%08x\n' % int.from_bytes(d[i:i+4], 'little') for i in range(0, len(d), 4)))
" "$PROG_BIN" "$WORK/prog.hex"

# pcinfo: prefer a committed one, else generate it from the .dump the same
# way duo_board_trace.ps1 does (the predecessor repository, line ~41: `-conv -objd <dump>
# -pcinfo <out>`).
DEFAULT_PCINFO="$BUILD_DIR/$PROG.pcinfo"
if [ -f "$DEFAULT_PCINFO" ]; then
	PCINFO="$DEFAULT_PCINFO"
else
	PCINFO="$WORK/prog.pcinfo"
	"$NEXRV" -conv -objd "$PROG_DUMP" -pcinfo "$PCINFO" > "$WORK/conv.log" 2>&1 \
		|| { echo "mbv_board_gate: pcinfo generation failed (see $WORK/conv.log)" >&2; exit 1; }
fi
[ -f "$PCINFO" ] || { echo "mbv_board_gate: pcinfo missing: $PCINFO" >&2; exit 1; }

# ------------------------------------------- 2+3. package + deploy the app -
if [ "$SKIP_DEPLOY" -eq 0 ]; then
	echo "### PACKAGE $APP <- $BIT"
	"$PY" "$COMMON_BOARD/package_kv260_app.py" --bit "$BIT" --app "$APP" --out "$WORK/pkg"
	echo "### DEPLOY $APP -> $USER_@$BOARD via $JUMP"
	bash "$COMMON_BOARD/deploy_kv260_app.sh" \
		--app-dir "$WORK/pkg/$APP" --board "$BOARD" --jump "$JUMP" \
		--user "$USER_" --sudo-pass "$SUDO_PASS"
else
	echo "### SKIP_DEPLOY -- reusing whatever app is already loaded on $BOARD"
fi

# ------------------------------------------- 4. on-board load+run sequence -
# Byte-for-byte board_run/board_seq.sh from the predecessor repository at bf81683 (the sequence
# that produced PREFIX_PASS 26772/26772), with PL_MHZ and the run-duration
# sleep as the only parametrized tokens. The quoted heredoc delimiter keeps
# every `$(( ... ))`/`$w` literal here -- they run on the BOARD, not here.
cat > "$WORK/board_seq.sh" <<'BOARD_SEQ_EOF'
set -e
dm() { busybox devmem "$@"; }
xmutil unloadapp >/dev/null 2>&1 || true
# pl_clk0 must be set BEFORE the design sits in the slot -- the PS controls
# the PL clock via PL0_REF_CTRL (CRL_APB); an xmutil overlay with only
# `firmware-name` does not touch it, so a freshly loaded design inherits
# whatever the boot firmware left behind (measured: 100 MHz, while every
# design in this tree is constrained for a lower rate). Order is mandatory:
# unloadapp, then clock, then loadapp -- a frequency jump under a running
# design is a clock glitch mid-logic.
PL_MHZ=__PLMHZ__
if [ ! -f /tmp/kv260_plclk.sh ]; then
  echo "PLCLK_SCRIPT_MISSING /tmp/kv260_plclk.sh" >&2
  exit 9
fi
MHZ="$PL_MHZ" sh /tmp/kv260_plclk.sh >&2 || { echo "PLCLK_FAILED" >&2; exit 9; }
# Which bitstream is about to load? App names are reused across rebuilds, so
# this hash is the only way to tie a board run back to a specific build.
BITBIN=/lib/firmware/xilinx/__APP__/__APP__.bit.bin
if [ -f "$BITBIN" ]; then
  echo "BITBIN_MD5 $(md5sum "$BITBIN" | awk '{print $1}')" >&2
else
  echo "BITBIN_MISSING $BITBIN" >&2
fi
xmutil loadapp __APP__ >/dev/null
sleep 2
# Read-only clock check AFTER loading: the clock must have survived the app
# switch (a board reboot restores the 100 MHz vendor default, so a proof from
# an earlier run never carries over).
sh /tmp/kv260_plclk.sh >&2 || true
dm 0xA0000000 32 0x2
dm 0xA0000000 32 0x0
i=0
while read -r w; do
  w=${w%$'\r'}
  a=$(printf '0x%08x' $(( 0xA0100000 + i*4 )))
  dm $a 32 0x$w
  i=$((i+1))
done < /tmp/prog.hex
echo "LOADED $i" >&2
dm 0xA0010000 32 0x01068067
dm 0xA0000000 32 0x1
sleep __RUNSEC__
dm 0xA0010000 32 0x01068063
dm 0xA0000000 32 0x5
sleep 0.1
dm 0xA0000000 32 0x1
nbytes=$(dm 0xA000000C)
echo "NBYTES $nbytes" >&2
echo "STATUS $(dm 0xA0000004)" >&2
nwords=$(( ( $((nbytes)) + 3 ) / 4 ))
for ((i=0;i<nwords;i++)); do a=$(printf '0x%08x' $(( 0xA0200000 + i*4 ))); dm $a; done
BOARD_SEQ_EOF
sed -i "s/__PLMHZ__/$PL_MHZ/g; s/__RUNSEC__/$RUNSEC/g; s/__APP__/$APP/g" "$WORK/board_seq.sh"

# Transport: workstation -> jump host /tmp -> board /tmp (the board only
# accepts ssh from the jump host). Two hops, exactly the predecessor repository
# mbv_board_trace.ps1 shape, ported to bare ssh/scp (already on PATH in
# Git-Bash, no GitUsr override needed -- see deploy_kv260_app.sh).
echo "### RUN $PROG on $BOARD (runsec=$RUNSEC pl-mhz=$PL_MHZ)"
scp -q "$WORK/prog.hex" "$WORK/board_seq.sh" "$COMMON_BOARD/kv260_plclk.sh" "$JUMP:/tmp/"

set +e
OUT="$(ssh "$JUMP" "scp -q /tmp/prog.hex /tmp/board_seq.sh /tmp/kv260_plclk.sh $USER_@$BOARD:/tmp/ && ssh $USER_@$BOARD 'echo $SUDO_PASS | sudo -S bash /tmp/board_seq.sh'" 2> "$WORK/board.err")"
BOARD_RC=$?
set -e
printf '%s\n' "$OUT" > "$WORK/trace.words"

grep -E "LOADED|NBYTES|STATUS|FAILED|MISSING|No such" "$WORK/board.err" | sed 's/^/  [board] /' || true

nbytes_line="$(sed -n 's/^NBYTES \(0x[0-9A-Fa-f]\+\|[0-9]\+\).*/\1/p' "$WORK/board.err" | tail -1)"
status_line="$(sed -n 's/^STATUS \(0x[0-9A-Fa-f]\+\|[0-9]\+\).*/\1/p' "$WORK/board.err" | tail -1)"
bitbin_md5="$(sed -n 's/^BITBIN_MD5 \([0-9a-fA-F]\{32\}\).*/\1/p' "$WORK/board.err" | tail -1)"

if [ -z "$nbytes_line" ] || [ -z "$status_line" ]; then
	echo "### BOARD_SEQ_FAILED (rc=$BOARD_RC; no NBYTES/STATUS in $WORK/board.err)"
	tail -20 "$WORK/board.err" | sed 's/^/  /'
	exit 1
fi
nbytes=$(( nbytes_line ))
status=$(( status_line ))
wrap=$(( status & 0x1 ))

# ------------------------------------- evidence lines (always, pass or fail)
if grep -q "CLK_SET_OK" "$WORK/board.err"; then
	echo "### PLCLK ${PL_MHZ}"
else
	echo "### PLCLK UNVERIFIED (no CLK_SET_OK in $WORK/board.err)"
fi
echo "### BITBIN_MD5 ${bitbin_md5:-UNKNOWN}"
echo "### NBYTES $nbytes"
echo "### WRAP $wrap"

# A wrapped ring overwrote its own oldest bytes mid-capture -- the anchor
# class of capture failure this gate cannot decode around (mbv README/CTRL
# register doc: STATUS bit0 = trace_wrapped). Fail fast, before spending time
# decoding data that is known-incomplete at its start.
if [ "$wrap" -ne 0 ]; then
	echo "### MBV_BOARD_GATE FAIL (ring wrapped -- STATUS bit0 set; lower --runsec or verify ring capacity)"
	exit 1
fi

# ---------------------------------------------- 5. words -> bin, 6. decode -
"$PY" -c "
import sys
words = [int(x, 16) for x in open(sys.argv[1]) if x.strip().startswith('0x')]
nb = int(sys.argv[3], 0)
open(sys.argv[2], 'wb').write(b''.join(w.to_bytes(4, 'little') for w in words)[:nb])
" "$WORK/trace.words" "$WORK/trace.bin" "$nbytes"

"$NEXRV" -deco "$WORK/trace.bin" -pcinfo "$PCINFO" -pcout "$WORK/trace.pcout" -bp -full \
	> "$WORK/deco.log" 2>&1 || true
if ! grep -q "Decoded OK" "$WORK/deco.log"; then
	echo "### DECODE_FAILED (see $WORK/deco.log)"
	tail -10 "$WORK/deco.log" | sed 's/^/  /'
	exit 1
fi
grep -E "Decoded OK|Stat:" "$WORK/deco.log" | sed 's/^/  [decode] /'

# ------------------------------------------------------- 7. verdict --------
set +e
"$PY" "$TE_ROOT/scripts/check_pcout_vs_retired.py" "$WORK/trace.pcout" "$ORACLE" \
	--label mbv --ref-prefix-ok > "$WORK/verdict.log" 2>&1
CHECK_RC=$?
set -e
cat "$WORK/verdict.log"

if [ "$CHECK_RC" -eq 0 ]; then
	# <n>/<n> = the oracle length (the always-printed "reference : N PCs"
	# line), i.e. "all N reference PCs matched" -- reproduces the historical
	# "PREFIX_PASS 26772/26772" figure for this oracle. (Reasoning:
	# check_pcout_vs_retired.py's own PASS message does not print counts in
	# n/n shape in the --ref-prefix-ok fast path.)
	n_ref="$(sed -n 's/.*reference[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' "$WORK/verdict.log" | head -1)"
	echo "### MBV_BOARD_GATE PASS ${n_ref}/${n_ref}"
	exit 0
else
	echo "### MBV_BOARD_GATE FAIL"
	exit 1
fi
