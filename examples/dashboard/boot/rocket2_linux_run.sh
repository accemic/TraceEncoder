# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# rocket2_linux_run.sh -- board sequence of the TWO-HART Rocket demonstrator.
# Runs ON THE BOARD.
#
#   sudo PHASE=prep  bash rocket2_linux_run.sh     # clock, AFIFM, rings, payload + hash
#   sudo PHASE=diag  bash rocket2_linux_run.sh     # signs of life from BOTH harts
#   sudo PHASE=start RUNSEC=3 bash rocket2_linux_run.sh
#   sudo PHASE=con   bash rocket2_linux_run.sh     # console ring -> /tmp/r2_con.bin
#   sudo PHASE=login bash rocket2_linux_run.sh     # interactive over the RX path
#   sudo PHASE=type CMD='...' bash rocket2_linux_run.sh
#   sudo PHASE=trace bash rocket2_linux_run.sh     # trace -> /tmp/r2_trace.bin
#
# Twin of rocket_linux64_run.sh. It was deliberately NOT extended but
# duplicated: the single-hart app stays operable unchanged, and a script that
# writes ENC1 @0x02_0000 cannot accidentally run against the single-hart app
# (where nothing answers at that address).
#
# FOUR differences, and every single one is a place where the proof would
# otherwise fail SILENTLY:
#
#  1. TWO encoder windows, with DIFFERENT SrcIDs.
#       ENC0 0xA0010000 -> SrcBits 2 / SrcID 0   (hart 0)
#       ENC1 0xA0020000 -> SrcBits 2 / SrcID 1   (hart 1)
#     Without different SrcIDs the merged stream carries only one source and
#     `NexRv -target 1` returns zero instructions -- on the board that looks
#     like "the funnel does not separate" (counter-check P-1).
#
#  2. trTeControl with THREE bits that the older scripts do NOT set:
#       b9  Context      -- without this bit the composer produces NO
#                           ownership message (TCODE 2). Exactly this one bit
#                           was the difference between 13 and 0 messages.
#       b15 InhibitSrc=0 -- otherwise the SRC field is missing in the frame.
#       [23:20] InstSyncMax -- the default 0 means full synchronization every
#                           16 instructions. Measured: 221-359 error messages
#                           and gaps in BOTH sequences; on real software the
#                           same effect costs a factor of 3.9 in bandwidth.
#     The value proven in simulation is 0x016602E7 (SYNCMAX=6).
#
#  3. Observation channel PER HART (0x4C/0x50/0x54 and 0x5C/0x60/0x64) plus
#     STATUS b18/b19 (retire_seen per hart) and b[14:12]/b[22:20] (privilege
#     level per hart). That is the proof "two harts really run" which does NOT
#     go through the trace -- so it does not share the failure domain of the
#     thing it is meant to prove.
#
#  4. FUNNEL_CTRL 0xA0000058 is read and logged (reset 0x11 = round robin). An
#     arbitration that starves one channel would look, in the result, exactly
#     like "hart 1 is not running".
#
# WHY phys_io.py AND NOT `dd of=/dev/mem`: the window is reserved `no-map`, the
# read()/write() path returns "Bad address" there, only mmap works. And the
# slice copy (`readbulk`) faults on THIS board even on the DDR sink buffer with
# "Bus error" (open issue) -- hence the ctypes word loop everywhere.
set -e
dm() { busybox devmem "$@"; }

APP=${APP:-rocket2_ctrace_kv260}
PAYLOAD=${PAYLOAD:-/tmp/fw_payload_rocket2.bin}
GUEST=0x64000000          # PS view; the Rocket harts see this as 0x8000_0000
PHASE=${PHASE:-prep}

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
WIN_ERR_CNT=0xA000003C
WIN_ERR_LO=0xA0000040
WIN_ERR_HI=0xA0000044
PC0_LO=0xA000004C
PC0_HI=0xA0000050
RETIRES0=0xA0000054
FUNNEL_CTRL=0xA0000058
PC1_LO=0xA000005C
PC1_HI=0xA0000060
RETIRES1=0xA0000064
ENC0=0xA0010000
ENC0_FEAT=0xA0010008
ENC1=0xA0020000
ENC1_FEAT=0xA0020008
TR_RING=0xA0200000
CON_RING=0xA0300000

# --- OpenSBI cold-boot arbiters IN THE GUEST IMAGE ------------------------
# FOUR words decide whether a released core boots COLD or falls into the warm
# path. Offsets relative to the start of the image (guest 0x8000_0000 =
# PS $GUEST), addresses from `nm fw_payload.elf`:
#   0x40000 _boot_lottery     (.data)  asm lottery in fw_base.S
#   0x40008 _boot_status      (.data)  asm progress marker
#   0x43000 coldboot_lottery  (.bss)   C lottery in sbi_init()
#   0x43018 coldboot_done     (.bss)
#
# In the FILE all four are 0. A booted guest sets all four to 1 -- and they
# survive ITS OWN RESET, because the reset only hits the cores, not the DDR.
# If it is then released again without reloading, hart 0 reads "somebody has
# already done the cold boot", takes the warm path and parks in
# sbi_hsm_hart_wait() on an IPI that nobody sends; hart 1 meanwhile stays in
# the park loop of the boot ROM waiting for exactly that IPI. Both wait for
# each other and the console stays at 0 bytes.
#
# THAT is the "it worked the first time, not afterwards" failure: hart0
# 0x8001_077E (a `wfi`, resolved against sbi.dis), hart1 0x0001_0064 (likewise
# `wfi`, rom_patched.dis:31), STATUS 0x003C_3701. It was triggered from the
# UI: `ctl stop` writes CONTROL=0 (that is NOT a pause, b0 is core_rst_hold)
# and `ctl run` releases again WITHOUT reloading the payload. Reproduced
# bit-identically.
ARB="_boot_lottery:0x40000 _boot_status:0x40008 coldboot_lottery:0x43000 coldboot_done:0x43018"

