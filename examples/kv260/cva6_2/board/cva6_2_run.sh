#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# cva6_2_run.sh -- board sequence for the two-core AMP CVA6 demonstrator.
# RUNS ON THE BOARD.
#
#   sudo PHASE=prep  PAYLOAD0=... PAYLOAD1=... sh cva6_2_run.sh
#   sudo PHASE=start RUNSEC=3 sh cva6_2_run.sh
#   sudo PHASE=start TRACE_DELAY=2 RUNSEC=1 sh cva6_2_run.sh   # a LATER window
#   sudo PHASE=con   sh cva6_2_run.sh          # console ring -> /tmp/c2_con.bin
#   sudo PHASE=trace sh cva6_2_run.sh          # trace ring   -> /tmp/c2_trace.bin
#
# AMP, NOT SMP -- and that is why there are TWO payloads. Each core owns a
# private 32 MiB window (core 0 at 0x6400_0000, core 1 at 0x6600_0000) and
# runs its own Linux; the only shared byte range is the UNCACHED mailbox at
# 0x6800_0000. Two cores on one cached window would be incoherent in this
# build (no L1 coherence path compiled in), and the failure mode would be
# silent data corruption -- see rtl/cva6_2_soc_top.sv's header.
#
# The two guest images differ ONLY in their load address and their device
# tree's memory node; build both with sw/build_payload_cva6_2.sh.
#
# SENDCFG IS MANDATORY HERE. This build carries the 64-bit encoder, and the
# decoder learns its address width from the configuration message alone
# (CAPS bit 23). Without it the stream folds the index at bit 25 and the
# decode aborts -- so the script refuses SENDCFG=none instead of producing
# an undecodable capture.
#
# Register map: rtl/cva6_2_soc_top.sv header (congruent with rocket2).
set -u

CTRL=0xA0000000
STATUS=0xA0000004
TRACE_BYTES=0xA000000C
CON_BYTES=0xA0000014
SINK_CTRL=0xA000001C
FUNNEL_CTRL=0xA0000058
PC_LO=0xA000004C
RETIRES=0xA0000054
RETIRES1=0xA0000064
ENC0=0xA0010000
ENC0_FEAT=0xA0010008
ENC1=0xA0020000
ENC1_FEAT=0xA0020008
TR_RING=0xA0200000
CON_RING=0xA0300000

GUEST0=${GUEST0:-0x64000000}
GUEST1=${GUEST1:-0x66000000}
PAYLOAD0=${PAYLOAD0:-/tmp/fw_payload_cva6_2_core0.bin}
PAYLOAD1=${PAYLOAD1:-/tmp/fw_payload_cva6_2_core1.bin}
PHYS_IO=${PHYS_IO:-/tmp/phys_io.py}
PLCLK=${PLCLK:-/tmp/kv260_plclk.sh}
PHASE=${PHASE:-prep}
RUNSEC=${RUNSEC:-3}
PL_MHZ=${PL_MHZ:-75}

dm() { busybox devmem "$@"; }

plclk_gate() {
	[ "$PL_MHZ" = "skip" ] && return 0
	_cur=$(dm 0xFF5E00C0)
	_d0=$(( (_cur >> 8) & 0x3F ))
	_d1=$(( (_cur >> 16) & 0x3F ))
	[ "$_d0" -eq 0 ] && return 1
	[ "$_d1" -eq 0 ] && _d1=1
	_hz=$(( 1500000000 / _d0 / _d1 ))
	_want=$(( PL_MHZ * 1000000 ))
	# 68 MHz is a LABEL: 1500/22 = 68181818 Hz, not 68000000.
	[ "$PL_MHZ" = "68" ] && _want=68181818
	if [ "$_hz" -eq "$_want" ]; then
		echo "PLCLK OK: pl_clk0 = $_hz Hz" >&2
		return 0
	fi
	echo "PLCLK_WRONG: pl_clk0 = $_hz Hz, want $_want Hz." >&2
	echo "  The change belongs BETWEEN unloadapp and loadapp -- a frequency" >&2
	echo "  step under a running design is a clock glitch inside the logic." >&2
	echo "  Run: sudo MHZ=$PL_MHZ sh $PLCLK  with the PL unloaded." >&2
	return 9
}

