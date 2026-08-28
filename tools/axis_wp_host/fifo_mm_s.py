#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""fifo_mm_s.py -- RX backend for the AMD `axi_fifo_mm_s` (PG080) on the KV260.

Register map (PG080 v4.3, AXI4-Lite window; only the RX side is used,
TX registers are documented for completeness):

    0x00  ISR   Interrupt Status (W1C)
    0x04  IER   Interrupt Enable (stays 0 -- we poll)
    0x08  TDFR  Transmit FIFO Reset (Key 0xA5)          [TX, unused]
    0x0C  TDFV  Transmit FIFO Vacancy                   [TX, unused]
    0x10  TDFD  Transmit FIFO Data                      [TX, unused]
    0x14  TLR   Transmit Length                         [TX, unused]
    0x18  RDFR  Receive FIFO Reset  -- writing 0xA5 resets the RX side
    0x1C  RDFO  Receive FIFO Occupancy -- 32-bit words in the RX FIFO
    0x20  RDFD  Receive FIFO Data   -- every read pops ONE word
    0x24  RLR   Receive Length      -- bytes of the next packet
                (store-and-forward: only valid once the packet is
                 complete; cut-through: bit 31 = partial flag,
                 [30:0] = bytes so far)
    0x28  SRR   AXI4-Stream Reset (Key 0xA5, both sides)
    0x2C  TDR   Transmit Destination                    [TX, unused]
    0x30  RDR   Receive Destination (TDEST/TID of the packet)

Init behavior (F1, board finding G0 1a): `init()` by default attaches
NON-DESTRUCTIVELY -- only IER := 0 (polling contract; nothing is
discarded, RDFO/buffered records and the sticky ISR diagnostics are left
untouched). The PG080 RX reset (RDFR := 0xA5, then ISR := 0xFFFFFFFF W1C,
including the RRC "Receive Reset Complete", bit 23, that this sets) EMPTIES
the RX side and only runs on explicit request: constructor flag
`reset_on_init`, CLI `--reset`, or directly `reset_rx()`.

Access pattern (modeled on `tools/robustness/boardio.py` / `tools/phys_io.py`,
learned the expensive way on the board there -- COPIED HERE VERBATIM,
apply changes there first):
  * /dev/mem + mmap, page-aligned mapping (offset = page base).
  * Register accesses strictly as SINGLE 32-bit words via
    `ctypes.c_uint32.from_buffer` -- NO memcpy/slice: glibc NEON stores
    SIGBUS on Device-nGnRnE mappings, and byte-wise accesses produce
    partial strobes on registers with side effects (RDFD pops on every
    access!).

Base address/window size/register offsets are constructor parameters --
package D1 fixes the board addresses, nothing is hardcoded here.

