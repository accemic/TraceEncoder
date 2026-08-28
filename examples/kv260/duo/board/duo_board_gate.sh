#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# duo_board_gate.sh -- package, deploy and run the duo (MicroBlaze-V +
# MINRES TGC5B) KV260 example on real hardware, then decode and verdict
# both cores' trace. Bash port of the predecessor repository's `duo_board_trace.ps1`
# (Phase 4b: dual-core trace + NexRv multi-target decode), folded together
# with this repository's own `package_kv260_app.py` + `deploy_kv260_app.sh`
# so a single invocation goes from a routed .bit to a PASS/FAIL verdict.
#
#   duo_board_gate.sh --bit <routed.bit> [options]
#   duo_board_gate.sh --skip-package --app-dir <dir> [options]
#
# Required (unless --skip-package):
#   --bit <path>            routed .bit from examples/kv260/duo/fpga
#
# Options:
#   --app <name>             board-app name (default duo_ctrace_kv260)
#   --prog <name>             MBV program under ../../mbv/sw/build/ (default trace_test)
#   --runsec <sec>            capture window (default 0.02 -- 0.05 wraps the
#                              1-MiB ring, see the anchor-class gate below)
#   --pl-mhz <68|75|100>      PL clock label kv260_plclk.sh understands (default 75)
#   --board <ip>              board IP (no default; or KV260_BOARD)
#   --jump <host>             jump host, ssh-config alias ok (no default; or KV260_JUMP)
#   --user <name>             board user (default ubuntu)
#   --sudo-pass <pw>          board sudo password (default: $KV260_SUDO_PASS)
#   --vivado-bin <dir>        forwarded to package_kv260_app.py (bootgen location)
#   --skip-package            reuse an already-packaged app dir (needs --app-dir)
#   --app-dir <dir>           packaged app dir (package_kv260_app.py's --out/<app>);
#                              required with --skip-package, else computed from
#                              the packaging step's own "app-dir <path>" line
#   --oracle0 <retired.pcs>   MBV reference PC sequence for the prefix check
#                              (a sim run's retired-PCs capture; none exists in
#                              this migrated tree yet -- default: skip, loudly)
#   --oracle1 <retired.pcs>   TGC5B reference PC sequence, same as --oracle0
#   --irq-vector <addr>       core1 IRQ-aware verdict: a divergence from the sim
#                             reference is accepted ONLY if it jumps into this trap
#                             vector after >= --irq-min-prefix (800) identical PCs
#                             (hello_trace: 0x6c <trap_handler>); otherwise FAIL
#   --closure-verify <cmd>    optional hook run after capture with the board
#                              log path as its one argument (extension point
#                              for a future port of kv260_closure_verify.ps1's
#                              timing-closure database -- NOT reimplemented
#                              here, see README.md); best-effort, a nonzero
#                              exit prints a warning but does not fail the gate
#   --out <dir>               work dir for generated artifacts
#                              (default: ./board_run_<app> next to this script)
#   -h|--help
#
# WHY THE SECOND unloadapp/plclk/loadapp CYCLE (after deploy_kv260_app.sh
# already did its own load): deploy_kv260_app.sh's load happens at whatever
# PL clock was already active (typically the 100 MHz vendor boot default, or
# whatever a previous app left behind) -- an xmutil runtime overlay only sets
# `firmware-name`, it does not touch PL0_REF_CTRL (CRL_APB). Only a design
# that is put into the slot AFTER the clock is set actually runs at that
# clock; a frequency change under a running design is a clock glitch, not a
# reconfiguration (R5a finding, kv260_plclk.sh header). So every capture run
# repeats unloadapp -> plclk -> loadapp itself, on top of whatever deploy did.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
COMMON_BOARD="$REPO/examples/kv260/common/board"
MBV_SW="$REPO/examples/kv260/mbv/sw"
TGC_PROG="$REPO/examples/kv260/common/tgc5b/prog"

# shellcheck source=/dev/null
. "$REPO/scripts/ct_env.sh"

PY="${PY:-py}"
command -v py >/dev/null 2>&1 || PY=python3

