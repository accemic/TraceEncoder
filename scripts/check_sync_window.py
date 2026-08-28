# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Byte-quota window check on a RAW ATB capture (P2 stage 4, test 29).

Frames the raw ATB byte stream (MDO/MSEO) itself, extracts the raw byte
offset of every synchronization message and HARD-checks that the maximum
distance between consecutive sync-message start offsets is

    max_gap  <=  2^(InstSyncMax + 4)  +  DELTA

MEASUREMENT CONTRACT -- raw output beats, NOT decoder log lines.  The
quota counted by the encoder is defined by the RDL
(`rdl/ct_cs_cpuif.rdl`, `ITR_SYNC_TRACE_BYTES`): "trace bytes as accepted
on the ATB output: whole output beats, so alignment padding and flush
idle beats count toward the quota".  That is exactly what a live/ring
consumer cuts its window out of, so it is the only scale on which the
window guarantee may be measured.

  Why not the NexRv `-full` log (the scale used until 2026-08-04):
  `NexRv -deco -full` echoes every accepted byte on its own ". 0x" line
  BUT COLLAPSES A RUN OF CONSECUTIVE IDLE BYTES INTO A SINGLE LINE.
  Log-line distances are therefore systematically TOO SMALL.  Proven
  bit-exactly on the test-29 capture: the log's ". 0x" value sequence is
  the raw byte sequence with every 0xFF run replaced by one 0xFF
  (1100 raw bytes -> 894 log lines; 335 idle bytes in 129 runs => 206
  bytes swallowed).  Use `--log` below to keep the decoder as a
  cross-check on message CLASSIFICATION, never as the byte scale.

Framing rules (IEEE-ISTO 5001 MSEO, `nexus_vendor_riscv_pkg.sv:415-424`):
  * a message ends with the first byte carrying MSEO[1:0] = 11,
  * an idle / alignment-pad byte is the whole byte 0xFF (MDO = 111111,
    MSEO = 11) and is NOT a message -- it is counted, not framed,
  * the first byte of a message carries TCODE[5:0] in MDO with MSEO = 00
    (a start byte can therefore never be 0xFF).
The input buffer must START ON A MESSAGE BOUNDARY: the simulation ATB
dumps do by construction (stream start); ring/window cuts are aligned by
the consumer first (`insight.align_to_messages`, identical rule).

Sync classification is by TCODE, mirroring `TcodeIsSync()`
(`nexus_vendor_riscv_pkg.sv:507-520`) and the "*Sync" message names of
the reference decoder (`NexRvMsg.h`):
  9 ProgTraceSync, 11 DirectBranchSync, 12 IndirectBranchSync,
  29 IndirectBranchHistSync, 32 RepeatInstructionSync   -> re-anchor the
  PROGRAM flow; these are the anchors the window bound is about.
  13 DataWriteSync, 14 DataReadSync (CT_EN_DF_ADDR_COMPRESS) re-anchor
  only the data reference -- they are part of the decoder's "*Sync"
  label class (and thus of the `--log` cross-check) but are NOT counted
  as window anchors.

DELTA derivation (D2/D7; documented numbers for the ct_env clocking:
tip_clk 10 ns, proc/atb_clk 4 ns, ATB ceiling rate 4 B/beat / 4 ns
= 1 B/ns; vector_cdc2 req-ack handshake worst-case transfer latency
~ 3 dest + 3 src + 3 dest cycles):

  The egress counter counts accepted beats in proc_clk (D2, packer_wr);
  the sync generator lives in tip_clk. Between the counter crossing its
  threshold and the resulting PERIODIC sync message appearing in the byte
  stream, and again while the SyncCntClr rearm round-trips, the stream
  keeps flowing -- those in-flight bytes stretch the observed window
  beyond the programmed quota:

    detect path   level CDC in (proc->tip:  3*10 + 3*4 + 3*10 = 72 ns)
                  + periodic-arm decision            ~ 1 tip =  10 ns
                  + anchor wait (BP off: next retire @ CPI=2) = 20 ns
                                                       subtotal 102 ns
    rearm dead    clr CDC out (tip->proc: 3*4 + 3*10 + 3*4 =    54 ns)
    time          + level-drop CDC back (proc->tip)  =          72 ns
    (counter      + SyncCntClr release                ~ 1 tip = 10 ns
    holds 0 /     + clr-fall CDC out                 =          54 ns
    not counting)                                      subtotal 190 ns

    bytes  = (102 + 190) ns * 1 B/ns (ATB ceiling)  =  292 B
    + CDC-FIFO / composer-formatter queue jitter    =   32 B  (FIFO depth)
    ------------------------------------------------------------------
    DELTA                                           =  324 B

  1 B/ns is the ATB CEILING, not a sustained encoder rate -- the measured
  maximum (printed below) is the honest number for the docs; the bound is
  the never-exceed gate. A dead rearm (no SyncCntClr crossing) or a dead
  quota makes the gap grow with the stream length and fails hard.