arb_show() {
  s=""
  for e in $ARB; do
    s="$s ${e%%:*}=$(dm $(printf '0x%08x' $(( GUEST + ${e#*:} ))))"
  done
  echo "ARB $1:$s" >&2
}

# True (0) when AT LEAST ONE arbiter is set -- the image is then used and a
# core release on top of it can no longer boot cold.
arb_used() {
  for e in $ARB; do
    if [ $(( $(dm $(printf '0x%08x' $(( GUEST + ${e#*:} )))) )) -ne 0 ]; then
      return 0
    fi
  done
  return 1
}

# Before EVERY release from reset. If the cores already run, set arbiters are
# the normal case (the guest is running) and no error -- the check therefore
# only applies when b0 really is 0.
arb_gate() {
  if [ $(( $(dm $CTRL) & 1 )) -ne 0 ]; then return 0; fi
  if ! arb_used; then return 0; fi
  arb_show "before the release"
  echo "GUEST_IMAGE_USED -- the image in DDR is used: a booted OpenSBI has set" >&2
  echo "  the cold-boot arbiters. Releasing on top of that ends in hart0 =" >&2
  echo "  sbi_hsm_hart_wait and hart1 = boot-ROM park, both waiting for each" >&2
  echo "  other, and the console stays silent." >&2
  echo "  Remedy: PHASE=prep -- reloads the payload AND verifies it." >&2
  echo "  Merely releasing again cannot heal this (measured: a partial restore" >&2
  echo "  is not enough either, the core then hangs at the kernel entry" >&2
  echo "  0x8020_00F4 instead of at the warm path)." >&2
  exit 14
}

LABEL=${LABEL:-m5}
SINK=${SINK:-ddr}         # ddr (256 MiB, default) | uram (1 MiB one-shot)
# Default: DDR4 rather than URAM. The URAM ring holds 1 MiB and is full after
# 35 ms at the MEASURED 29.7 MB/s -- too small as the default for a view that
# is supposed to show traffic.
#
# ADDRESS PLAN v4 ("256 MB of trace memory, otherwise the write pointer runs
# through too fast"):
#     0x5000_0000 +256 MiB  trace sink    <- HERE
#     0x6000_0000  +64 MiB  GAP (the old trace window)
#     0x6400_0000 +192 MiB  guest         <- unchanged
# Measured: 64 MiB wrap every 2.3 s, 256 MiB every 9.0 s. The encoder is NO
# lever for this -- InstSyncMax 6 -> 15 changes the byte rate by 0.3 %.
DDR_WIN_BASE=${DDR_WIN_BASE:-0x50000000}
DDR_WIN_SIZE=${DDR_WIN_SIZE:-0x10000000}

# The aperture is touched ONLY when EXACTLY our app owns the active slot.
# Otherwise the AXI interconnect wedges and the board is dead (three boards
# frozen that way). fpga_manager "operating" is NOT a sufficient criterion.
if ! xmutil listapps 2>/dev/null | awk -v a="$APP" '$1==a && $NF!="-1" {f=1} END{exit !f}'; then
  echo "APP_NOT_ACTIVE ($APP) -- aperture NOT touched" >&2
  xmutil listapps >&2 || true
  exit 8
fi

# A diagnostic line that names BOTH harts. A shared counter would happily keep
# running while ONE hart stands still -- with two harts, "is the core making
# progress?" is no longer one question but two.
diag_line() {
  st=$(dm $STATUS); stv=$((st))
  echo "  STATUS=$st [retire0=$(( (stv >> 18) & 1 )) retire1=$(( (stv >> 19) & 1 ))" \
       "priv0=$(( (stv >> 12) & 7 )) priv1=$(( (stv >> 20) & 7 ))]" >&2
  echo "  HART0 RETIRES=$(dm $RETIRES0) PC=$(dm $PC0_HI):$(dm $PC0_LO)" >&2
  echo "  HART1 RETIRES=$(dm $RETIRES1) PC=$(dm $PC1_HI):$(dm $PC1_LO)" >&2
  echo "  WIN_ERR=$(dm $WIN_ERR_CNT)@$(dm $WIN_ERR_HI):$(dm $WIN_ERR_LO)" \
       "CON=$(dm $CON_BYTES)/$(dm $CON_DROPS) TR=$(dm $TR_BYTES) FUNNEL=$(dm $FUNNEL_CTRL)" >&2
}

# --- set the trace window -- WITH a coverage check against the live devicetree
#
# TWO traps live here, and both are expensive:
#
#  1. WRITING INTO FOREIGN MEMORY. `reserved-memory` is a BOOT-TIME
#     reservation. As long as the reboot with the new ctrace_resmem.dtso has
#     not happened, 0x5000_0000..0x5FFF_FFFF belongs to the Ubuntu kernel
#     (`/proc/iomem`: "00000000-5fffffff : System RAM"). A sink writing there
#     at 29.7 MB/s corrupts the HOST. The reservation is therefore READ, not
#     assumed, and without coverage the RTL reset value stays in place.
#
#  2. ct_soc_ddr_sink must NOT have its size reduced while running.
#     `bytes_left = size_i - off_q` is unsigned (ct_soc_ddr_sink.sv:99), and in
#     circular mode room1 does not check it at all (:101). If off_q is above
#     the new size, the difference underflows and exactly ONE transfer goes to
#     base+off_q -- outside the window. Measured byte-exactly: 4 bytes at
#     0x63F0_022C with off_q=0x03F0_022C, red counter-probe with a clear pulse
#     at 0 bytes. The order below -- switch off, CLEAR, set, switch on -- is
#     therefore not caution but the measured condition for this not happening.
ddr_window_setup() {
  want_b=$(( DDR_WIN_BASE )); want_s=$(( DDR_WIN_SIZE ))
  # Reservation from the LIVE devicetree, not from the source file: only the
  # live tree says what this boot actually reserved.
  set -- $(python3 - <<'PY'
import glob, struct
f = sorted(glob.glob('/sys/firmware/devicetree/base/reserved-memory/ctrace-pl-ddr@*/reg'))
if not f:
    print("0 0")
else:
    a, s = struct.unpack('>QQ', open(f[0], 'rb').read()[:16])
    print(a, s)
PY
)
  res_b=$1; res_s=$2
  printf 'RESMEM 0x%08X + 0x%08X   WANTED 0x%08X + 0x%08X\n' \
         "$res_b" "$res_s" "$want_b" "$want_s" >&2
  if [ "$res_s" -gt 0 ] && [ "$want_b" -ge "$res_b" ] \
     && [ $(( want_b + want_s )) -le $(( res_b + res_s )) ]; then
    # Covered. Set the window -- in the order the underflow trap enforces.
    dm $SINK_CTRL 32 0x0
    dm $SINK_CTRL 32 0x2                     # clear -> off_q = 0
    dm $DDR_BASE 32 $(printf '0x%08X' $want_b)
    dm $DDR_SIZE 32 $(printf '0x%08X' $want_s)
    got_b=$(( $(dm $DDR_BASE) )); got_s=$(( $(dm $DDR_SIZE) ))
    if [ "$got_b" != "$want_b" ] || [ "$got_s" != "$want_s" ]; then
      printf 'DDR_WINDOW_REJECTED register 0x%08X+0x%08X instead of 0x%08X+0x%08X\n' \
             "$got_b" "$got_s" "$want_b" "$want_s" >&2
      exit 15
    fi
    printf 'DDR_WINDOW 0x%08X + %d MiB (wrap ~%d.%d s at 29.7 MB/s)\n' \
           "$got_b" $(( got_s / 1048576 )) \
           $(( got_s / 29700000 )) $(( (got_s * 10 / 29700000) % 10 )) >&2
  else
    # NOT covered -> change nothing. The RTL reset value lies in the old,
    # provably reserved window; a short wrap is better than a corrupted host.
    printf 'DDR_WINDOW_UNRESERVED -- 0x%08X + 0x%08X is NOT reserved no-map.\n' \
           "$want_b" "$want_s" >&2
    echo   "  The RTL reset value stays. The large window needs the REBOOT" >&2
    echo   "  with the new ctrace_resmem.dtso device-tree overlay" >&2
    echo   "  (see the board memory map in the documentation)." >&2
    printf 'DDR_WINDOW (reset) 0x%08X + %d MiB\n' \
           $(( $(dm $DDR_BASE) )) $(( $(dm $DDR_SIZE) / 1048576 )) >&2
  fi
}

# Read the console ring. CAPPED: CON_BYTES is MONOTONIC (a write position),
# but the ring holds only 65,536 bytes. An uncapped read would run past the
# window -- and a Linux boot plus a login session exceeds 64 KiB easily.
read_con() {
  n=$1
  [ "$n" -gt 65536 ] && n=65536
  [ "$n" -gt 0 ] && python3 /tmp/phys_io.py read $CON_RING $(( (n + 3) / 4 * 4 )) -o /tmp/r2_con.bin
  echo "CONFILE $(ls -l /tmp/r2_con.bin 2>/dev/null | awk '{print $5}') (ring position $1)" >&2
}

type_line() {
  s="$1"; i=0
  while [ $i -lt ${#s} ]; do
    c=$(printf '%s' "$s" | cut -c$((i+1)))
    o=$(printf '%d' "'$c")
    dm $CON_TX 32 $(printf '0x%08x' $((0x100 | o)))
    i=$((i+1))
  done
  dm $CON_TX 32 0x10A                      # '\n'
}

case "$PHASE" in
prep)
  # --- pin pl_clk0 down instead of taking it as found ----------------------
  # CHECK first, set only if needed: kv260_plclk.sh refuses every change while
  # an app owns the active slot -- and that is ALWAYS the case here, otherwise
  # the script would not have got this far. An unconditional call would be a
  # guaranteed PLCLK_FAILED. The change itself therefore belongs BETWEEN
  # unloadapp and loadapp (host script).
  PL_MHZ=${PL_MHZ:-75}
  if [ "$PL_MHZ" != "skip" ]; then
    _cur=$(dm 0xFF5E00C0); _v=$((_cur))
    _d0=$(( (_v >> 8) & 0x3F )); _d1=$(( (_v >> 16) & 0x3F ))
    _hz=0
    [ "$_d0" -gt 0 ] && [ "$_d1" -gt 0 ] && _hz=$(( 1500000000 / (_d0 * _d1) ))
    # PL_MHZ is a LABEL, not an exact frequency: f = 1500 MHz / DIVISOR0 is not
    # freely choosable with integer divisors. Divisor 22 gives 68181818 Hz --
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
      echo "  belongs BETWEEN unloadapp and loadapp (host script)." >&2
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
  # Without it the first fetch of the cores hangs.
  afifm_width 0xFD380000 2
  afifm_width 0xFD390000 1
  echo "AFIFM HP0=$(dm 0xFD380000)/$(dm 0xFD380014) HP1=$(dm 0xFD390000)/$(dm 0xFD390014)" >&2
  # Both harts in reset; clear rings, window-guard diagnostics and the
  # observation sticky bits (b1|b2|b3|b4 = 0x1E, level triggered).
  dm $CTRL 32 0x1E
  dm $CTRL 32 0x0
  dm $CON_RPTR 32 0x0
  echo "FUNNEL_CTRL $(dm $FUNNEL_CTRL) (reset 0x11 = round robin)" >&2
  sz=$(stat -c%s "$PAYLOAD")
  src_md5=$(md5sum "$PAYLOAD" | cut -d' ' -f1)
  echo "PAYLOAD $PAYLOAD $sz B md5=$src_md5" >&2
  arb_show "before the load"
  t0=$(date +%s)
  # Word loop, NO writebulk: the slice copy faults on this `no-map` window
  # with "Bus error". Measured rather than believed (the run died after 1 s) --
  # 42 s per restart hang on this note.
  python3 /tmp/phys_io.py write $GUEST "$PAYLOAD"
  echo "WRITE_SECONDS $(( $(date +%s) - t0 ))" >&2
  # LOAD EVIDENCE = md5 READ BACK FROM THE WINDOW. A byte counter or a word
  # sample is none (it can just as well come from an earlier run).
  python3 /tmp/phys_io.py read $GUEST "$sz" -o /tmp/r2_rbr.bin
  tgt_md5=$(md5sum /tmp/r2_rbr.bin | cut -d' ' -f1)
  rm -f /tmp/r2_rbr.bin
  echo "TARGET_MD5 $tgt_md5" >&2
  # ...and the comparison is actually DRAWN. Previously two sums stood here
  # below each other and the script continued in EVERY case -- an eyeball
  # check, not a check. "TARGET_MD5 is right" was thus a statement about the
  # reader, not about the board.
  if [ "$tgt_md5" != "$src_md5" ]; then
    echo "PREP_MD5_MISMATCH -- window $tgt_md5 != file $src_md5" >&2
    exit 11
  fi
  # And the evidence that matters on the SECOND start: are the four cold-boot
  # arbiters 0 again? It follows from the md5 equality, but only stated
  # explicitly is it visible -- and exactly this property is the difference
  # between "boots" and "hangs".
  arb_show "after the load"
  if arb_used; then
    echo "PREP_GUEST_NOT_PRISTINE -- arbiters set despite md5 equality." >&2
    echo "  That is a contradiction: either somebody writes into the guest" >&2
    echo "  window in parallel, or the cores were running during the load" >&2
    echo "  (CTRL b0). CTRL=$(dm $CTRL)" >&2
    exit 12
  fi
  echo "PREP_DONE" >&2
  ;;
diag)
  echo "DIAG t0:" >&2; diag_line
  sleep 2
  echo "DIAG t1 (+2 s):" >&2; diag_line
  ;;
start)
  # First the question that decides the whole run: can this image still boot
  # at all? Before the sink dance, so that a hopeless run does not first
  # collect a second of trace and then wedge silently.
  arb_gate
  # --- prepare the sink -----------------------------------------------------
  # STALE BYTES are a real problem here, not a precaution: the beat FIFO in
  # front of the sink holds the remainder of the previous run, and a window
  # then begins with the END of its predecessor (measured: 3,528 B of residual
  # surge, gone after ~1 s). In the stream that looks like a framing error and
  # is none.
  if [ "$SINK" = "ddr" ]; then
    ddr_window_setup              # window BEFORE arming for the first time
    dm $SINK_CTRL 32 0x1          # sink on, so the residual surge drains
    prev=-1; i=0
    while [ $i -lt 20 ]; do
      sleep 0.2
      cur=$(( $(dm $DDR_WPTR) ))
      [ "$cur" = "$prev" ] && break
      prev=$cur; i=$((i+1))
    done
    dm $SINK_CTRL 32 0x0
    echo "DRAIN $prev B after $i rounds" >&2
    dm $SINK_CTRL 32 0x2          # ddr_clear (pulse)
    # The loop above is INEFFECTIVE on its own: it waits for a standing
    # DDR_WPTR -- but the residual surge only runs into the fresh buffer AFTER
    # the clear. Consequence: every capture begins with the end of its
    # predecessor, the seam sits in the middle of a message, and the decoder
    # aborts the WHOLE run on it. The position is exactly predictable
    # (DDR_WPTR right before arming, 5 of 5 windows), and at the 2 KiB
    # boundary the surge is additionally written twice. Therefore: after the
    # clear, let it drain AGAIN and clear a SECOND time. Measured: 0 of 8
    # arming events broken, 0 damaged spots in 351,496 messages (without
    # RECLEAR: 5 of 5).
    dm $SINK_CTRL 32 0x1
    prev2=-1; j=0
    while [ $j -lt 20 ]; do
      sleep 0.2
      cur=$(( $(dm $DDR_WPTR) ))
      [ "$cur" = "$prev2" ] && break
      prev2=$cur; j=$((j+1))
    done
    dm $SINK_CTRL 32 0x0
    echo "RECLEAR $prev2 B after $j rounds" >&2
    dm $SINK_CTRL 32 0x2          # second ddr_clear
    w0=$(dm $DDR_WPTR)
    [ $(( w0 )) -eq 0 ] || { echo "DDR_NOT_CLEARED ($w0)" >&2; exit 13; }
    dm $SINK_CTRL 32 0x1          # linear (b2 = 0), 64 MiB
  else
    dm $CTRL 32 0x2; dm $CTRL 32 0x0     # empty the URAM ring
    dm $SINK_CTRL 32 0x8                 # URAM one-shot: the FIRST 1 MiB
  fi
  echo "SINK=$SINK SINK_CTRL=$(dm $SINK_CTRL) base=$(dm $DDR_BASE) size=$(dm $DDR_SIZE)" >&2

  # --- encoder configuration ------------------------------------------------
  # Features register: SrcBits [31:28] = 2, SrcID [27:16]; the lower 16 bits
  # are the compression suite and are preserved by read-modify-write.
  # SrcID 0 for hart 0, SrcID 1 for hart 1 -- THAT is the separation.
  feat=0
  for ft in $(printf '%s' "${FEATURES:-}" | tr ',' ' '); do
    case "$ft" in
    ir) b=3 ;; bp) b=4 ;; jtc) b=5 ;; rh) b=8 ;;
    rb) b=11 ;; wideicnt) b=12 ;; ibhs) b=13 ;; ri) b=14 ;;
    *) echo "unknown FEATURE '$ft'" >&2; exit 2 ;;
    esac
    feat=$(( feat | (1 << b) ))
  done
  SRC0=${SRC0:-0}; SRC1=${SRC1:-1}
  dm $ENC0_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC0 << 16) | feat )))
  dm $ENC1_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC1 << 16) | feat )))
  echo "FEAT0 $(dm $ENC0_FEAT) FEAT1 $(dm $ENC1_FEAT) (SrcID $SRC0/$SRC1, FEATURES='${FEATURES:-none}')" >&2

  # trTeControl: b0 Active, b1 Enable, b2 InstTracing, [6:4] InstMode,
  # [8:7] SendConfig, b9 Context, b15 InhibitSrc, [19:16] InstSyncMode,
  # [23:20] InstSyncMax, [26:24] Format.
  SENDCFG=${SENDCFG:-once}
  SYNCMAX=${SYNCMAX:-6}
  case "$SENDCFG" in none) cfg=0 ;; once) cfg=1 ;; onsync) cfg=2 ;;
  *) echo "unknown SENDCFG=$SENDCFG (none|once|onsync)" >&2; exit 2 ;; esac
  # SENDCFG is MANDATORY on the 64-bit encoder: only from the config message
  # does the decoder read CAPS bit 23 and switch its address width to 64.
  # Without it, it folds the index at bit 25 and aborts.
  if [ "$cfg" = "0" ]; then
    echo "SENDCFG_REQUIRED: CT_XLEN=64 -- without the config message the" >&2
    echo "  stream is not decodable (SENDCFG=once)." >&2
    exit 10
  fi
  base=$(( (0x01060063 & ~0x180) | (cfg << 7) | 0x200 ))        # b9 Context ON
  base=$(( base & ~0x8000 ))                                    # b15 InhibitSrc OFF
  base=$(( (base & ~0x00F00000) | ((SYNCMAX & 0xF) << 20) ))
  ctrl_on=$(( base | 0x4 ))                                     # b2 InstTracing
  dm $ENC0 32 $(printf '0x%08x' $ctrl_on)
  dm $ENC1 32 $(printf '0x%08x' $ctrl_on)
  echo "ENC_CTRL0 $(dm $ENC0) ENC_CTRL1 $(dm $ENC1) SYNCMAX=$SYNCMAX (sync every $((1 << (SYNCMAX + 4))) instr) SENDCFG=$SENDCFG" >&2

  # --- release the cores ----------------------------------------------------
  dm $CTRL 32 0x1                       # b0 releases BOTH harts
  echo "CORE_STARTED $(dm $CTRL)" >&2
  t0=$(date +%s%N)
  sleep ${RUNSEC:-3}
  dm $ENC0 32 $(printf '0x%08x' $base)  # InstTracing off, cores KEEP running
  dm $ENC1 32 $(printf '0x%08x' $base)
  t1=$(date +%s%N)
  sleep 0.3
  # Encoder fully off -- that completes the message in flight instead of
  # ending it in the middle of a field.
  dm $ENC0 32 0x0
  dm $ENC1 32 0x0
  sleep 0.3
  [ "$SINK" = "ddr" ] && dm $SINK_CTRL 32 0x0
  echo "M5_US $(( (t1 - t0) / 1000 ))" >&2
  echo "TRACE_BEATS $(dm $TR_BEATS) TRACE_BYTES $(dm $TR_BYTES)" >&2
  echo "DDR wptr=$(dm $DDR_WPTR) stat=$(dm $SINK_STAT) drops=$(dm $DDR_DROPS)" >&2
  echo "CON_BYTES $(dm $CON_BYTES) CON_DROPS $(dm $CON_DROPS)" >&2
  echo "WIN_ERR_CNT $(dm $WIN_ERR_CNT) @ $(dm $WIN_ERR_HI):$(dm $WIN_ERR_LO)" >&2
  echo "FUNNEL_CTRL $(dm $FUNNEL_CTRL)" >&2
  diag_line
  # THE hardware proof that does NOT go through the trace: two separate
  # retire counters, both non-zero and different from each other.
  r0=$(( $(dm $RETIRES0) )); r1=$(( $(dm $RETIRES1) ))
  # BLIND CHECK FIXED: this used to be `r0 > 0 && r1 > 0` on CUMULATIVE
  # counters that no reset clears. After the first real boot the check
  # therefore ALWAYS passed -- the last run reported PASS with hart0=1793832784
  # and hart1=18, both frozen. A measurement that cannot measure after the
  # first time is worse than none: it colours a dead core green. What is
  # checked now is the INCREASE over a time window.
  sleep 1
  r0b=$(( $(dm $RETIRES0) )); r1b=$(( $(dm $RETIRES1) ))
  d0=$(( r0b - r0 )); d1=$(( r1b - r1 ))
  echo "M5_RETIRES hart0=$r0 (+$d0 in 1 s)  hart1=$r1 (+$d1 in 1 s)" >&2
  if [ "$d0" -gt 0 ] && [ "$d1" -gt 0 ]; then
    echo "M5_TWOHART_HW PASS -- both harts are retiring NOW (+$d0/+$d1)" >&2
  else
    echo "M5_TWOHART_HW FAIL -- increase hart0=+$d0 hart1=+$d1 (at $r0/$r1)" >&2
    echo "M5_HINT PC hart0=$(dm $PC0_HI):$(dm $PC0_LO) hart1=$(dm $PC1_HI):$(dm $PC1_LO)" >&2
    # The one signature we can name, instead of leaving the reader to look for
    # it. Deliberately phrased STRUCTURALLY (hart 1 below the guest memory,
    # i.e. still in the boot ROM) and not pinned to the address 0x0001_0064: a
    # newly built payload would move the address, and a hint that then silently
    # stops firing is worse than none.
    if [ $(( $(dm $PC1_LO) )) -lt $(( 0x80000000 )) ] && [ "$d1" -eq 0 ]; then
      echo "M5_HINT hart1 is still in the boot ROM (PC < 0x8000_0000) waiting" >&2
      echo "  for an IPI. Typical for a USED guest image: hart0 falls into the" >&2
      echo "  warm path (sbi_hsm_hart_wait) and never sends it. Remedy:" >&2
      echo "  PHASE=prep. The console stands at $(dm $CON_BYTES) B." >&2
      arb_show "in the failing case"
    fi
  fi
  echo "START_DONE" >&2
  ;;
