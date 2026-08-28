# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# cva6_linux64_run.sh -- board sequence of the RV64 Linux demonstrator on the
# cv64a6 (package R5a). Runs ON THE BOARD.
#
#   sudo PHASE=prep  bash cva6_linux64_run.sh     # clock, AFIFM, rings, payload + hash
#   sudo PHASE=start RUNSEC=3 bash cva6_linux64_run.sh
#   sudo PHASE=live  bash cva6_linux64_run.sh     # continuous mode for the dashboard
#   sudo PHASE=con   bash cva6_linux64_run.sh     # console ring -> /tmp/cva6_linux64_con.bin
#   sudo PHASE=login bash cva6_linux64_run.sh     # interactive, over the RX path
#   sudo PHASE=type CMD='...' bash cva6_linux64_run.sh
#   sudo PHASE=trace bash cva6_linux64_run.sh     # trace -> /tmp/cva6_linux64_trace.bin
#
# Twin of rocket_linux64_run.sh (package R5b) and sibling of
# rocket2_linux_run.sh (package M5); the three share their phase interface so
# that the dashboard server can call every recipe the same way (boot.json).
#
# ENCODER CONFIGURATION of the start/live phases (package W1):
#   SENDCFG=once|onsync        config message TCODE 58 (default: once)
#   SYNCMAX=<0-15>             trTeControl.InstSyncMax[23:20], sync every
#                              2^(x+4) instructions (default 6 = every 1024,
#                              the RDL reset value)
#   FEATURES=jtc,bp,ir,rh,wideicnt,rb,ibhs,ri   compression suite (default: none)
#   TRACE_DELAY=<s>            start recording only <s> seconds into the run (0)
#   SINK=uram|ddr              destination of the stream (default uram = the
#                              1 MiB URAM ring)
#
# WHY TRACE_DELAY AND SINK EXIST (a W1 measurement, not convenience): the 1 MiB
# URAM ring in one-shot mode holds the FIRST ~1.1 million instructions -- and
# those lie entirely inside OpenSBI (measured on the R5a capture: 1,102,954
# decoded PCs, ALL inside the window 0x6400_0000..0x6400_5400, not a single one
# above 2^32). An RV64 address proof needs Sv39 kernel addresses. Two ways to
# get there, both built in:
#   * TRACE_DELAY -- the core starts, the encoder only records later. The window
#     moves to where the kernel is already running with satp. The config message
#     still arrives: CFG_ONCE fires on the RISING EDGE of inst_trace_active
#     (ct_L23_preproc_composer_etip.sv:487).
#   * SINK=ddr -- instead of 1 MiB of URAM, the DDR sink window (RTL reset
#     0x6000_0000 + 64 MiB, `no-map` reserved and separate from the guest RAM
#     at 0x6400_0000). That is ~64x more window, and hence the chance of
#     catching the satp transition IN ONE PIECE instead of as two separate cuts.
#
# The config message is MANDATORY on the 64-bit encoder, not optional: the
# decoder reads CAPS bit 23 only from there and sets its address width to 64.
# Without it, it folds the JTC index at bit 25 instead of 63 and aborts in the
# middle of the stream ("VendorJTC references jump-target-cache index N which is
# not yet installed", R2.1c legs L3/L5). SENDCFG=none is therefore refused.
#
# WHY phys_io.py AND NOT `dd of=/dev/mem` (R5a finding): the guest window is
# `no-map` reserved. For such ranges the read()/write() path of /dev/mem
# answers "Bad address" -- only mmap works (measured 2026-07-27, documented in
# the header of examples/kv260/common/board/phys_io.py).
#   * Writing into the window: ctypes WORD LOOP (`write`) -- a slice copy faults
#     there with SIGBUS (glibc NEON memcpy on a device mapping).
#   * READING from the window likewise a word loop (`read`). The header of
#     phys_io.py clears the slice copy for reading ("64 MiB in 1.08 s") -- that
#     clearance does NOT hold for THIS window: `readbulk 0x64000000` died
#     reproducibly with "Bus error (core dumped)". The clearance comes from the
#     DDR SINK buffer; the guest window is evidently mapped differently. 32 MB
#     of word loop cost ~50 s here -- measured, not estimated.
#   * Aperture rings (0xA02.., 0xA03..): ALWAYS the word loop (`read`).
set -e
dm() { busybox devmem "$@"; }