Usage:  py scripts/check_sync_window.py <atb_bin> <InstSyncMax> [DELTA]
                                        [--log <nexrv_full_log>]
Exit 0 iff the bound holds, >= 2 sync messages were found and (with
--log) the raw framing agrees with the decoder on the sync-message count.
"""

import re
import sys

DELTA_DEFAULT = 324  # bytes; derivation above

IDLE_BYTE = 0xFF
MSEO_MASK = 0x3
MSEO_END = 0x3

# TCODEs that re-anchor the program flow (window anchors, see above).
ANCHOR_TCODES = frozenset({9, 11, 12, 29, 32})
# The decoder's full "*Sync" label class = anchors + the data-trace forms.
LOG_SYNC_TCODES = ANCHOR_TCODES | frozenset({13, 14})

BYTE_RE = re.compile(r"^\. 0x")
SYNC_RE = re.compile(r"TCODE\[6\]=\d+.*Sync")


def frame_messages(buf):
    """Frame a message-aligned raw ATB buffer.

    Returns (messages, idle_bytes, truncated_tail) with
    messages = [(raw_start_offset, tcode, length), ...].
    """
    msgs = []
    idle = 0
    trunc = 0
    i = 0
    n = len(buf)
    while i < n:
        if buf[i] == IDLE_BYTE:          # idle filler / alignment pad
            idle += 1
            i += 1
            continue
        start = i
        tcode = buf[i] >> 2
        while i < n and (buf[i] & MSEO_MASK) != MSEO_END:
            i += 1
        if i >= n:                       # cut capture: incomplete last message
            trunc = n - start
            break
        i += 1
        msgs.append((start, tcode, i - start))
    return msgs, idle, trunc


def count_log_syncs(path):
    """Sync messages as the reference decoder labels them ("*Sync")."""
    n = 0
    with open(path, "r", errors="replace") as f:
        for line in f:
            if BYTE_RE.match(line) and SYNC_RE.search(line):
                n += 1
    return n


def main() -> int:
    argv = [a for a in sys.argv[1:]]
    log_path = None
    if "--log" in argv:
        k = argv.index("--log")
        if k + 1 >= len(argv):
            print(__doc__)
            return 2
        log_path = argv[k + 1]
        del argv[k:k + 2]
    if len(argv) < 2:
        print(__doc__)
        return 2
    bin_path = argv[0]
    sync_max = int(argv[1])
    delta = int(argv[2]) if len(argv) > 2 else DELTA_DEFAULT
    quota = 1 << (sync_max + 4)
    bound = quota + delta

    with open(bin_path, "rb") as f:
        raw = f.read()
    msgs, idle, trunc = frame_messages(raw)
    offsets = [m[0] for m in msgs if m[1] in ANCHOR_TCODES]
    label_syncs = [m for m in msgs if m[1] in LOG_SYNC_TCODES]
    sync_bytes = sum(m[2] for m in label_syncs)

    print(f"[sync-window] {bin_path}: {len(raw)} raw ATB bytes "
          f"({len(msgs)} messages, {idle} idle/pad bytes"
          f"{', %d B truncated tail' % trunc if trunc else ''}), "
          f"{len(offsets)} sync messages, quota 2^({sync_max}+4)={quota} B, "
          f"bound {quota}+{delta}={bound} B")

    if log_path is not None:
        n_log = count_log_syncs(log_path)
        ok = (n_log == len(label_syncs))
        print(f"[sync-window] decoder cross-check: raw framing {len(label_syncs)} "
              f"*Sync message(s) vs. NexRv log {n_log} -- "
              f"{'OK' if ok else 'MISMATCH'}")
        if not ok:
            print("[sync-window] FAIL -- raw framing disagrees with the "
                  "decoder on the sync-message class")
            return 1

    if len(offsets) < 2:
        print("[sync-window] FAIL -- fewer than 2 sync messages (quota dead?)")
        return 1

    gaps = [b - a for a, b in zip(offsets, offsets[1:])]
    max_gap = max(gaps)
    print(f"[sync-window] measured distances: n={len(gaps)} "
          f"min={min(gaps)} max={max_gap} B "
          f"(sync offsets {offsets[0]}..{offsets[-1]}, "
          f"sync overhead {100.0 * sync_bytes / len(raw):.3f} % = "
          f"{sync_bytes}/{len(raw)} B)")
    if max_gap > bound:
        worst = gaps.index(max_gap)
        print(f"[sync-window] FAIL -- max gap {max_gap} B > bound {bound} B "
              f"(between sync #{worst} @ {offsets[worst]} and "
              f"#{worst + 1} @ {offsets[worst + 1]})")
        return 1
    print(f"[sync-window] PASS -- max re-anchor distance {max_gap} B "
          f"<= {bound} B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