Offline testability: `FifoMmS` takes any bus object with `r1(off) -> int`
and `write(off, val)` -- on the board `DevMemBus`, in the unit test a
FakeBus (see test_axis_wp_host.py). The read loop
(RDFO -> RLR -> RDFD, partial behavior) is thus testable without /dev/mem.
"""
from __future__ import annotations

import ctypes
import mmap
import os
import time

PAGE = 0x1000

# Register offsets (PG080) -- kept as a dict so D1 can inject a different
# window layout (e.g. a separate AXI4-Full data window for RDFD).
PG080_OFFSETS = {
    "ISR":  0x00,
    "IER":  0x04,
    "TDFR": 0x08,
    "TDFV": 0x0C,
    "TDFD": 0x10,
    "TLR":  0x14,
    "RDFR": 0x18,
    "RDFO": 0x1C,
    "RDFD": 0x20,
    "RLR":  0x24,
    "SRR":  0x28,
    "TDR":  0x2C,
    "RDR":  0x30,
}

RESET_KEY = 0xA5              # RDFR/TDFR/SRR key value
ISR_RRC = 0x00800000          # Bit 23: Receive Reset Complete
ISR_TRC = 0x01000000          # Bit 24: Transmit Reset Complete
ISR_RC = 0x04000000           # Bit 26: Receive Complete
ISR_RFPE = 0x00080000         # Bit 19: Rx FIFO Programmable Empty
RLR_PARTIAL = 0x80000000      # Cut-through: packet not yet complete


class DevMemBus:
    """32-bit word access to ONE PL register window via /dev/mem.

    Modeled on `tools/robustness/boardio.py::HwBus` (one mmap, ctypes
    words), here as a single-region variant without a thread lock (the
    reader is a batch tool). Usable only on Linux with root; the unit
    tests never instantiate this class.
    """

    def __init__(self, base: int, size: int = PAGE):
        page = base & ~(PAGE - 1)
        self._off = base - page
        mlen = (self._off + size + PAGE - 1) & ~(PAGE - 1)
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        try:
            self.m = mmap.mmap(self.fd, mlen, mmap.MAP_SHARED,
                               mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
        except Exception:
            os.close(self.fd)
            raise

    def r1(self, off: int) -> int:
        return ctypes.c_uint32.from_buffer(self.m, self._off + off).value

    def write(self, off: int, value: int) -> None:
        ctypes.c_uint32.from_buffer(self.m, self._off + off).value = \
            value & 0xFFFFFFFF

    def close(self) -> None:
        try:
            self.m.close()
        except (BufferError, ValueError):
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


class DrainStats:
    __slots__ = ("n_packets", "n_words", "n_partial", "n_zero_len", "n_polls")

    def __init__(self):
        self.n_packets = 0
        self.n_words = 0
        self.n_partial = 0     # RLR reported more words than RDFO provided
        self.n_zero_len = 0    # RLR == 0 despite occupancy (ended defensively)
        self.n_polls = 0       # empty windows in drain_poll (empty polls)


class FifoMmS:
    """`axi_fifo_mm_s` RX side: init + packet read loop (reset explicit)."""

    def __init__(self, bus, offsets=None, reset_on_init=False):
        self.bus = bus
        self.reg = dict(PG080_OFFSETS)
        if offsets:
            self.reg.update(offsets)
        self.reset_on_init = bool(reset_on_init)

    # -- Init -----------------------------------------------------------

    def reset_rx(self) -> None:
        """RX reset per PG080: RDFR := key, then fully W1C-clear ISR.

        DESTRUCTIVE: discards all buffered records (G0 finding 1a) --
        never call implicitly, only via `reset_on_init`/CLI `--reset`.
        """
        self.bus.write(self.reg["RDFR"], RESET_KEY)
        self.bus.write(self.reg["ISR"], 0xFFFFFFFF)

    def init(self) -> None:
        """Polled-mode init: IER := 0. Non-destructive by default.

        Buffered records, RDFO, and the sticky ISR diagnostics are left
        untouched (attaching to a running stream); the destructive RX
        reset only runs with `reset_on_init=True` (constructor flag).
        """
        self.bus.write(self.reg["IER"], 0)
        if self.reset_on_init:
            self.reset_rx()

    # -- Status -----------------------------------------------------------

    def isr(self) -> int:
        return self.bus.r1(self.reg["ISR"])

    def rx_occupancy(self) -> int:
        """RDFO: 32-bit words currently available in the RX FIFO."""
        return self.bus.r1(self.reg["RDFO"])

    # -- Reading ------------------------------------------------------------

    def read_packet(self, stats: DrainStats):
        """Read ONE packet (RDFO -> RLR -> n x RDFD). None if empty.

        Partial behavior: if RLR reports more words than RDFO provides
        (cut-through partial flag, or an inconsistent state), only the
        available words are read and `n_partial` counts it -- RDFD is
        never read beyond the occupancy (that would set the underflow
        sticky ISR[RPURE/RPORE] and return garbage).
        """
        occ = self.rx_occupancy()
        if occ == 0:
            return None
        rlr = self.bus.r1(self.reg["RLR"])
        length = rlr & ~RLR_PARTIAL
        nwords = (length + 3) // 4
        if nwords == 0:
            stats.n_zero_len += 1
            return None
        if (rlr & RLR_PARTIAL) or nwords > occ:
            stats.n_partial += 1
            nwords = min(nwords, occ)
        words = [self.bus.r1(self.reg["RDFD"]) for _ in range(nwords)]
        stats.n_packets += 1
        stats.n_words += len(words)
        return words

    def drain(self, max_packets: int = 0):
        """Read all currently available packets -> (flat word list, DrainStats).

        max_packets = 0: until the FIFO is empty. The flat word list goes
        straight into `wp_records.parse_words` (1 packet == 1 record == 4
        words; a partial packet then shows up there as a malformed
        remainder).
        """
        stats = DrainStats()
        words = []
        while not max_packets or stats.n_packets < max_packets:
            pkt = self.read_packet(stats)
            if pkt is None:
                break
            words.extend(pkt)
        return words, stats

    def drain_poll(self, poll_s: float = 0.010, duration_s=None,
                   max_records: int = 0, stop=None,
                   sleep=time.sleep, clock=time.monotonic):
        """Long-run drain: polls across empty windows (G0 finding 1b).

        Unlike `drain()`, an empty RDFO does NOT end the loop -- it
        sleeps `poll_s` and keeps polling (`n_polls` counts the empty
        windows). END CONDITIONS (documented contract):
          * `max_records > 0`  -> ends once that many records (packets)
                                  have been read;
          * `stop()` truthy    -> cooperative abort (the CLI wires
                                  SIGINT/SIGTERM to this); the backlog
                                  already available at the time of the
                                  abort is still drained completely;
          * `duration_s`       -> ends once the time budget elapses
                                  (measured with `clock`, checked after
                                  every drained window);
          * none of the three  -> runs FOREVER (deliberate: continuous
                                  operation).
        `sleep`/`clock` are injectable so the offline tests run without
        actually sleeping. Return value same as `drain()`.
        """
        stats = DrainStats()
        words = []
        t0 = clock()
        while True:
            while not max_records or stats.n_packets < max_records:
                pkt = self.read_packet(stats)
                if pkt is None:
                    break
                words.extend(pkt)
            if max_records and stats.n_packets >= max_records:
                break
            if stop is not None and stop():
                break
            if duration_s is not None and clock() - t0 >= duration_s:
                break
            stats.n_polls += 1
            sleep(poll_s)
        return words, stats


def open_devmem_fifo(base: int, size: int = PAGE, offsets=None,
                     reset_on_init: bool = False) -> FifoMmS:
    """Board convenience: open a /dev/mem bus at `base` + FifoMmS on top of it."""
    return FifoMmS(DevMemBus(base, size), offsets, reset_on_init=reset_on_init)