APP=${APP:-cva6_linux64_x64ctx_ctrace_kv260}
PAYLOAD=${PAYLOAD:-/tmp/fw_payload64.bin}
GUEST=0x64000000
PHASE=${PHASE:-prep}
SINK=${SINK:-uram}

CTRL=0xA0000000
STATUS=0xA0000004
TR_BEATS=0xA0000008
TR_BYTES=0xA000000C
CON_BYTES=0xA0000014
CON_DROPS=0xA0000018
SINK_CTRL=0xA000001C
DDR_BASE=0xA0000020
DDR_SIZE=0xA0000024
DDR_WPTR=0xA0000028
SINK_STAT=0xA000002C
DDR_DROPS=0xA0000030
CON_TX=0xA0000034
CON_RPTR=0xA0000038
ENC=0xA0010000
ENC_FEAT=0xA0010008
TR_RING=0xA0200000
CON_RING=0xA0300000

CONFILE=/tmp/cva6_linux64_con.bin
TRFILE=/tmp/cva6_linux64_trace.bin

# The aperture is touched ONLY if EXACTLY our app is in the active slot.
# Otherwise the AXI interconnect hangs and the board is dead (2026-07-27/28,
# three frozen boards). fpga_manager "operating" is NOT sufficient as a
# criterion -- the starter-kit app programs the PL as well, but has no slave
# at 0xA000_0000.
if ! xmutil listapps 2>/dev/null | awk -v a="$APP" '$1==a && $NF!="-1" {f=1} END{exit !f}'; then
  echo "APP_NOT_ACTIVE ($APP) -- aperture NOT touched" >&2
  xmutil listapps >&2 || true
  exit 8
fi