live)
  # CONTINUOUS OPERATION for the dashboard view. Difference to
  # `start`/`window`: NOTHING is switched off again here. The encoders stay
  # armed, the cores keep running, and the URAM ring runs CIRCULAR instead of
  # one-shot -- otherwise the display freezes after the first MiB and shows a
  # still image instead of traffic.
  #
  # The register values are LITERALLY those from `start`; typing them out here
  # would build a second place of truth for the same configuration.
  # DDR4 is the default sink: b0 sink on, b2 CIRCULAR. That b2 is not a detail
  # here but the condition for continuous operation -- linear, the 64 MiB
  # window would be full after three seconds at ~22 MB/s and the display would
  # stand still. Bit 2 is proven in the RTL: rocket2_soc_top.sv:327 wires
  # circ_i (sink_ctrl_reg[2]). b3=0 lets the URAM ring run circular as well, so
  # that both sink cards show traffic.
  # Here too: `live` sets b0 and thereby releases a core standing in reset. On
  # a used image the result would be a still image reporting LIVE_STALLED
  # without naming the reason.
  arb_gate
  ddr_window_setup                      # sets base/size and switches off +
                                        # clears on the way -- MUST come before
                                        # arming, not after
  dm $SINK_CTRL 32 0x5                  # b0 DDR on, b2 circular, URAM circular
  dm $CTRL 32 0x3                       # b1 trace_clear (pulse) with cores running
  dm $CTRL 32 0x1
  feat=0
  for ft in $(printf '%s' "${FEATURES:-}" | tr ',' ' '); do
    case "$ft" in
    ir) b=3 ;; bp) b=4 ;; jtc) b=5 ;; rh) b=8 ;;
    rb) b=11 ;; wideicnt) b=12 ;; ibhs) b=13 ;; ri) b=14 ;;
    *) echo "unknown FEATURE '$ft'" >&2; exit 2 ;;
    esac
    feat=$(( feat | (1 << b) ))
  done
  SRC0=${SRC0:-0}; SRC1=${SRC1:-1}
  dm $ENC0_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC0 << 16) | feat )))
  dm $ENC1_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC1 << 16) | feat )))
  SYNCMAX=${SYNCMAX:-6}
  # SENDCFG=once is mandatory at CT_XLEN=64: only from the config message does
  # the decoder read CAPS bit 23 and switch to 64 bit.
  base=$(( (0x01060063 & ~0x180) | (1 << 7) | 0x200 ))
  base=$(( base & ~0x8000 ))
  base=$(( (base & ~0x00F00000) | ((SYNCMAX & 0xF) << 20) ))
  ctrl_on=$(( base | 0x4 ))
  dm $ENC0 32 $(printf '0x%08x' $ctrl_on)
  dm $ENC1 32 $(printf '0x%08x' $ctrl_on)
  sleep 1
  echo "LIVE ENC_CTRL0 $(dm $ENC0) ENC_CTRL1 $(dm $ENC1) SYNCMAX=$SYNCMAX" >&2
  echo "LIVE FEAT0 $(dm $ENC0_FEAT) FEAT1 $(dm $ENC1_FEAT) (SrcID $SRC0/$SRC1)" >&2
  echo "LIVE SINK_CTRL $(dm $SINK_CTRL) (b0 DDR on, b2 circular, b3=0 URAM circular)" >&2
  echo "LIVE DDR base=$(dm $DDR_BASE) size=$(dm $DDR_SIZE) wptr=$(dm $DDR_WPTR)" >&2
  b1=$(( $(dm $TR_BYTES) )); sleep 2; b2=$(( $(dm $TR_BYTES) ))
  echo "LIVE TRACE_BYTES $b1 -> $b2 (+$((b2 - b1)) in 2 s)" >&2
  r0=$(( $(dm $RETIRES0) )); r1=$(( $(dm $RETIRES1) ))
  sleep 1
  r0b=$(( $(dm $RETIRES0) )); r1b=$(( $(dm $RETIRES1) ))
  echo "LIVE RETIRES hart0 +$((r0b - r0))  hart1 +$((r1b - r1))" >&2
  echo "LIVE STATUS $(dm $STATUS) FUNNEL_CTRL $(dm $FUNNEL_CTRL) CON_BYTES $(dm $CON_BYTES)" >&2
  # The evidence the display needs: is anything really flowing, and are BOTH
  # harts retiring? A still image would otherwise be indistinguishable from a
  # hanging core.
  # The DEFAULT SINK belongs in the gate. Without it, "DDR4 by default" would
  # be exactly the failure class that costs the most time: the setup loses data
  # without saying so. The comparison is on CHANGED, not on grown -- at 64 MiB
  # and ~22 MB/s the ring wraps in ~3 s.
  w1=$(dm $DDR_WPTR); sleep 1; w2=$(dm $DDR_WPTR)
  ddr_moves=0; [ "$w1" != "$w2" ] && ddr_moves=1
  echo "LIVE DDR_WPTR $w1 -> $w2 (moved=$ddr_moves)" >&2
  if [ "$((b2 - b1))" -gt 0 ] && [ "$((r0b - r0))" -gt 0 ] && [ "$((r1b - r1))" -gt 0 ] \
     && [ "$ddr_moves" -eq 1 ]; then
    echo "LIVE_OK -- stream running, both harts retiring, DDR4 writing" >&2
  else
    echo "LIVE_STALLED -- bytes+$((b2 - b1)) hart0+$((r0b - r0)) hart1+$((r1b - r1)) ddr=$ddr_moves" >&2
  fi
  echo "LIVE_DONE" >&2
  ;;