case "$PHASE" in
prep)
	plclk_gate || exit 9
	# PS AFIFM port widths. Reset is 128 bit and `psu_init` -- which would
	# set them -- does not run for a DFX app, so this has to happen once per
	# boot.
	#
	# THE ADDRESSES MATTER AND I GOT THEM WRONG ONCE (2026-08-19). The first
	# version of this script wrote 0xFD36_xxxx / 0xFD37_xxxx and labelled
	# them "HP0/HP1". Those are AFIFM0 and AFIFM1 = HPC0/HPC1, which this
	# bitstream does not even enable. The ports actually used are AFIFM2
	# (saxigp2, trace sink) and AFIFM3 (saxigp3, guest memory) --
	# 0xFD38_xxxx and 0xFD39_xxxx, exactly as the boot recipes under
	# examples/dashboard/boot/ have always had it.
	#
	# The cost of the wrong address was not an error message: the trace sink
	# then writes 32-bit beats into a port that presents 128 bit, so ONE word
	# lands per 16-byte slot and the capture is unreadable while every
	# counter looks healthy (0 drops). Measured and fixed the same day --
	# with 0xFD38_0014 set to 32 bit the same run decodes 4,209,664
	# instructions with zero error messages.
	#
	# ONE PORT FURTHER OUT (2026-08-21) -- and this one was the whole story.
	# Every board recipe in this repository configures TWO ports, because every
	# other design has one core and therefore one guest window. THIS design has
	# two cores with a private PS port each (header of cva6_2_mem_xbar.sv):
	# core 0 on saxigp3, core 1 on **saxigp4** = AFIFM4 @0xFD3A_0000. That port
	# was never touched and stayed at its 128-bit reset value, and core 1 could
	# not write at all: no store ever reached DDR, and the window guard reported
	# nothing, because the accesses never got that far. Its READ path was
	# unaffected -- core 1 fetches and retires from its window either way, which
	# is why it looked alive for two days.
	#
	# The first operation that WAITS for its answer is OpenSBI's boot lottery,
	# `amoswap.w` on _fw_rw_start, the 15th instruction after reset. It never
	# returned, and the core stood there with RETIRES=14 forever.
	#
	# One-variable discrimination, from a power-cycled board:
	#   AFIFM4 at reset (0x3B0) -> RETIRES1 = 14, PC1 = 0x6400_0032, one guest
	#   AFIFM4 width 64         -> BOTH guests boot to `buildroot login:`
	#                              (RETIRES 544,507,540 / 542,494,739, both PCs
	#                              in the kernel idle loop, 22,389 bytes of
	#                              console, 0 drops, both window guards 0)
	# Reproduced four times; the reverse case reproduced as well.
	#
	afifm_width 0xFD380000 2   # AFIFM2 = saxigp2, trace sink   -> 32 bit
	afifm_width 0xFD390000 1   # AFIFM3 = saxigp3, core 0 RAM   -> 64 bit
	afifm_width 0xFD3A0000 1   # AFIFM4 = saxigp4, core 1 RAM   -> 64 bit
	echo "AFIFM2=$(dm 0xFD380000)/$(dm 0xFD380014) AFIFM3=$(dm 0xFD390000)/$(dm 0xFD390014) AFIFM4=$(dm 0xFD3A0000)/$(dm 0xFD3A0014)" >&2
	# Hold both cores, clear both rings, before anything is written.
	dm $CTRL 32 0x00000006
	dm $CTRL 32 0x00000000
	rc=0
	for pair in "0 $GUEST0 $PAYLOAD0" "1 $GUEST1 $PAYLOAD1"; do
		set -- $pair
		c=$1; addr=$2; file=$3
		[ -f "$file" ] || { echo "PAYLOAD_MISSING core$c: $file" >&2; exit 3; }
		sz=$(stat -c%s "$file")
		# The image must FIT between the two windows, or writing the second
		# one silently destroys the tail of the first. Refuse instead of
		# producing two images of which one is quietly wrong.
		span=$(( GUEST1 - GUEST0 ))
		if [ "$sz" -gt "$span" ]; then
			echo "IMAGE_TOO_LARGE core$c: $sz B > window spacing $span B" >&2
			echo "  Writing both images would overlap by $(( sz - span )) B." >&2
			echo "  Shrink the guest image or widen the windows (DRAM_SIZE in" >&2
			echo "  rtl/cva6_2_soc_top.sv) -- both are decisions, see" >&2
			echo "  docs/FINDINGS_board_wedge_20260818.md." >&2
			exit 7
		fi
		src=$(md5sum "$file" | cut -d' ' -f1)
		echo "PAYLOAD core$c $file $sz B md5=$src -> $addr" >&2
		python3 "$PHYS_IO" write "$addr" "$file" || exit 4
		python3 "$PHYS_IO" read "$addr" "$sz" -o /tmp/c2_rb.bin || exit 4
		tgt=$(md5sum /tmp/c2_rb.bin | cut -d' ' -f1)
		rm -f /tmp/c2_rb.bin
		if [ "$src" = "$tgt" ]; then
			echo "VERIFY core$c OK md5=$tgt" >&2
		else
			echo "VERIFY core$c MISMATCH src=$src target=$tgt" >&2; rc=5
		fi
	done
	[ $rc -eq 0 ] || exit $rc

	# RE-VERIFY CORE 0 *AFTER* CORE 1 HAS BEEN WRITTEN.
	#
	# The per-image check above runs right after each write, so core 0 is
	# verified BEFORE core 1 exists. That is exactly the window in which the
	# following can happen and did (2026-08-19): the two PS windows are
	# 32 MiB apart, the guest image is 33.1 MiB, so writing core 1 lands on
	# top of the last 1.1 MiB of core 0. Both per-image checks report OK, and
	# one of the two images is destroyed anyway.
	#
	# Measured: md5 of core 0 read back after a full prep differs from the
	# source, and the first differing byte sits at offset 0x0200_0000 --
	# exactly the window boundary.
	sz0=$(stat -c%s "$PAYLOAD0")
	src0=$(md5sum "$PAYLOAD0" | cut -d' ' -f1)
	python3 "$PHYS_IO" read "$GUEST0" "$sz0" -o /tmp/c2_rb0.bin || exit 4
	tgt0=$(md5sum /tmp/c2_rb0.bin | cut -d' ' -f1)
	rm -f /tmp/c2_rb0.bin
	if [ "$src0" != "$tgt0" ]; then
		echo "RECHECK core0 FAILED after writing core1: $src0 != $tgt0" >&2
		echo "  The images overlap. Window spacing is $(( (GUEST1 - GUEST0) / 1048576 )) MiB," >&2
		echo "  the image is $(( sz0 / 1048576 )) MiB. Shrink the guest image or" >&2
		echo "  widen the windows -- see docs/FINDINGS_board_wedge_20260818.md." >&2
		exit 6
	fi
	echo "RECHECK core0 OK after writing core1 (md5=$tgt0)" >&2
	echo "PREP_DONE" >&2
	;;