# Type one line into the guest console (RX path, b8 = commit).
type_line() {
  s="$1"; i=0
  while [ $i -lt ${#s} ]; do
    c=$(printf '%s' "$s" | cut -c$((i+1)))
    o=$(printf '%d' "'$c")
    dm $CON_TX 32 $(printf '0x%08x' $((0x100 | o)))
    i=$((i+1))
  done
  dm $CON_TX 32 0x10A                      # newline
}

# Read the console ring. CAPPED: CON_BYTES is MONOTONIC (it is the write
# position), the ring holds only 65,536 bytes. An uncapped read would run past
# the window -- and a Linux boot followed by a login session passes 64 KiB
# easily.
read_con() {
  n=$1
  [ "$n" -gt 65536 ] && n=65536
  [ "$n" -gt 0 ] && python3 /tmp/phys_io.py read $CON_RING $(( (n + 3) / 4 * 4 )) -o $CONFILE
  echo "CONFILE $(ls -l $CONFILE 2>/dev/null | awk '{print $5}') (ring position $1)" >&2
}

# The DDR window is READ and CHECKED, never resized here.
#
# Two reasons, and both are measured elsewhere in this repository:
#  1. WRITING INTO FOREIGN MEMORY. `reserved-memory` is a BOOT-TIME
#     reservation. Without the reboot that carries
#     examples/kv260/common/board/ctrace_resmem.dtso, the range belongs to the
#     host kernel, and a sink writing there at tens of MB/s corrupts the HOST.
#     So the reservation is READ from the LIVE devicetree -- only the live tree
#     says what THIS boot actually reserved -- and a window without coverage is
#     refused instead of used.
#  2. ct_soc_ddr_sink must NOT have its size shrunk while running (finding
#     B-C1-1): `bytes_left = size_i - off_q` is unsigned, and in circular mode
#     room1 does not check it at all. This script therefore leaves base and
#     size at their RTL reset (0x6000_0000 + 64 MiB,
#     examples/kv260/cva6_linux64/rtl/cva6_linux64_soc_top.sv:433) and only
#     verifies that the reservation covers them.
ddr_check_window() {
  b=$(( $(dm $DDR_BASE) )); s=$(( $(dm $DDR_SIZE) ))
  set -- $(python3 - <<'PY'
import glob, struct
f = sorted(glob.glob('/sys/firmware/devicetree/base/reserved-memory/ctrace-pl-ddr@*/reg'))
if not f:
    print("0 0")
else:
    a, sz = struct.unpack('>QQ', open(f[0], 'rb').read()[:16])
    print(a, sz)
PY
)
  res_b=$1; res_s=$2
  printf 'RESMEM 0x%08X + 0x%08X   SINK 0x%08X + 0x%08X\n' \
         "$res_b" "$res_s" "$b" "$s" >&2
  if [ "$res_s" -gt 0 ] && [ "$b" -ge "$res_b" ] \
     && [ $(( b + s )) -le $(( res_b + res_s )) ]; then
    printf 'DDR_WINDOW 0x%08X + %d MiB (covered by the reservation)\n' \
           "$b" $(( s / 1048576 )) >&2
  else
    printf 'DDR_WINDOW_UNRESERVED -- 0x%08X + 0x%08X is NOT no-map reserved.\n' \
           "$b" "$s" >&2
    echo   "  Writing there would corrupt the host kernel's own RAM. The" >&2
    echo   "  reservation needs a REBOOT with" >&2
    echo   "  examples/kv260/common/board/ctrace_resmem.dtso installed." >&2
    echo   "  Use SINK=uram until then." >&2
    exit 15
  fi
}

# Encoder control word, assembled FIELD BY FIELD instead of from a hex
# constant. The constants in the archived board scripts carried
# InstSyncMax = 0 (full sync every 16 instructions) without saying so -- that
# is the value which floods the ring with ResourceFull+ProgTraceSync pairs and
# broke decode at the first jalr in fw_platform_init on every bitstream tested
# (2026-08-17). Two wrong fields inside one hex literal mask each other; named
# fields do not.
#
# trTeControl: b0 Active, b1 Enable, b2 InstTracing, [6:4] InstMode,
# [8:7] SendConfig, b9 Context, b15 InhibitSrc, [19:16] InstSyncMode,
# [23:20] InstSyncMax, [26:24] Format.
enc_words() {
  SENDCFG=${SENDCFG:-once}
  SYNCMAX=${SYNCMAX:-6}
  case "$SENDCFG" in
  once)   cfg=1 ;;
  onsync) cfg=2 ;;
  none)
    echo "SENDCFG_REQUIRED: this app carries the 64-bit encoder -- without the" >&2
    echo "  config message (SENDCFG=once) the stream is not decodable." >&2
    exit 10 ;;
  *) echo "unknown SENDCFG=$SENDCFG (once|onsync)" >&2; exit 2 ;;
  esac
  base=$(( (0x01060063 & ~0x180) | (cfg << 7) ))
  base=$(( (base & ~0x00F00000) | ((SYNCMAX & 0xF) << 20) ))
  ctrl_on=$(( base | 0x4 ))                       # b2 InstTracing
}

# Feature register: SrcBits [31:28], SrcID [27:16], compression suite [15:0].
# The word is written IN FULL rather than read-modify-written, so that the
# configuration does not depend on whatever a previous run left behind: two
# consecutive runs would otherwise not be comparable. With FEATURES="" the
# result is the same word the archived script wrote (0x2002_0000).
enc_feat() {
  SRC=${SRC:-2}
  feat=0
  for ft in $(printf '%s' "${FEATURES:-}" | tr ',' ' '); do
    case "$ft" in
    ir)       b=3  ;;
    bp)       b=4  ;;
    jtc)      b=5  ;;
    rh)       b=8  ;;
    rb)       b=11 ;;
    wideicnt) b=12 ;;
    ibhs)     b=13 ;;
    ri)       b=14 ;;
    *) echo "unknown FEATURE '$ft' (ir bp jtc rh rb wideicnt ibhs ri)" >&2; exit 2 ;;
    esac
    feat=$(( feat | (1 << b) ))
  done
  dm $ENC_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC << 16) | feat )))
  echo "FEAT $(dm $ENC_FEAT)  (SrcID $SRC, FEATURES='${FEATURES:-none}')" >&2
}

