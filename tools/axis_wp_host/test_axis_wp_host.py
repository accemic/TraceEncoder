#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""test_axis_wp_host.py -- unit tests for the F0 host reader (plain asserts).

Run:  py tools/axis_wp_host/test_axis_wp_host.py
Gate: last line `F0_ALL_PASS` + counter.

No pytest required; every test_* function is called directly.
The FakeBus emulates the axi_fifo_mm_s RX register semantics (RDFO counts
words, RLR pops the length of the next packet, RDFD pops one word per
read, RDFR/ISR like PG080) and logs every access in order.
"""
from __future__ import annotations

import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import checks
import fifo_mm_s
import read_wp_stream
import wp_records
from fifo_mm_s import PG080_OFFSETS as REG


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def rec_words(pc, direct=0, ts=0, core=0, tid=0x2A, tstrb=0xFFF, resv=0):
    """Build a 4-word record following the D0 layout (resv = W3[31:24])."""
    w3 = ((resv & 0xFF) << 24) | ((core & 0xF) << 20) | \
         ((tstrb & 0xFFF) << 8) | (tid & 0xFF)
    return [pc & 0xFFFFFFFF, direct & 0xFFFFFFFF, ts & 0xFFFFFFFF, w3]


def stream(*recs):
    words = []
    for r in recs:
        words += r
    return words


def parse(*recs):
    return wp_records.parse_words(stream(*recs))


class FakeBus:
    """Register semantics of the axi_fifo_mm_s (RX side) for offline tests.

    `data` = flat word FIFO, `lengths` = length FIFO (bytes per packet,
    optionally with the RLR_PARTIAL bit set for the cut-through case).
    Every access lands in `log` -- the tests use it to check the
    RDFO->RLR->RDFD sequence.
    """

    def __init__(self, packets=(), lengths=None):
        self.data = []
        self.lengths = []
        for p in packets:
            self.data += list(p)
            self.lengths.append(4 * len(p))
        if lengths is not None:
            self.lengths = list(lengths)
        self.regs = {REG["ISR"]: 0, REG["IER"]: 0}
        self.log = []

    def r1(self, off):
        self.log.append(("r", off))
        if off == REG["RDFO"]:
            return len(self.data)
        if off == REG["RLR"]:
            return self.lengths.pop(0) if self.lengths else 0
        if off == REG["RDFD"]:
            assert self.data, "RDFD read on an empty FIFO (underflow!)"
            return self.data.pop(0)
        return self.regs.get(off, 0)

    def write(self, off, val):
        self.log.append(("w", off, val))
        if off == REG["RDFR"]:
            assert val == fifo_mm_s.RESET_KEY, "RDFR without key 0xA5"
            self.data = []
            self.lengths = []
            self.regs[REG["ISR"]] |= fifo_mm_s.ISR_RRC
        elif off == REG["ISR"]:
            self.regs[REG["ISR"]] &= ~val            # W1C
        else:
            self.regs[off] = val & 0xFFFFFFFF


# ---------------------------------------------------------------------------
# wp_records
# ---------------------------------------------------------------------------

def test_parse_fields():
    res = parse(rec_words(0x80000124, direct=0xDEAD0001, ts=0x42,
                          core=3, tid=0x11, tstrb=0xFFF))
    assert res.n_records == 1 and res.n_valid == 1
    r = res.records[0]
    assert r.pc == 0x80000124 and r.direct == 0xDEAD0001 and r.ts == 0x42
    assert r.core_id == 3 and r.tid == 0x11 and r.tstrb == 0xFFF
    assert r.valid and r.errors == []


def test_parse_bytes_roundtrip():
    words = stream(rec_words(0x100, ts=1), rec_words(0x104, ts=2, core=1))
    data = struct.pack("<%dI" % len(words), *words)
    res = wp_records.parse_bytes(data)
    assert res.n_records == 2 and res.n_valid == 2
    assert res.records[1].core_id == 1
    assert res.n_malformed_words == 0 and res.n_malformed_bytes == 0


def test_w3_reserved_bits():
    res = parse(rec_words(0x100, ts=1, resv=0x80))
    assert res.n_invalid == 1
    assert any("W3[31:24]" in e for e in res.records[0].errors)


def test_tstrb_plausibility():
    # partial strobe within element 0 -> invalid
    res = parse(rec_words(0x100, ts=1, tstrb=0xFFE))
    assert res.n_invalid == 1
    assert any("partial" in e for e in res.records[0].errors)
    # PC element completely absent -> invalid
    res = parse(rec_words(0x100, ts=1, tstrb=0xFF0))
    assert res.n_invalid == 1
    assert any("PC element absent" in e for e in res.records[0].errors)
    # only the PC element (0x00F) is plausible (e.g. without CT_EN_AXIS_TS)
    res = parse(rec_words(0x100, ts=1, tstrb=0x00F))
    assert res.n_valid == 1


def test_malformed_tail_words():
    for extra in (1, 2, 3):
        words = stream(rec_words(0x100, ts=1)) + [0xAAAA] * extra
        res = wp_records.parse_words(words)
        assert res.n_records == 1 and res.n_malformed_words == extra
        assert res.tail_words == [0xAAAA] * extra


def test_malformed_tail_bytes():
    words = stream(rec_words(0x100, ts=1))
    data = struct.pack("<%dI" % len(words), *words) + b"\x55\x66"
    res = wp_records.parse_bytes(data)
    assert res.n_records == 1
    assert res.n_malformed_bytes == 2 and res.n_malformed_words == 0


def test_split_by_core():
    res = parse(rec_words(0x100, ts=1, core=0), rec_words(0x200, ts=2, core=1),
                rec_words(0x104, ts=3, core=0),
                rec_words(0x300, ts=4, core=2, resv=1))   # invalid -> dropped
    by = wp_records.split_by_core(res.records)
    assert sorted(by) == [0, 1]
    assert [r.pc for r in by[0]] == [0x100, 0x104]
    assert [r.pc for r in by[1]] == [0x200]


# ---------------------------------------------------------------------------
# checks: TS monotonicity + wrap
# ---------------------------------------------------------------------------

def test_ts_monotonic_ok():
    res = parse(rec_words(0x100, ts=10), rec_words(0x104, ts=11),
                rec_words(0x108, ts=0x7FFFFFFF))
    ts = checks.check_ts_monotonic(res.records)
    assert ts.ok and ts.wraps == 0 and ts.n_checked == 2


def test_ts_equal_is_violation():
    res = parse(rec_words(0x100, ts=10), rec_words(0x104, ts=10))
    ts = checks.check_ts_monotonic(res.records)
    assert not ts.ok and "equal" in ts.violations[0]


def test_ts_backwards_is_violation():
    res = parse(rec_words(0x100, ts=100), rec_words(0x104, ts=99))
    ts = checks.check_ts_monotonic(res.records)
    assert not ts.ok and "backwards" in ts.violations[0]


def test_ts_wrap_over_ffffffff():
    # 0xFFFFFFF0 -> 0x00000010: modular distance 0x20 -> wrap, no error
    res = parse(rec_words(0x100, ts=0xFFFFFFF0), rec_words(0x104, ts=0x10),
                rec_words(0x108, ts=0x11))
    ts = checks.check_ts_monotonic(res.records)
    assert ts.ok, ts.violations
    assert ts.wraps == 1 and ts.wraps_per_core == {0: 1}


def test_ts_huge_forward_jump_is_violation():
    # a forward jump >= 2^31 is a backward step per the window heuristic
    res = parse(rec_words(0x100, ts=0x1000), rec_words(0x104, ts=0x80001001))
    ts = checks.check_ts_monotonic(res.records)
    assert not ts.ok and "backwards" in ts.violations[0]


def test_ts_per_core_independent():
    # each core has its own chain; interleaving does not interfere
    res = parse(rec_words(0x100, ts=100, core=0),
                rec_words(0x200, ts=5, core=1),
                rec_words(0x104, ts=101, core=0),
                rec_words(0x204, ts=6, core=1))
    ts = checks.check_ts_monotonic(res.records)
    assert ts.ok and ts.n_checked == 2


def test_unwrap_ts():
    res = parse(rec_words(0x100, ts=0xFFFFFFFE), rec_words(0x104, ts=2),
                rec_words(0x108, ts=3))
    un = checks.unwrap_ts(res.records)
    assert [t for _, t in un] == [0xFFFFFFFE, 0x100000002, 0x100000003]


def test_ts_mode_matrix():
    # F1-Fix 3: three modes on three characteristic streams
    zeros = parse(rec_words(0x100, ts=0), rec_words(0x104, ts=0))  # W2==0 (before C0a)
    inc = parse(rec_words(0x100, ts=1), rec_words(0x104, ts=2))
    wrapped = parse(rec_words(0x100, ts=0xFFFFFFF0), rec_words(0x104, ts=0x10))
    # wrap (default, == the original heuristic)
    assert not checks.check_ts_monotonic(zeros.records, mode="wrap").ok
    assert checks.check_ts_monotonic(inc.records, mode="wrap").ok
    w = checks.check_ts_monotonic(wrapped.records, mode="wrap")
    assert w.ok and w.wraps == 1
    # strict: strictly increasing WITHOUT wrap -- the wrap is now a violation
    assert not checks.check_ts_monotonic(zeros.records, mode="strict").ok
    assert checks.check_ts_monotonic(inc.records, mode="strict").ok
    s = checks.check_ts_monotonic(wrapped.records, mode="strict")
    assert not s.ok and s.wraps == 0 and "backwards" in s.violations[0]
    # strict is purely numeric: a huge forward jump (>= 2^31) is OK
    jump = parse(rec_words(0x100, ts=0x1000), rec_words(0x104, ts=0x80001001))
    assert checks.check_ts_monotonic(jump.records, mode="strict").ok
    assert not checks.check_ts_monotonic(jump.records, mode="wrap").ok
    # off: nothing checked, everything green (even W2==0)
    o = checks.check_ts_monotonic(zeros.records, mode="off")
    assert o.ok and o.n_checked == 0 and o.wraps == 0
    # an unknown mode is a tool error
    try:
        checks.check_ts_monotonic(inc.records, mode="bogus")
        assert False, "expected ValueError"
    except ValueError as e:
        assert "bogus" in str(e)


# ---------------------------------------------------------------------------
# checks: membership + sequence
# ---------------------------------------------------------------------------

def _write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def test_addr_file_and_membership():
    d = tempfile.mkdtemp(prefix="f0_test_")
    p = os.path.join(d, "wp_set.txt")
    _write(p, "# comment\n0x00000100 func_a\n0x104\n\n0x00000108  <boot+0x8>\n")
    addrs = checks.load_addr_file(p)
    assert addrs == [0x100, 0x104, 0x108]
    res = parse(rec_words(0x100, ts=1), rec_words(0x104, ts=2),
                rec_words(0x1FC, ts=3))
    mem = checks.check_pc_membership(res.records, set(addrs))
    assert not mem.ok and mem.n_checked == 3
    assert [r.pc for r in mem.misses] == [0x1FC]
    mem2 = checks.check_pc_membership(res.records[:2], set(addrs))
    assert mem2.ok and mem2.misses == []


def test_addr_file_bad_line():
    d = tempfile.mkdtemp(prefix="f0_test_")
    p = os.path.join(d, "bad.txt")
    _write(p, "0x100\nnotanaddr xyz\n")
    try:
        checks.load_addr_file(p)
        assert False, "expected ValueError"
    except ValueError as e:
        assert ":2:" in str(e)


def test_addr_file_e0_hits_format():
    # F1: the real E0 format `P<phase> <seq> 0x<addr8> <name>` (the first
    # token is NOT the address) -- mixed with the wp_set format
    d = tempfile.mkdtemp(prefix="f0_test_")
    p = os.path.join(d, "hits.txt")
    _write(p, "# expected_hits -- header\n"
              "P0 0 0x00000a6c entry:f018\n"
              "P0 1 0x00000d1c entry:f021+0x4\n"
              "0x00001c8 entry:f000\n")
    assert checks.load_addr_file(p) == [0xA6C, 0xD1C, 0x1C8]
    # a broken 0x token raises with a line number (no silent skip)
    p2 = os.path.join(d, "bad0x.txt")
    _write(p2, "P0 0 0xZZZ entry:kaputt\n")
    try:
        checks.load_addr_file(p2)
        assert False, "expected ValueError"
    except ValueError as e:
        assert ":1:" in str(e)
    # a line without any 0x token also raises
    p3 = os.path.join(d, "no0x.txt")
    _write(p3, "P0 0 42 entry:ohne\n")
    try:
        checks.load_addr_file(p3)
        assert False, "expected ValueError"
    except ValueError as e:
        assert ":1:" in str(e)


def test_sequence_exact_and_drops():
    exp = [0x100, 0x104, 0x108, 0x10C, 0x110]
    # exact
    res = parse(*[rec_words(a, ts=i + 1) for i, a in enumerate(exp)])
    seq = checks.check_sequence(res.records, exp)
    assert seq.ok and seq.matched == 5 and seq.expected_consumed == 5
    # with drops (the shim discards 0x104 + 0x10C) -> subsequence, still green
    res = parse(rec_words(0x100, ts=1), rec_words(0x108, ts=2),
                rec_words(0x110, ts=3))
    seq = checks.check_sequence(res.records, exp)
    assert seq.ok and seq.matched == 3 and seq.expected_consumed == 5


def test_sequence_bogus_record():
    exp = [0x100, 0x104, 0x108]
    res = parse(rec_words(0x100, ts=1), rec_words(0xBAD0, ts=2),
                rec_words(0x104, ts=3), rec_words(0x108, ts=4))
    seq = checks.check_sequence(res.records, exp)
    # foreign record reported, cursor not desynchronized: the rest matches
    assert not seq.ok and seq.matched == 3
    assert len(seq.unmatched) == 1 and seq.unmatched[0][0].pc == 0xBAD0
    assert seq.unmatched[0][1] == 1          # cursor stood at expected[1]


def test_sequence_out_of_order_detected():
    exp = [0x100, 0x104, 0x108]
    res = parse(rec_words(0x104, ts=1), rec_words(0x100, ts=2),
                rec_words(0x108, ts=3))
    seq = checks.check_sequence(res.records, exp)
    assert not seq.ok and len(seq.unmatched) == 1
    assert seq.unmatched[0][0].pc == 0x100   # 0x100 cannot be placed after 0x104


def test_sequence_cycle():
    # F1: periodic oracle (endless walk) -- cursor wraps, cycles is counted
    exp = [0x100, 0x104, 0x108]
    obs = parse(rec_words(0x104, ts=1), rec_words(0x100, ts=2),
                rec_words(0x108, ts=3), rec_words(0x104, ts=4))
    seq = checks.check_sequence(obs.records, exp, cycle=True)
    assert seq.ok and seq.matched == 4 and seq.cycles == 2
    assert seq.expected_consumed == 2        # cursor position in the last lap
    # a foreign record misses the full cycle too: reported, cursor stays
    # put (does not desynchronize), cycles unchanged
    obs2 = parse(rec_words(0x100, ts=1), rec_words(0xBAD0, ts=2),
                 rec_words(0x104, ts=3))
    seq2 = checks.check_sequence(obs2.records, exp, cycle=True)
    assert not seq2.ok and seq2.matched == 2
    assert len(seq2.unmatched) == 1 and seq2.unmatched[0][0].pc == 0xBAD0
    assert seq2.cycles == 0
    # without cycle the old behavior holds (the 2nd lap shows up as an error)
    seq3 = checks.check_sequence(obs.records, exp)
    assert not seq3.ok


# ---------------------------------------------------------------------------
# checks: merge of two cores
# ---------------------------------------------------------------------------

def test_merge_two_cores_with_tie():
    res = parse(rec_words(0x100, ts=10, core=0), rec_words(0x104, ts=30, core=0),
                rec_words(0x200, ts=10, core=1), rec_words(0x204, ts=20, core=1))
    by = wp_records.split_by_core(res.records)
    merged = checks.merge_streams(by)
    # tie at ts=10: core 0 first
    assert [(r.core_id, r.pc) for r in merged] == \
        [(0, 0x100), (1, 0x200), (1, 0x204), (0, 0x104)]


def test_merge_across_wrap():
    # core 1 wraps; its 0x...02 is TEMPORALLY after core 0's ts=0xFFFFFFFB
    res = parse(rec_words(0x100, ts=0xFFFFFFF0, core=0),
                rec_words(0x104, ts=0xFFFFFFFB, core=0),
                rec_words(0x200, ts=0xFFFFFFFA, core=1),
                rec_words(0x204, ts=0x2, core=1))
    by = wp_records.split_by_core(res.records)
    merged = checks.merge_streams(by)
    assert [r.pc for r in merged] == [0x100, 0x200, 0x104, 0x204]


def test_merge_empty_and_single():
    assert checks.merge_streams({}) == []
    res = parse(rec_words(0x100, ts=1, core=0))
    by = wp_records.split_by_core(res.records)
    assert [r.pc for r in checks.merge_streams(by)] == [0x100]


# ---------------------------------------------------------------------------
# fifo_mm_s: FakeBus read loop
# ---------------------------------------------------------------------------

def test_fifo_init_nondestructive_default():
    # F1-Fix 1: default init LEAVES buffered records alone (no RDFR)
    p0 = rec_words(0x100, ts=1)
    bus = FakeBus(packets=[p0])
    fifo = fifo_mm_s.FifoMmS(bus)
    fifo.init()
    ws = [e for e in bus.log if e[0] == "w"]
    assert ws == [("w", REG["IER"], 0)]      # ONLY IER := 0, no RDFR/ISR
    assert bus.data == list(p0)              # occupancy untouched
    words, st = fifo.drain()
    assert words == p0 and st.n_packets == 1  # the backlog still arrives


def test_fifo_init_sequence():
    # explicit reset (reset_on_init=True): IER := 0, RDFR := 0xA5,
    # ISR := W1C -- in this order; discards the buffer
    p0 = rec_words(0x100, ts=1)
    bus = FakeBus(packets=[p0])
    fifo = fifo_mm_s.FifoMmS(bus, reset_on_init=True)
    fifo.init()
    ws = [e for e in bus.log if e[0] == "w"]
    assert ws[0] == ("w", REG["IER"], 0)
    assert ws[1] == ("w", REG["RDFR"], fifo_mm_s.RESET_KEY)
    assert ws[2] == ("w", REG["ISR"], 0xFFFFFFFF)
    assert bus.regs[REG["ISR"]] == 0         # RRC cleared again
    words, st = fifo.drain()
    assert words == [] and st.n_packets == 0  # reset DID discard it (G0 1a)


def test_fifo_drain_two_packets():
    p0 = rec_words(0x100, ts=1)
    p1 = rec_words(0x104, ts=2, core=1)
    bus = FakeBus(packets=[p0, p1])
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain()
    assert words == p0 + p1
    assert st.n_packets == 2 and st.n_words == 8
    assert st.n_partial == 0 and st.n_zero_len == 0
    # sequence per packet: RDFO -> RLR -> 4x RDFD
    rs = [e[1] for e in bus.log if e[0] == "r"]
    expect = [REG["RDFO"], REG["RLR"]] + [REG["RDFD"]] * 4
    assert rs == expect + expect + [REG["RDFO"]]   # final RDFO == 0 ends it
    # afterwards: parse attaches directly
    res = wp_records.parse_words(words)
    assert res.n_records == 2 and res.n_valid == 2


def test_fifo_empty():
    bus = FakeBus()
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain()
    assert words == [] and st.n_packets == 0
    # with RDFO == 0, neither RLR nor RDFD is touched
    rs = [e[1] for e in bus.log if e[0] == "r"]
    assert rs == [REG["RDFO"]]


def test_fifo_partial_packet():
    # RLR claims 16 bytes, but only 2 words are actually in the FIFO
    bus = FakeBus()
    bus.data = [0x11, 0x22]
    bus.lengths = [16]
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain()
    assert words == [0x11, 0x22]
    assert st.n_partial == 1 and st.n_packets == 1
    # the partial remainder shows up as the parser's malformed counter (2 words < 4)
    res = wp_records.parse_words(words)
    assert res.n_records == 0 and res.n_malformed_words == 2


def test_fifo_cut_through_partial_flag():
    p = rec_words(0x100, ts=1)
    bus = FakeBus()
    bus.data = list(p)
    bus.lengths = [fifo_mm_s.RLR_PARTIAL | 16]     # bit 31 set
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain()
    assert words == p and st.n_partial == 1


def test_fifo_zero_length():
    bus = FakeBus()
    bus.data = [0x11]
    bus.lengths = [0]                              # RLR == 0 despite occupancy
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain()
    assert words == [] and st.n_zero_len == 1 and st.n_packets == 0


def test_fifo_max_packets():
    ps = [rec_words(0x100 + 4 * i, ts=i + 1) for i in range(3)]
    bus = FakeBus(packets=ps)
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain(max_packets=2)
    assert st.n_packets == 2 and len(words) == 8


# ---------------------------------------------------------------------------
# fifo_mm_s: drain_poll (F1-Fix 2 -- empty windows do not end it)
# ---------------------------------------------------------------------------

class ArrivingBus(FakeBus):
    """FakeBus in which packets only arrive at the Nth RDFO poll.

    `schedule` = {rdfo_poll_index: [packet, ...]} -- models empty windows
    between record arrivals (the G0 continuous-run case).
    """

    def __init__(self, schedule):
        super().__init__()
        self.schedule = {k: list(v) for k, v in schedule.items()}
        self.rdfo_polls = 0

    def r1(self, off):
        if off == REG["RDFO"]:
            for p in self.schedule.pop(self.rdfo_polls, []):
                self.data += list(p)
                self.lengths.append(4 * len(p))
            self.rdfo_polls += 1
        return super().r1(off)


class FakeClock:
    """Deterministic time for drain_poll tests (sleep advances the clock)."""

    def __init__(self):
        self.t = 0.0
        self.sleeps = []

    def clock(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s


def test_fifo_drain_poll_over_empty_windows():
    # packets only arrive at the 3rd and 5th RDFO poll -- the old drain()
    # would have stopped at the 1st empty poll (G0 finding 1b)
    p0 = rec_words(0x100, ts=1)
    p1 = rec_words(0x104, ts=2)
    bus = ArrivingBus({2: [p0], 4: [p1]})
    clk = FakeClock()
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain_poll(poll_s=0.01, max_records=2,
                                sleep=clk.sleep, clock=clk.clock)
    assert words == p0 + p1
    assert st.n_packets == 2
    assert st.n_polls == 3 and clk.sleeps == [0.01] * 3
    # counter-check: the one-shot loop ends at the first empty window
    bus2 = ArrivingBus({2: [p0]})
    words2, st2 = fifo_mm_s.FifoMmS(bus2).drain()
    assert words2 == [] and st2.n_packets == 0


def test_fifo_drain_poll_duration_budget():
    bus = FakeBus()                          # stays empty
    clk = FakeClock()
    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain_poll(poll_s=0.5, duration_s=2.0,
                                sleep=clk.sleep, clock=clk.clock)
    # sleeps 0.5/1.0/1.5/2.0, then the budget is reached -> end
    assert words == [] and st.n_polls == 4 and clk.t == 2.0


def test_fifo_drain_poll_stop_flag():
    # stop() (CLI: SIGINT/SIGTERM) ends it; the available backlog is still
    # drained before the end
    p0 = rec_words(0x100, ts=1)
    bus = FakeBus(packets=[p0])
    clk = FakeClock()
    calls = []

    def stop():
        calls.append(1)
        return len(calls) >= 2

    fifo = fifo_mm_s.FifoMmS(bus)
    words, st = fifo.drain_poll(poll_s=0.01, stop=stop,
                                sleep=clk.sleep, clock=clk.clock)
    assert words == p0 and st.n_packets == 1
    assert st.n_polls == 1                   # exactly one sleep window


# ---------------------------------------------------------------------------
# CLI end-to-end (file source)
# ---------------------------------------------------------------------------

def test_cli_file_green_and_red():
    d = tempfile.mkdtemp(prefix="f0_cli_")
    exp = [0x100, 0x104, 0x108]
    words = stream(rec_words(0x100, ts=0xFFFFFFF0, core=0),
                   rec_words(0x104, ts=0x10, core=0),       # wrap, no error
                   rec_words(0x100, ts=0x11, core=1),
                   rec_words(0x108, ts=0x12, core=1))
    binp = os.path.join(d, "stream.bin")
    with open(binp, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    wpp = os.path.join(d, "wp_set.txt")
    _write(wpp, "0x100 a\n0x104 b\n0x108 c\n")
    expp = os.path.join(d, "expected_hits.txt")
    _write(expp, "0x100\n0x104\n0x108\n")
    rc = read_wp_stream.run(["--source", "file", "--in", binp,
                             "--wp-set", wpp, "--expected", expp,
                             "--core", "merge"])
    assert rc == 0
    # red: PC outside the set
    with open(binp, "ab") as f:
        f.write(struct.pack("<4I", *rec_words(0xBAD0, ts=0x13, core=1)))
    rc = read_wp_stream.run(["--source", "file", "--in", binp,
                             "--wp-set", wpp])
    assert rc == 1
    # core filter: core 0 alone stays green (0xBAD0 is on core 1)
    rc = read_wp_stream.run(["--source", "file", "--in", binp,
                             "--wp-set", wpp, "--core", "0"])
    assert rc == 0


def test_cli_malformed_is_red():
    d = tempfile.mkdtemp(prefix="f0_cli_")
    binp = os.path.join(d, "stream.bin")
    words = stream(rec_words(0x100, ts=1)) + [0x77]          # remainder word
    with open(binp, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    assert read_wp_stream.run(["--in", binp]) == 1


def test_cli_invalid_record_is_red():
    d = tempfile.mkdtemp(prefix="f0_cli_")
    binp = os.path.join(d, "stream.bin")
    words = stream(rec_words(0x100, ts=1, resv=0xFF))
    with open(binp, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    assert read_wp_stream.run(["--in", binp]) == 1


def test_cli_ts_mode():
    # F1-Fix 3: W2==0 stream (state before C0a) -- default/strict red, off green
    d = tempfile.mkdtemp(prefix="f0_cli_")
    binp = os.path.join(d, "zeros.bin")
    words = stream(rec_words(0x100, ts=0), rec_words(0x104, ts=0),
                   rec_words(0x108, ts=0))
    with open(binp, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    assert read_wp_stream.run(["--in", binp]) == 1                    # wrap
    assert read_wp_stream.run(["--in", binp, "--ts-mode", "strict"]) == 1
    assert read_wp_stream.run(["--in", binp, "--ts-mode", "off"]) == 0
    # wrap stream: default tolerates the wrap, strict does not
    binw = os.path.join(d, "wrap.bin")
    words = stream(rec_words(0x100, ts=0xFFFFFFF0), rec_words(0x104, ts=0x10))
    with open(binw, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    assert read_wp_stream.run(["--in", binw]) == 0
    assert read_wp_stream.run(["--in", binw, "--ts-mode", "strict"]) == 1


def test_cli_expected_cycle():
    # F1: observation across 2 walk passes against a one-pass oracle
    d = tempfile.mkdtemp(prefix="f0_cli_")
    exp = [0x100, 0x104, 0x108]
    obs = [0x100, 0x104, 0x108, 0x100, 0x108]        # 2nd pass with a drop
    words = stream(*[rec_words(a, ts=i + 1) for i, a in enumerate(obs)])
    binp = os.path.join(d, "stream.bin")
    with open(binp, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    expp = os.path.join(d, "expected_hits.txt")
    _write(expp, "".join("P0 %d 0x%08x entry:f%03d\n" % (i, a, i)
                         for i, a in enumerate(exp)))
    assert read_wp_stream.run(["--in", binp, "--expected", expp,
                               "--expected-cycle"]) == 0
    assert read_wp_stream.run(["--in", binp, "--expected", expp]) == 1


def test_cli_parser_defaults_and_alias():
    # reset default off, ts-mode wrap, no polling; --max-packets remains
    # a working alias for --max-records (same dest)
    ap = read_wp_stream.build_parser()
    a = ap.parse_args([])
    assert a.reset is False and a.ts_mode == "wrap"
    assert a.max_records == 0 and a.poll_ms is None and a.duration_s is None
    assert a.expected_cycle is False
    assert ap.parse_args(["--max-records", "7"]).max_records == 7
    assert ap.parse_args(["--max-packets", "5"]).max_records == 5
    assert ap.parse_args(["--reset"]).reset is True
    assert ap.parse_args(["--poll-ms", "10", "--duration-s", "3"]).poll_ms == 10.0


# ---------------------------------------------------------------------------

def main():
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        fn()
        print("PASS %s" % name)
    print("tests=%d records-layout=D0(W0 PC/W1 direct/W2 ts/W3 meta)" % len(tests))
    print("F0_ALL_PASS")


if __name__ == "__main__":
    main()