BIT="" APP="duo_ctrace_kv260" PROG="trace_test" RUNSEC="0.02" PLMHZ="75"
BOARD="${KV260_BOARD:-}" JUMP="${KV260_JUMP:-}" USER_="ubuntu"
SUDO_PASS="${KV260_SUDO_PASS:-}"
VIVADO_BIN="" SKIP_PACKAGE=0 APPDIR="" ORACLE0="" ORACLE1=""
CLOSURE_VERIFY="" OUT=""

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bit) BIT="$2"; shift 2;;
        --app) APP="$2"; shift 2;;
        --prog) PROG="$2"; shift 2;;
        --runsec) RUNSEC="$2"; shift 2;;
        # --plmhz (no second hyphen) was this gate's original spelling and
        # stays accepted so older invocations and logs keep working; the
        # documented spelling is --pl-mhz, as in the mbv and wp gates.
        --pl-mhz|--plmhz) PLMHZ="$2"; shift 2;;
        --board) BOARD="$2"; shift 2;;
        --jump) JUMP="$2"; shift 2;;
        --user) USER_="$2"; shift 2;;
        --sudo-pass) SUDO_PASS="$2"; shift 2;;
        --vivado-bin) VIVADO_BIN="$2"; shift 2;;
        --skip-package) SKIP_PACKAGE=1; shift;;
        --app-dir) APPDIR="$2"; shift 2;;
        --oracle0) ORACLE0="$2"; shift 2;;
        --oracle1) ORACLE1="$2"; shift 2;;
        --irq-vector) IRQ_VECTOR="$2"; shift 2;;
        --irq-min-prefix) IRQ_MIN_PREFIX="$2"; shift 2;;
        --closure-verify) CLOSURE_VERIFY="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "duo_board_gate: unknown argument $1" >&2; exit 2;;
    esac
done
if [ "$SKIP_PACKAGE" -eq 1 ]; then
    [ -n "$APPDIR" ] || { echo "duo_board_gate: --skip-package needs --app-dir <dir>" >&2; exit 2; }
else
    [ -n "$BIT" ] || { echo "duo_board_gate: --bit <path> required (or --skip-package --app-dir <dir>)" >&2; exit 2; }
fi

WORK="${OUT:-$HERE/board_run_$APP}"
mkdir -p "$WORK"

# A path a Windows `py` printed (backslashes, drive letter) confuses bash's
# `[ -d ... ]`/scp on some MSYS setups -- normalise the same way ct_env.sh
# does for the python interpreter path it resolves.
norm_path() {
    case "$1" in
        *\\*|[A-Za-z]:*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -u "$1"
                return
            fi
            ;;
    esac
    printf '%s\n' "$1"
}