case "$PHASE" in
prep)
  # --- set pl_clk0 deliberately, do not just find it ------------------------
  # The PS controls the PL clock through PL0_REF_CTRL (CRL_APB). An xmutil
  # overlay carrying only `firmware-name` does NOT touch it -- a freshly
  # loaded design therefore runs at whatever the boot firmware left behind
  # (found on this board: 100 MHz, and 150 MHz on 2026-08-19).
  #
  # CHECK ONLY, never set (B-W1-1): kv260_plclk.sh refuses any change while an
  # app occupies the active slot -- and that is ALWAYS the case here, otherwise
  # the aperture clamp above would not have let this script get this far. An
  # unconditional call would be a guaranteed PLCLK_FAILED. The change itself
  # belongs BETWEEN unloadapp and loadapp; the dashboard server does it there
  # (server.py load_app(), driven by plclk.json).
  PL_MHZ=${PL_MHZ:-75}
  if [ "$PL_MHZ" != "skip" ]; then
    _cur=$(dm 0xFF5E00C0); _v=$((_cur))
    _d0=$(( (_v >> 8) & 0x3F )); _d1=$(( (_v >> 16) & 0x3F ))
    _hz=0
    [ "$_d0" -gt 0 ] && [ "$_d1" -gt 0 ] && _hz=$(( 1500000000 / (_d0 * _d1) ))
    # PL_MHZ is a LABEL, not an exact frequency: f = 1500 MHz / DIVISOR0 is not
    # freely choosable with integer dividers. Divider 22 gives 68181818 Hz --
    # NOT 68000000. The target hertz are therefore formed exactly as in
    # kv260_plclk.sh, otherwise the check fails on a rounding instead of on an
    # error.
    case "$PL_MHZ" in
      68)  _want=$(( 1500000000 / 22 )) ;;
      75)  _want=$(( 1500000000 / 20 )) ;;
      100) _want=$(( 1500000000 / 15 )) ;;
      *)   _want=$(( PL_MHZ * 1000000 )) ;;
    esac
    if [ "$_hz" = "$_want" ]; then
      echo "PLCLK OK: pl_clk0 = $_hz Hz (PL0_REF_CTRL=$_cur)" >&2
    else
      echo "PLCLK_WRONG: pl_clk0 = $_hz Hz, wanted $_want Hz -- the change" >&2
      echo "  belongs BETWEEN unloadapp and loadapp (see plclk.json)." >&2
      exit 9
    fi
  fi
  # PS AFIFM port widths (reset = 128 bit, needed once per boot):
  # HP0/AFIFM2 -> 32 bit (trace sink), HP1/AFIFM3 -> 64 bit (guest memory).