window)
  # ANOTHER trace window while the cores KEEP RUNNING (CTRL b0 stays
  # untouched). Needed for the case `start` cannot deliver:
  #
  #   `start` records from reset. In that phase hart 1 sits in the HSM wait
  #   loop of OpenSBI executing `wfi` -- so it retires almost nothing. A window
  #   meant to show the separation on TWO working harts has to lie AFTER the
  #   SMP boot, and by then the cores are already running.
  #
  # Same order as in `start`: empty the sink first (stale bytes!), then arm.
  if [ "$SINK" = "ddr" ]; then
    ddr_window_setup
    dm $SINK_CTRL 32 0x1
    prev=-1; i=0
    while [ $i -lt 20 ]; do
      sleep 0.2; cur=$(( $(dm $DDR_WPTR) ))
      [ "$cur" = "$prev" ] && break
      prev=$cur; i=$((i+1))
    done
    dm $SINK_CTRL 32 0x0
    echo "DRAIN $prev B after $i rounds" >&2
    dm $SINK_CTRL 32 0x2
    # Second place of the same trap -- see the detailed reasoning in `start`.
    # The residual surge only runs AFTER the clear; without this second
    # drain-and-clear every window carries a broken message at its start, and
    # the decoder aborts the whole run on it.
    dm $SINK_CTRL 32 0x1
    prev2=-1; j=0
    while [ $j -lt 20 ]; do
      sleep 0.2; cur=$(( $(dm $DDR_WPTR) ))
      [ "$cur" = "$prev2" ] && break
      prev2=$cur; j=$((j+1))
    done
    dm $SINK_CTRL 32 0x0
    echo "RECLEAR $prev2 B after $j rounds" >&2
    dm $SINK_CTRL 32 0x2
    w0=$(dm $DDR_WPTR)
    [ $(( w0 )) -eq 0 ] || { echo "M5_INVALID DDR_NOT_CLEARED ($w0)" >&2; exit 13; }
    dm $SINK_CTRL 32 0x1
  else
    # Clear ONLY the trace ring (b1). NOT 0x1E -- b0 has to stay set, otherwise
    # the core drops into reset in the middle of operation.
    dm $CTRL 32 0x3
    dm $CTRL 32 0x1
    dm $SINK_CTRL 32 0x8
  fi
  feat=0
  for ft in $(printf '%s' "${FEATURES:-}" | tr ',' ' '); do
    case "$ft" in
    ir) b=3 ;; bp) b=4 ;; jtc) b=5 ;; rh) b=8 ;;
    rb) b=11 ;; wideicnt) b=12 ;; ibhs) b=13 ;; ri) b=14 ;;
    *) echo "unknown FEATURE '$ft'" >&2; exit 2 ;;
    esac
    feat=$(( feat | (1 << b) ))
  done
  SRC0=${SRC0:-0}; SRC1=${SRC1:-1}
  dm $ENC0_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC0 << 16) | feat )))
  dm $ENC1_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC1 << 16) | feat )))
  SYNCMAX=${SYNCMAX:-6}
  base=$(( (0x01060063 & ~0x180) | (1 << 7) | 0x200 ))
  base=$(( base & ~0x8000 ))
  base=$(( (base & ~0x00F00000) | ((SYNCMAX & 0xF) << 20) ))
  r0a=$(( $(dm $RETIRES0) )); r1a=$(( $(dm $RETIRES1) ))
  dm $ENC0 32 $(printf '0x%08x' $(( base | 0x4 )))
  dm $ENC1 32 $(printf '0x%08x' $(( base | 0x4 )))
  echo "ENC_CTRL0 $(dm $ENC0) ENC_CTRL1 $(dm $ENC1) FEAT0 $(dm $ENC0_FEAT) FEAT1 $(dm $ENC1_FEAT)" >&2
  t0=$(date +%s%N)
  sleep ${RUNSEC:-0.2}
  dm $ENC0 32 $(printf '0x%08x' $base)
  dm $ENC1 32 $(printf '0x%08x' $base)
  t1=$(date +%s%N)
  sleep 0.2
  dm $ENC0 32 0x0
  dm $ENC1 32 0x0
  sleep 0.2
  [ "$SINK" = "ddr" ] && dm $SINK_CTRL 32 0x0
  r0b=$(( $(dm $RETIRES0) )); r1b=$(( $(dm $RETIRES1) ))
  echo "M5_WINDOW $LABEL SYNCMAX=$SYNCMAX RUNSEC=${RUNSEC:-0.2} us=$(( (t1 - t0) / 1000 ))" >&2
  # Retires IN THE WINDOW, not since the start. Only this difference answers
  # whether BOTH harts worked during THIS window.
  echo "M5_WIN_RETIRES hart0=+$(( r0b - r0a )) hart1=+$(( r1b - r1a ))" >&2
  echo "TRACE_BEATS $(dm $TR_BEATS) TRACE_BYTES $(dm $TR_BYTES) STATUS $(dm $STATUS)" >&2
  echo "DDR wptr=$(dm $DDR_WPTR) stat=$(dm $SINK_STAT) drops=$(dm $DDR_DROPS)" >&2
  st=$(( $(dm $SINK_STAT) ))
  [ $(( st & 0x1 )) -ne 0 ] && echo "M5_INVALID ddr_full -- shorten the window" >&2
  [ $(( st & 0x2 )) -ne 0 ] && echo "M5_INVALID ddr_axi_err" >&2
  [ $(( $(dm $DDR_DROPS) )) -ne 0 ] && echo "M5_INVALID DDR_DROPS" >&2
  echo "WINDOW_DONE" >&2
  ;;