start)
	plclk_gate || exit 9
	SENDCFG=${SENDCFG:-once}
	SYNCMAX=${SYNCMAX:-6}
	SRC0=${SRC0:-0}; SRC1=${SRC1:-1}
	case "$SENDCFG" in
	none) echo "SENDCFG_REQUIRED: CT_XLEN=64 -- without the configuration" >&2
	      echo "  message the stream is not decodable (SENDCFG=once)." >&2; exit 10 ;;
	once) cfg=1 ;;
	onsync) cfg=2 ;;
	*) echo "unknown SENDCFG=$SENDCFG (once|onsync)" >&2; exit 2 ;;
	esac
	# URAM one-shot: the FIRST 1 MiB, which is the boot from reset.
	dm $SINK_CTRL 32 0x8
	dm $ENC0_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC0 << 16) )))
	dm $ENC1_FEAT 32 $(printf '0x%08x' $(( 0x20000000 | (SRC1 << 16) )))
	# trTeControl: b0 Active, b1 Enable, b2 InstTracing, [6:4] InstMode,
	# [8:7] SendConfig, b9 Context, b15 InhibitSrc, [19:16] InstSyncMode,
	# [23:20] InstSyncMax, [26:24] Format.
	base=$(( (0x01060063 & ~0x180) | (cfg << 7) | 0x200 ))
	base=$(( base & ~0x8000 ))
	base=$(( (base & ~0x00F00000) | ((SYNCMAX & 0xF) << 20) ))
	ctrl_on=$(( base | 0x4 ))
	# TRACE_DELAY: record a LATER window instead of the first one. The URAM
	# ring is a 1 MiB one-shot and fills in a fraction of a second, so a
	# plain run always shows the same opening phase -- useless when the
	# question is where execution ENDS. With a delay the cores run first and
	# the encoder is armed afterwards, so the ring holds the window around
	# that moment. Added 2026-08-19 while chasing the AMP guest's hang: the
	# first window ends inside OpenSBI's device-tree scan, which says where
	# it WAS, not where it stopped.
	TRACE_DELAY=${TRACE_DELAY:-0}
	if [ "$TRACE_DELAY" != "0" ]; then
		dm $CTRL 32 0x00000001
		echo "CORES_STARTED $(dm $CTRL) -- arming the encoders in ${TRACE_DELAY}s" >&2
		sleep "$TRACE_DELAY"
		dm $ENC0 32 $(printf '0x%08x' $ctrl_on)
		dm $ENC1 32 $(printf '0x%08x' $ctrl_on)
		echo "ENC0 $(dm $ENC0) ENC1 $(dm $ENC1) (armed after ${TRACE_DELAY}s)" >&2
	else
		dm $ENC0 32 $(printf '0x%08x' $ctrl_on)
		dm $ENC1 32 $(printf '0x%08x' $ctrl_on)
		echo "ENC0 $(dm $ENC0) ENC1 $(dm $ENC1) FEAT0 $(dm $ENC0_FEAT) FEAT1 $(dm $ENC1_FEAT)" >&2
		dm $CTRL 32 0x00000001
		echo "CORES_STARTED $(dm $CTRL)" >&2
	fi
	echo "SENDCFG=$SENDCFG SYNCMAX=$SYNCMAX (sync every $(( 1 << (SYNCMAX + 4) )) instr)" >&2
	sleep "$RUNSEC"
	echo "TRACE_BYTES $(dm $TRACE_BYTES) CON_BYTES $(dm $CON_BYTES) STATUS $(dm $STATUS)" >&2
	echo "RETIRES core0=$(dm $RETIRES) core1=$(dm $RETIRES1) PC0=$(dm $PC_LO)" >&2
	echo "START_DONE" >&2
	;;
con)
	n=$(dm $CON_BYTES)
	n=$(( n ))
	[ "$n" -gt 0 ] && python3 "$PHYS_IO" read $CON_RING $(( (n + 3) / 4 * 4 )) -o /tmp/c2_con.bin
	echo "CONFILE $(stat -c%s /tmp/c2_con.bin 2>/dev/null) (ring level $n)" >&2
	;;
trace)
	n=$(dm $TRACE_BYTES)
	n=$(( n ))
	[ "$n" -gt 1048576 ] && n=1048576
	[ "$n" -gt 0 ] && python3 "$PHYS_IO" read $TR_RING $(( (n + 3) / 4 * 4 )) -o /tmp/c2_trace.bin
	echo "TRACEFILE $(stat -c%s /tmp/c2_trace.bin 2>/dev/null) (TRACE_BYTES $n)" >&2
	;;
*)
	echo "unknown PHASE=$PHASE (prep|start|con|trace)" >&2; exit 2 ;;
esac