# FABRIC_WIDTH is bits [1:0] of RDCTRL/WRCTRL, and the reset value of those
# registers is 0x3B0 -- several bits above [1:0] are marked reserved but are
# RW and set out of reset (UG1087). Writing the whole register with the width
# code therefore clears them. Read-modify-write instead; pointed out
# 2026-08-21 while the AMP core-1 defect was being tracked down, and
# corrected everywhere the same day.
afifm_width() {   # $1 = AFIFM base, $2 = FABRIC_WIDTH code (0=128, 1=64, 2=32)
    for _o in 0x0 0x14; do
        _a=$(printf '0x%08X' $(( $1 + $_o )))
        _v=$(( $(dm $_a) ))
        dm $_a 32 $(printf '0x%08X' $(( (_v & ~0x3) | $2 )))
    done
}
  # Without this the first fetch of the core hangs (finding C6).
  afifm_width 0xFD380000 2
  afifm_width 0xFD390000 1
  echo "AFIFM HP0=$(dm 0xFD380000)/$(dm 0xFD380014) HP1=$(dm 0xFD390000)/$(dm 0xFD390014)" >&2
  dm $CTRL 32 0x6          # core in reset, clear trace ring and console ring
  dm $CTRL 32 0x0
  dm $CON_RPTR 32 0x0
  case "$SINK" in
  uram)
    # URAM one-shot (SINK_CTRL b3): the ring holds the FIRST 1 MiB from the
    # moment recording is switched on. Without one-shot it wraps, and the
    # beginning of the window would be overwritten.
    dm $SINK_CTRL 32 0x8 ;;
  ddr)
    ddr_check_window
    # DDR sink linear (b0 enable, b2=0 not circular) + clear pulse b1, AND the
    # URAM one-shot (b3) alongside: the two sinks are independent and run in
    # parallel, so one run yields BOTH windows -- 1 MiB of URAM and up to
    # 64 MiB of DDR out of the same stream. b1 does not latch (write mask
    # 0xFFFF_FFDD), the register reads back 0x9.
    dm $SINK_CTRL 32 0x0B
    echo "SINK=ddr SINK_CTRL=$(dm $SINK_CTRL) DDR_BASE=$(dm $DDR_BASE) DDR_SIZE=$(dm $DDR_SIZE) WPTR=$(dm $DDR_WPTR)" >&2 ;;
  *) echo "unknown SINK=$SINK (uram|ddr)" >&2; exit 2 ;;
  esac
  sz=$(stat -c%s "$PAYLOAD")
  src_md5=$(md5sum "$PAYLOAD" | cut -d' ' -f1)
  echo "PAYLOAD $PAYLOAD $sz B md5=$src_md5" >&2
  t0=$(date +%s)
  python3 /tmp/phys_io.py write $GUEST "$PAYLOAD"
  echo "WRITE_SECONDS $(( $(date +%s) - t0 ))" >&2
  # LOAD PROOF = the md5 READ BACK OUT OF THE WINDOW. A byte counter or a word
  # sample is not one (either could come from a previous run).
  python3 /tmp/phys_io.py read $GUEST "$sz" -o /tmp/cva6_linux64_rb.bin
  tgt_md5=$(md5sum /tmp/cva6_linux64_rb.bin | cut -d' ' -f1)
  rm -f /tmp/cva6_linux64_rb.bin
  echo "TARGET_MD5 $tgt_md5" >&2
  # ...and the comparison is actually DRAWN. Two sums printed underneath each
  # other while the script continues in every case would be an eye check, not
  # a check (the same correction rocket2_linux_run.sh carries since
  # 2026-08-10).
  if [ "$tgt_md5" != "$src_md5" ]; then
    echo "PREP_MD5_MISMATCH -- window $tgt_md5 != file $src_md5" >&2
    exit 11
  fi
  echo "PREP_DONE" >&2
  ;;