# --- 1. Package -------------------------------------------------------------
if [ "$SKIP_PACKAGE" -eq 0 ]; then
    [ -f "$BIT" ] || { echo "### ERROR: --bit not found: $BIT"; exit 1; }
    echo "### PACKAGE $APP <- $BIT"
    pkg_args=("$COMMON_BOARD/package_kv260_app.py" --bit "$BIT" --app "$APP")
    if [ -n "$VIVADO_BIN" ]; then pkg_args+=(--vivado-bin "$VIVADO_BIN"); fi
    "$PY" "${pkg_args[@]}" | tee "$WORK/package.log"
    line="$(grep -E '^app-dir ' "$WORK/package.log" | tail -1 || true)"
    [ -n "$line" ] || { echo "### PACKAGE_FAILED (no 'app-dir' line, see $WORK/package.log)"; exit 1; }
    APPDIR="$(norm_path "${line#app-dir }")"
fi
[ -d "$APPDIR" ] || { echo "### ERROR: app dir not found: $APPDIR"; exit 1; }

# --- 2. Deploy ---------------------------------------------------------------
echo "### DEPLOY $APP -> $USER_@$BOARD via $JUMP"
"$COMMON_BOARD/deploy_kv260_app.sh" --app-dir "$APPDIR" --board "$BOARD" \
    --jump "$JUMP" --user "$USER_" --sudo-pass "$SUDO_PASS"

# --- 3. Local artifacts: images (LF-only) + pcinfos (our pinned -conv) ------
ct_need_nexrv
BUILD="$MBV_SW/build"
BIN="$BUILD/$PROG.bin"
DUMP="$BUILD/$PROG.dump"
if [ ! -f "$BIN" ] || [ ! -f "$DUMP" ]; then
    echo "### BUILD $PROG.bin/.dump (make -C $MBV_SW)"
    ( cd "$MBV_SW" && make "build/$PROG.bin" "build/$PROG.dump" ) \
        || { echo "### ERROR: could not build $PROG.bin/.dump in $MBV_SW (toolchain missing?)"; exit 1; }
fi
[ -f "$BIN" ] || { echo "### ERROR: $BIN missing after build"; exit 1; }

# raw MBV binary -> big-endian-free 32-bit little-endian hex word list (one
# word per line, zero-padded to a 4-byte multiple), for the devmem loader loop.
"$PY" -c "
import sys
d = open(sys.argv[1], 'rb').read()
d += b'\x00' * ((-len(d)) % 4)
open(sys.argv[2], 'w', newline='\n').write(
    ''.join('%08x\n' % int.from_bytes(d[i:i+4], 'little') for i in range(0, len(d), 4)))
" "$BIN" "$WORK/prog.hex"

# TGC5B hello_trace.hex is already a readmemh word list -- just enforce LF.
"$PY" -c "
import sys
open(sys.argv[2], 'w', newline='\n').write(
    '\n'.join(l.strip() for l in open(sys.argv[1]) if l.strip()))
" "$TGC_PROG/hello_trace.hex" "$WORK/prog2.hex"

"$NEXRV" -conv -objd "$DUMP" -pcinfo "$WORK/mbv.pcinfo" > "$WORK/conv0.log" 2>&1 || true
"$NEXRV" -conv -objd "$TGC_PROG/hello_trace.dis" -pcinfo "$WORK/tgc.pcinfo" > "$WORK/conv1.log" 2>&1 || true
[ -f "$WORK/mbv.pcinfo" ] && [ -f "$WORK/tgc.pcinfo" ] || { echo "### CONV_FAILED (see $WORK/conv0.log, $WORK/conv1.log)"; exit 1; }

# --- 4. Board sequence -------------------------------------------------------
# Address windows: CTRL 0xA0000000 | ENC0 0xA0010000 | ENC1 0xA0020000 |
# RAM1 0xA0080000 | RAM0 0xA0100000 | TRACE 0xA0200000 (duo_soc_top.sv
# @details -- unchanged since the PowerShell original; the RTL's newer additive
# DDR4/PIB/funnel sink registers at 0x18+ stay at their inert reset
# defaults, this sequence never touches them). Per-instance encoder arming:
# FEAT (trTeInstFeatures, ENC+0x08) RMW SrcBits=2[31:30]/SrcID[27:16], then
# trTeControl (ENC+0x00) 0x01060067 (InhibitSrc=0, enable).
cat > "$WORK/board_seq.sh" <<'BOARD_EOF'
set -e
dm() { busybox devmem "$@"; }
xmutil unloadapp >/dev/null 2>&1 || true
PL_MHZ=@@PLMHZ@@
if [ ! -f /tmp/kv260_plclk.sh ]; then
  echo "PLCLK_SCRIPT_MISSING /tmp/kv260_plclk.sh" >&2
  exit 9
fi
MHZ="$PL_MHZ" sh /tmp/kv260_plclk.sh >&2 || { echo "PLCLK_FAILED" >&2; exit 9; }
BITBIN=/lib/firmware/xilinx/@@APP@@/@@APP@@.bit.bin
if [ -f "$BITBIN" ]; then
  echo "BITBIN_MD5 $(md5sum "$BITBIN" | awk '{print $1}')" >&2
else
  echo "BITBIN_MISSING $BITBIN" >&2
fi
xmutil loadapp @@APP@@ >/dev/null
sleep 2
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
echo "LOADED0 $i" >&2
i=0
while read -r w; do
  w=${w%$'\r'}
  a=$(printf '0x%08x' $(( 0xA0080000 + i*4 )))
  dm $a 32 0x$w
  i=$((i+1))
done < /tmp/prog2.hex
echo "LOADED1 $i" >&2
f0=$(dm 0xA0010008)
f0=$(( (f0 & 0x0000FFFF) | 0x20000000 ))
dm 0xA0010008 32 $(printf '0x%08x' $f0)
f1=$(dm 0xA0020008)
f1=$(( (f1 & 0x0000FFFF) | 0x20010000 ))
dm 0xA0020008 32 $(printf '0x%08x' $f1)
echo "FEAT0 $(dm 0xA0010008) FEAT1 $(dm 0xA0020008)" >&2
dm 0xA0010000 32 0x01060067
dm 0xA0020000 32 0x01060067
dm 0xA0000000 32 0x1
sleep @@RUNSEC@@
dm 0xA0010000 32 0x01060063
dm 0xA0020000 32 0x01060063
dm 0xA0000000 32 0x5
sleep 0.1
dm 0xA0000000 32 0x1
nbytes=$(dm 0xA000000C)
echo "NBYTES $nbytes" >&2
echo "STATUS $(dm 0xA0000004)" >&2
nwords=$(( ( $((nbytes)) + 3 ) / 4 ))
# Read the ring. Until 2026-08-21 a word loop with `busybox devmem` stood
# here -- one process start per 32-bit word, i.e. 262,144 process starts for
# a full 1 MiB ring. Measured on this board: after 20 minutes 90 % had been
# read, and a trio run died in its timeout because of it. phys_io.py reads
# the same range through a single mapping; the content is identical, only
# the path differs. If the tool is missing the word loop remains as the
# fallback -- a silent failure would be worse than a slow run.
if [ -f /tmp/phys_io.py ] && python3 /tmp/phys_io.py read 0xA0200000 $(( nwords * 4 )) -o /tmp/ct_ring.bin >/dev/null 2>&1; then
    echo "RINGREAD phys_io $(( nwords * 4 )) bytes" >&2
    echo "---RINGB64---"
    base64 /tmp/ct_ring.bin
    echo "---ENDRINGB64---"
else
    echo "RINGREAD wordloop (phys_io.py unavailable) $nwords words" >&2
    for ((i=0;i<nwords;i++)); do a=$(printf '0x%08x' $(( 0xA0200000 + i*4 ))); dm $a; done
fi
BOARD_EOF
sed -i -e "s/@@APP@@/$APP/g" -e "s/@@RUNSEC@@/$RUNSEC/g" -e "s/@@PLMHZ@@/$PLMHZ/g" "$WORK/board_seq.sh"
sed -i 's/\r$//' "$WORK/board_seq.sh"

# --- 5. Upload + run (workstation -> jump host -> board) --------------------
scp -q "$WORK/prog.hex" "$WORK/prog2.hex" "$WORK/board_seq.sh" "$COMMON_BOARD/kv260_plclk.sh" "$COMMON_BOARD/phys_io.py" "$JUMP:/tmp/"
ssh "$JUMP" \
    "scp -q /tmp/prog.hex /tmp/prog2.hex /tmp/board_seq.sh /tmp/kv260_plclk.sh /tmp/phys_io.py $USER_@${BOARD}:/tmp/ && \
     ssh $USER_@$BOARD 'echo $SUDO_PASS | sudo -S bash /tmp/board_seq.sh'" \
    > "$WORK/trace.words" 2> "$WORK/board.err" || true
grep -aE 'LOADED|FEAT|NBYTES|STATUS|BITBIN|PLCLK|PL0_REF|CLK_SET|RINGREAD|FAILED|No such' "$WORK/board.err" \
    | while IFS= read -r l; do echo "  [board] $l"; done || true

# --- 6. Optional closure-verify hook (extension point, not reimplemented) ---
if [ -n "$CLOSURE_VERIFY" ]; then
    echo "### CLOSURE_HOOK: $CLOSURE_VERIFY $WORK/board.err"
    if out="$("$CLOSURE_VERIFY" "$WORK/board.err" 2>&1)"; then
        printf '%s\n' "$out" | while IFS= read -r l; do echo "  [closure] $l"; done || true
    else
        rc=$?
        printf '%s\n' "$out" | while IFS= read -r l; do echo "  [closure] $l"; done || true
        echo "### CLOSURE_HOOK_WARN (rc=$rc) -- hook failed, gate continues (not a re-implementation of kv260_closure_verify.ps1)"
    fi
fi

# --- 7. Anchor-class gate: a wrapped ring is not a valid contiguous trace --
# RunSec 0.02 is the default precisely because 0.05 wraps the 1-MiB ring; a
# wrapped ring re-syncs mid-stream WITHOUT an enable event, which the
# decoder cannot anchor -- every board decode failure traced back to this
# class (memory: ctte-mbv-decode-validity-gate). Caught here, before
# decode, so the failure reads as what it is instead of a mysterious decode
# error.
nb_line="$(grep -aE '^NBYTES ' "$WORK/board.err" | tail -1 || true)"
st_line="$(grep -aE '^STATUS ' "$WORK/board.err" | tail -1 || true)"
[ -n "$nb_line" ] || { echo "### BOARD_SEQ_FAILED (no NBYTES; see $WORK/board.err)"; exit 1; }
nb="${nb_line#NBYTES }"; nb="${nb%%$'\r'}"
st="${st_line#STATUS }"; st="${st%%$'\r'}"
nb_int=$((nb)); st_int=$((st))
echo "### CAPTURE: NBYTES=$nb STATUS=$st"
if [ "$nb_int" -gt $((0x100000)) ] || [ $((st_int & 0x1)) -ne 0 ]; then
    echo "### DUO_BOARD FAIL (anchor-class: NBYTES=$nb $([ "$nb_int" -gt $((0x100000)) ] && echo '>1MiB ')STATUS.trace_wrapped=$((st_int & 0x1)) -- ring wrapped, capture is not a contiguous trace; lower --runsec)"
    exit 1
fi

# --- 8. Words -> bin, multi-target decode -----------------------------------
"$PY" -c "
import base64, sys
raw = open(sys.argv[1], 'rb').read()
nb = int(sys.argv[3], 0)
lo = raw.find(b'---RINGB64---')
if lo >= 0:
    hi = raw.find(b'---ENDRINGB64---', lo)
    body = raw[lo + len(b'---RINGB64---'):hi if hi >= 0 else len(raw)]
    data = base64.b64decode(b''.join(body.split()))
else:
    words = [int(x, 16) for x in raw.decode('ascii', 'replace').splitlines() if x.strip().startswith('0x')]
    data = b''.join(w.to_bytes(4, 'little') for w in words)
open(sys.argv[2], 'wb').write(data[:nb])
" "$WORK/trace.words" "$WORK/trace.bin" "$nb"
echo "### CAPTURE: $nb bytes (merged)"

"$NEXRV" -deco "$WORK/trace.bin" \
    -target 0 -pcinfo "$WORK/mbv.pcinfo" -pcout "$WORK/duo.core0.pcout" \
    -target 1 -pcinfo "$WORK/tgc.pcinfo" -pcout "$WORK/duo.core1.pcout" \
    -src 2 -stat > "$WORK/deco.log" 2>&1 || true
grep -aE 'Decoded OK|target|WARNING|ERROR' "$WORK/deco.log" | tail -6 || true
grep -aq 'Decoded OK' "$WORK/deco.log" || { echo "### DECODE_FAILED (see $WORK/deco.log)"; exit 1; }

# --- 9. Prefix check per core against a reference PC sequence -------------
# Defaults since 2026-08-19: refs/ next to this script. core 0 gets a real
# SIMULATION ORACLE (the same trace_test reference the mbv example uses --
# core 0 runs that image); core 1 gets a RECORDED reference, because no TGC5B
# simulation reference exists here and inventing one would be worse than
# having none. The two are different kinds of evidence and refs/README.md
# says so; quoting both as "verified against a reference" overclaims.
fail=0
for c in 0 1; do
    if [ "$c" -eq 0 ]; then oracle="$ORACLE0"; else oracle="$ORACLE1"; fi
    if [ -z "$oracle" ]; then
        if [ "$c" -eq 0 ]; then
            oracle="$HERE/refs/core0_trace_test.retired.pcs"
        else
            # 2026-08-21 recording, NOT the 2026-08-19 one. The older file
            # no longer reproduces: four board runs that day -- duo at 75 MHz,
            # duo at 68, trio at 68, all with core 0 PASSing against its real
            # oracle -- diverge from it at the same index 855 with the same
            # PCs, while being IDENTICAL to each other over 720 238 PCs. Its
            # own context shows 0x20 three times after 0x1ec, i.e. a core
            # standing still. A gate that fails with its own defaults is
            # worse than no gate, so the default follows what three
            # independent runs agree on.
            #
            # The reservation belongs next to this, not instead of it:
            # REPRODUCIBLE IS NOT CORRECT. Nobody has held either sequence
            # against what hello_trace is SUPPOSED to do. Core 1 therefore
            # stays a reproduction result, never an oracle result -- the
            # distinction refs/README.md insists on. The 2026-08-19 file is
            # kept beside this one as the only evidence of what the board did
            # that day; pass it with --oracle1 to compare.
            oracle="$HERE/refs/core1_hello_trace.recorded_20260821.pcs"
        fi
        [ -f "$oracle" ] || {
            echo "### CORE${c}: SKIP -- no --oracle$c given and no default in refs/"
            continue
        }
        echo "### CORE${c}: using default reference $(basename "$oracle")"
    fi
    [ -f "$oracle" ] || { echo "### CORE${c}: SKIP -- oracle not found: $oracle"; continue; }
    rc=0
    "$PY" "$REPO/scripts/check_pcout_vs_retired.py" "$WORK/duo.core$c.pcout" "$oracle" \
        --label "core$c" --ref-prefix-ok > "$WORK/check$c.log" 2>&1 || rc=$?
    line="$(grep -aE 'PASS|FAIL' "$WORK/check$c.log" | head -1 || true)"
    echo "### CORE${c}: $line (rc=$rc)"
    if [ "$rc" -ne 0 ]; then
        # IRQ-aware verdict for the TGC5B core (hello_trace is timer-IRQ
        # driven): the simulation reference is physically no oracle beyond
        # the first interrupt entry -- interrupt timing on the board (real
        # time @ 75 MHz) is not the simulation's. What CAN be demanded and
        # is demanded here: the decoded stream is reference-identical for at
        # least --irq-min-prefix instructions AND the first divergence is a
        # jump INTO the trap vector (--irq-vector, hello_trace: 0x6c
        # <trap_handler>). Any other divergence stays a FAIL. Measured on
        # 2026-08-17/18: 855/855 then 0x1e8 -> 0x6c on both driver
        # generations (ps1 and this port).
        vec="${IRQ_VECTOR:-}"; minp="${IRQ_MIN_PREFIX:-800}"
        # The two patterns follow check_pcout_vs_retired.py's wording. It was
        # translated on 2026-08-19 ("passt bis PC #" -> "matches up to PC #",
        # "dekodiert[N]=" -> "decoded[N]="), and these greps were left behind:
        # they silently matched nothing, so the IRQ-aware verdict could never
        # fire and a legitimate interrupt divergence would have been reported
        # as a plain FAIL. Both spellings are accepted now -- the old logs in
        # verification/evidence/ still carry the German one, and a gate that cannot read
        # its own history is worth less than one that can.
        pfx="$(grep -aoE '(passt bis PC #|matches up to PC #)[0-9]+' "$WORK/check$c.log" | grep -oE '[0-9]+$' | head -1 || true)"
        div="$(grep -aoE '(dekodiert|decoded)\[[0-9]+\]=0x[0-9a-fA-F]+' "$WORK/check$c.log" | grep -oE '0x[0-9a-fA-F]+$' | head -1 || true)"
        if [ "$c" -eq 1 ] && [ -n "$vec" ] && [ -n "$pfx" ] && [ "$pfx" -ge "$minp" ] && \
           [ -n "$div" ] && [ "$((div))" -eq "$((vec))" ]; then
            echo "### CORE${c}: PASS-IRQ -- reference-identical for $pfx PCs, then divergence into the trap vector $vec (interrupt timing is not the simulation's; see comment)"
        else
            fail=1; tail -6 "$WORK/check$c.log"
        fi
    fi
done
if [ "$fail" -ne 0 ]; then echo "### DUO_BOARD FAIL"; exit 1; fi
echo "### DUO_BOARD PASS (both cores decoded; prefix check per core where an oracle was given)"