load)
  # Keep both harts busy. Without load the second hart idles (wfi) and retires
  # nothing -- a window on that would show "hart 1 is not running" although it
  # simply has nothing to do.
  before=$(dm $CON_BYTES); before=$((before))
  dm $CON_RPTR 32 $(printf '0x%08x' $before)
  printf '%s\n' "${LOADCMD0:-while true; do :; done &}" \
                "${LOADCMD1:-while true; do :; done &}" \
                "nproc" "cat /proc/interrupts" |
  while IFS= read -r c; do
    type_line "$c"
    sleep 2
  done
  sleep 2
  now=$(dm $CON_BYTES); now=$((now))
  echo "CON_AFTER $now (+$((now - before))) DROPS $(dm $CON_DROPS)" >&2
  read_con "$now"
  diag_line
  echo "LOAD_DONE" >&2
  ;;
login)
  before=$(dm $CON_BYTES); before=$((before))
  dm $CON_RPTR 32 $(printf '0x%08x' $before)
  echo "CON_BEFORE $before RX_USED $(dm $CON_TX)" >&2
  type_line "${LOGIN:-root}"
  sleep 4
  echo "RX_USED after the login input: $(dm $CON_TX)  (0 = guest fetched everything)" >&2
  # One line per command -- NO "for c in $CMDS": word splitting would break
  # "uname -a" into two commands.
  printf '%s\n' "uname -a" "nproc" "cat /proc/cpuinfo" "cat /proc/interrupts" "echo M5_ENV_OK" |
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
    n=$(dm $DDR_WPTR); n=$((n))
    sz=$(dm $DDR_SIZE); sz=$((sz))
    [ "$n" -gt "$sz" ] && n=$sz
    src=$(dm $DDR_BASE)
  else
    n=$(dm $TR_BYTES); n=$((n))
    [ "$n" -gt 1048576 ] && n=1048576
    src=$TR_RING
  fi
  # Cap against an accidentally huge read. If it takes effect, that is SAID --
  # a silently truncated stream would have fewer bytes AND fewer instructions,
  # and every number computed from it would still look plausible.
  MAXB=${MAXB:-4194304}
  cap=0
  if [ "$n" -gt "$MAXB" ]; then n=$MAXB; cap=1; fi
  echo "TRACE_BYTES $n (beats=$(dm $TR_BEATS) status=$(dm $STATUS) sinkstat=$(dm $SINK_STAT) capped=$cap)" >&2
  [ "$n" -gt 0 ] && python3 /tmp/phys_io.py read $src $(( (n + 3) / 4 * 4 )) -o /tmp/r2_trace_$LABEL.bin
  echo "TRACEFILE $(ls -l /tmp/r2_trace_$LABEL.bin 2>/dev/null | awk '{print $5}')" >&2
  ;;
*)
  echo "unknown PHASE=$PHASE" >&2; exit 2 ;;
esac