start)
  enc_feat
  enc_words
  TRACE_DELAY=${TRACE_DELAY:-0}
  if [ "$TRACE_DELAY" = "0" ]; then
    dm $ENC 32 $(printf '0x%08x' $ctrl_on)
    echo "ENC_CTRL $(dm $ENC)  (SENDCFG=$SENDCFG SYNCMAX=$SYNCMAX, recording from core start)" >&2
    dm $CTRL 32 0x1                     # core released -- OpenSBI runs from here
    echo "CORE_STARTED $(dm $CTRL)" >&2
  else
    # During the wait the encoder is COMPLETELY OFF (trTeControl = 0), not just
    # "InstTracing = 0". Reason, measured 2026-08-08 19:52: with Active/Enable
    # = 1 and only the emission disabled, the compression models inside the
    # encoder (JTC cache, BP table) KEEP RUNNING. When emission is switched on,
    # the encoder cache is warm while the decoder cache is empty -- and the
    # decode aborts after a few thousand instructions with "resolved source
    # PC ... to a non-indirect instruction ... decoder desynchronization". Out
    # of reset, both sides start empty. The config message still arrives
    # (CFG_ONCE fires on the rising edge of inst_trace_active).
    dm $ENC 32 0x00000000
    echo "ENC_CTRL $(dm $ENC)  (encoder OFF during the wait)" >&2
    dm $CTRL 32 0x1
    echo "CORE_STARTED $(dm $CTRL) -- waiting ${TRACE_DELAY}s before recording" >&2
    sleep "$TRACE_DELAY"
    dm $ENC 32 $(printf '0x%08x' $ctrl_on)
    echo "TRACE_ON at t=+${TRACE_DELAY}s: ENC_CTRL $(dm $ENC) (SENDCFG=$SENDCFG SYNCMAX=$SYNCMAX)" >&2
  fi
  sleep ${RUNSEC:-3}
  dm $ENC 32 $(printf '0x%08x' $base)   # tracing off, core KEEPS RUNNING
  sleep 0.3
  # Encoder fully off -- that closes the message in flight instead of letting
  # it end in the middle of a field.
  dm $ENC 32 0x0
  sleep 0.3
  [ "$SINK" = "ddr" ] && dm $SINK_CTRL 32 0x0
  echo "TRACE_BEATS $(dm $TR_BEATS) TRACE_BYTES $(dm $TR_BYTES)" >&2
  [ "$SINK" = "ddr" ] && echo "DDR wptr=$(dm $DDR_WPTR) stat=$(dm $SINK_STAT) drops=$(dm $DDR_DROPS)" >&2
  echo "CON_BYTES $(dm $CON_BYTES) CON_DROPS $(dm $CON_DROPS)" >&2
  echo "STATUS $(dm $STATUS)" >&2
  echo "START_DONE" >&2
  ;;
live)
  # CONTINUOUS MODE for the dashboard view. Difference to `start`: NOTHING is
  # switched off again. The encoder stays armed, the core keeps running, and
  # the ring runs CIRCULAR instead of one-shot -- otherwise the display stands
  # still after the first MiB and shows a freeze frame instead of traffic.
  #
  # b2 is the circular bit of ct_soc_ddr_sink (circ_i, wired in
  # examples/kv260/cva6_linux64/rtl/cva6_linux64_soc_top.sv:348); b3 = 0 lets
  # the URAM ring run circular as well, so both sink cards show traffic.
  if [ "$SINK" = "ddr" ]; then
    ddr_check_window
    dm $SINK_CTRL 32 0x5                # b0 DDR on, b2 circular, b3=0 URAM circular
  else
    dm $SINK_CTRL 32 0x0                # URAM circular (one-shot off)
  fi
  dm $CTRL 32 0x3                       # b1 trace_clear (pulse) with the core running
  dm $CTRL 32 0x1
  enc_feat
  enc_words
  dm $ENC 32 $(printf '0x%08x' $ctrl_on)
  sleep 1
  echo "LIVE ENC_CTRL $(dm $ENC) SENDCFG=$SENDCFG SYNCMAX=$SYNCMAX" >&2
  echo "LIVE SINK_CTRL $(dm $SINK_CTRL) SINK=$SINK" >&2
  [ "$SINK" = "ddr" ] && echo "LIVE DDR base=$(dm $DDR_BASE) size=$(dm $DDR_SIZE) wptr=$(dm $DDR_WPTR)" >&2
  b1=$(( $(dm $TR_BYTES) )); sleep 2; b2=$(( $(dm $TR_BYTES) ))
  echo "LIVE TRACE_BYTES $b1 -> $b2 (+$((b2 - b1)) in 2 s)" >&2
  echo "LIVE STATUS $(dm $STATUS) CON_BYTES $(dm $CON_BYTES)" >&2
  # The proof the display needs: is anything actually flowing? A freeze frame
  # would otherwise be indistinguishable from a hung core.
  if [ "$((b2 - b1))" -gt 0 ]; then
    echo "LIVE_OK -- stream is running" >&2
  else
    echo "LIVE_STALLED -- bytes +$((b2 - b1)) in 2 s" >&2
  fi
  echo "LIVE_DONE" >&2
  ;;
login)
  # Interactive guest console over the RX path (CON_TX 0x34: b8 = commit,
  # b7:0 = character). The ring is 64 KiB and CON_BYTES is MONOTONIC (= the
  # write position); CON_RPTR is only tracked so that con_used = wr - rd does
  # not reach the drop threshold -- it does not change the read address
  # (pos mod 64 KiB).
  before=$(dm $CON_BYTES); before=$((before))
  dm $CON_RPTR 32 $(printf '0x%08x' $before)
  echo "CON_BEFORE $before RX_USED $(dm $CON_TX)" >&2
  type_line "${LOGIN:-root}"
  sleep 4
  echo "RX_USED after the login input: $(dm $CON_TX)  (0 = the guest took it all)" >&2
  # One line per command -- NOT "for c in $CMDS": word splitting would tear
  # "uname -a" into two commands.
  printf '%s\n' "uname -a" "cat /proc/cpuinfo" "free -m" "echo R5A_ENV_OK" |
  while IFS= read -r c; do
    type_line "$c"
    sleep 4
  done
  now=$(dm $CON_BYTES); now=$((now))
  echo "CON_AFTER $now (+$((now - before))) DROPS $(dm $CON_DROPS)" >&2
  read_con "$now"
  ;;
type)
  before=$(dm $CON_BYTES); before=$((before))
  dm $CON_RPTR 32 $(printf '0x%08x' $before)
  type_line "$CMD"
  sleep ${WAIT:-4}
  now=$(dm $CON_BYTES); now=$((now))
  echo "CON_AFTER $now (+$((now - before))) DROPS $(dm $CON_DROPS)" >&2
  read_con "$now"
  ;;
con)
  n=$(dm $CON_BYTES); n=$((n))
  echo "CON_BYTES $n DROPS $(dm $CON_DROPS)" >&2
  read_con "$n"
  ;;
trace)
  if [ "$SINK" = "ddr" ]; then
    # DDR_WPTR (0x28) = bytes written since the clear pulse; SINK_STAT (0x2C)
    # carries b0 ddr_full / b1 ddr_axi_err / b2 ddr_wrapped.
    n=$(( $(dm $DDR_WPTR) )); sz=$(( $(dm $DDR_SIZE) ))
    [ "$n" -gt "$sz" ] && n=$sz
    src=$(dm $DDR_BASE)
    echo "DDR_WPTR $(dm $DDR_WPTR) SINK_STAT $(dm $SINK_STAT) DDR_DROPS $(dm $DDR_DROPS)" >&2
  else
    # The URAM ring is always readable (it runs along in both SINK modes).
    n=$(( $(dm $TR_BYTES) ))
    [ "$n" -gt 1048576 ] && n=1048576
    src=$TR_RING
  fi
  # Cap against an accidentally huge read. If it bites, that is ANNOUNCED -- a
  # silently truncated stream would have fewer bytes AND fewer instructions,
  # and every number computed from it would still look plausible.
  MAXB=${MAXB:-4194304}
  cap=0
  if [ "$n" -gt "$MAXB" ]; then n=$MAXB; cap=1; fi
  echo "TRACE_BYTES $n (beats=$(dm $TR_BEATS) status=$(dm $STATUS) capped=$cap)" >&2
  [ "$n" -gt 0 ] && python3 /tmp/phys_io.py read $src $(( (n + 3) / 4 * 4 )) -o $TRFILE
  echo "TRACEFILE $(ls -l $TRFILE 2>/dev/null | awk '{print $5}')" >&2
  ;;
*)
  echo "unknown PHASE=$PHASE" >&2; exit 2 ;;
esac
