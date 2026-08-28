#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""wp_load_indirect.py -- INDIRECT watchpoint load path of the C0b build (G1).

The C0b encoder (the 1023-slot watchpoint line) no longer
carries a direct WP window (the D1 window `ENCx + 0x4100` collided with
the DF registers at 1023 slots and was removed — BREAKING CHANGE,
SPEC_axis_wp_memory_map §7). The table is loaded exclusively through the
indirect registers in the ENC windows (offsets relative to the window
base, source rdl/ct_cs_cpuif.rdl @78460f0d4e):

    0x400C  trWpIndex     rw  Idx[15:0] -- slot pointer (load + readback)
    0x4010  trWpDataLow   rw  staging: watchpoint address (32 bit)
    0x4014  trWpDataHigh  rw  staging + COMMIT: Cmd[5:0]/Sink[7:6]/
                              DirectData[31:8]; the write commits
                              {Low,High} to slot Idx and increments
                              Idx (wraps at NUM_ACT_ST-1)
    0x4018  trWpReadLow   ro  shadow readback address (does NOT move Idx)
    0x401C  trWpReadHigh  ro  shadow readback Cmd word; READING it
                              increments Idx (serial readback, wraps)
    0x4020  trWpCap       ro  Entries[15:0] = slot capacity (1023;
                              reads 0 in profiles without ACT)

All three load registers are swwel-gated (writable only while
trTeControl.Enable=0), and the shim additionally gates the commit with
!Enable — loading is possible only while the encoder is inactive
(search-tree consistency rule; here the hardware enforces it).

Programming rules (RDL contract, verified in sim C1b, pattern
sim/axis_wp/tb_tgc5b2_axis_soc.sv wp_program_ind/wp_verify_slot):
  * Load ALL slots, in strictly ascending order (search tree); fill unused
    slots with ODD filler addresses (PC[0]=0 => unmatchable) and
    Cmd = ACT_CAP_ST_NONE (0).
  * Idx := 0, then per slot DataLow + DataHigh; after N commits Idx must
    read 0 again — the cheap load-verification check (wrap proof).

Bus contract same as fifo_mm_s.FifoMmS: any object with `r1(off) -> int`
and `write(off, val)` — on the board `fifo_mm_s.DevMemBus` on the ENC
window (map >= 0x5000 in size), offline the FakeIndirectBus of the
self-test (`py wp_load_indirect.py` runs without hardware and checks the
protocol, including the wrap/serial-readback contract, against a
reference model).
"""
from __future__ import annotations

# Register offsets within the ENC window (SPEC_axis_wp_memory_map §7).
WP_IND_OFFSETS = {
    "IDX":     0x400C,
    "DATA_LO": 0x4010,
    "DATA_HI": 0x4014,
    "READ_LO": 0x4018,
    "READ_HI": 0x401C,
    "CAP":     0x4020,
}

CMD_DAQ_PC_AXIS = 0x41        # Sink=AXIS(2'b01)<<6 | Cmd=DAQ_PC_CURR(1)
CMD_NONE = 0x00               # ACT_CAP_ST_NONE (filler slots)


class WpLoadError(RuntimeError):
    """Protocol violation during indirect load/readback (text = evidence)."""


def cmd_word(addr: int, slot: int) -> int:
    """Cmd word per slot (C1b rule `cmd_of`): a real (even) address ->
    DAQ_PC_CURR/Sink=AXIS, an odd filler -> ACT_CAP_ST_NONE;
    DirectData[31:8] = slot index (W1 cross-check on real slots)."""
    return (CMD_NONE if addr & 1 else CMD_DAQ_PC_AXIS) | ((slot & 0xFFFFFF) << 8)


def read_cap(bus, offsets=None) -> int:
    reg = dict(WP_IND_OFFSETS)
    if offsets:
        reg.update(offsets)
    return bus.r1(reg["CAP"]) & 0xFFFF


def load_table(bus, table, offsets=None) -> None:
    """Load the full table indirectly: Idx := 0, per slot Low+High (commit),
    then an Idx==0 check (proves both autoincrement AND wrap in one read).

    `table` = list of (addr, cmd) in slot order; its length MUST match the
    capacity (trWpCap), otherwise the wrap check proves nothing.
    Raises WpLoadError with register values in the text.
    """
    reg = dict(WP_IND_OFFSETS)
    if offsets:
        reg.update(offsets)
    cap = bus.r1(reg["CAP"]) & 0xFFFF
    if cap != len(table):
        raise WpLoadError("trWpCap %d != table length %d (the wrap proof "
                          "needs the full table)" % (cap, len(table)))
    bus.write(reg["IDX"], 0)
    for addr, cmd in table:
        bus.write(reg["DATA_LO"], addr)
        bus.write(reg["DATA_HI"], cmd)
    idx = bus.r1(reg["IDX"]) & 0xFFFF
    if idx != 0:
        raise WpLoadError("Idx %d != 0 after %d commits -- autoincrement/"
                          "wrap proof failed (encoder armed? swwel blocks "
                          "while trTeControl.Enable=1)"
                          % (idx, len(table)))


def verify_slot(bus, slot: int, exp_addr: int, exp_cmd: int, n_slots: int,
                offsets=None) -> None:
    """Serial-readback spot check of ONE slot (C1b `wp_verify_slot`):
    Idx := slot; ReadLow == exp_addr (Idx unmoved); ReadHigh == exp_cmd
    (reading it increments Idx); Idx afterwards == (slot+1) mod n_slots."""
    reg = dict(WP_IND_OFFSETS)
    if offsets:
        reg.update(offsets)
    bus.write(reg["IDX"], slot)
    lo = bus.r1(reg["READ_LO"])
    if lo != exp_addr:
        raise WpLoadError("Slot %d: ReadLow 0x%08x != 0x%08x"
                          % (slot, lo, exp_addr))
    idx = bus.r1(reg["IDX"]) & 0xFFFF
    if idx != slot:
        raise WpLoadError("Slot %d: Idx %d moved after ReadLow (contract: "
                          "only ReadHigh increments it)" % (slot, idx))
    hi = bus.r1(reg["READ_HI"])
    if hi != exp_cmd:
        raise WpLoadError("Slot %d: ReadHigh 0x%08x != 0x%08x"
                          % (slot, hi, exp_cmd))
    exp_next = 0 if slot == n_slots - 1 else slot + 1
    idx = bus.r1(reg["IDX"]) & 0xFFFF
    if idx != exp_next:
        raise WpLoadError("Slot %d: Idx after ReadHigh %d != %d "
                          "(serial readback/wrap)" % (slot, idx, exp_next))


def load_and_verify(bus, table, probe_slots=(0, 511, 1022), offsets=None,
                    log=None) -> None:
    """G1 load evidence in one go: trWpCap == len(table), load the full
    table (including the Idx wrap proof), readback spot checks `probe_slots`."""
    n = len(table)
    load_table(bus, table, offsets=offsets)
    for s in probe_slots:
        verify_slot(bus, s, table[s][0], table[s][1], n, offsets=offsets)
    if log:
        log("WP-INDIRECT: %d slots committed (Idx wrap proof), trWpCap==%d,"
            " readback %s OK" % (n, n, "/".join(str(s) for s in probe_slots)))


# ---------------------------------------------------------------------------
# Offline self-test (no /dev/mem): reference model of the RDL contract.
# ---------------------------------------------------------------------------
class FakeIndirectBus:
    """Protocol reference model for the self-test (RDL semantics: commit
    on DataHigh write, ReadHigh swacc increments, wraps at n-1)."""

    def __init__(self, n_slots=1023):
        self.n = n_slots
        self.idx = 0
        self.lo = 0
        self.hi = 0
        self.mem = {}

    def _advance(self):
        self.idx = 0 if self.idx == self.n - 1 else self.idx + 1

    def r1(self, off):
        if off == WP_IND_OFFSETS["IDX"]:
            return self.idx
        if off == WP_IND_OFFSETS["READ_LO"]:
            return self.mem.get(self.idx, (0, 0))[0]
        if off == WP_IND_OFFSETS["READ_HI"]:
            v = self.mem.get(self.idx, (0, 0))[1]
            self._advance()
            return v
        if off == WP_IND_OFFSETS["CAP"]:
            return self.n
        raise AssertionError("read @0x%04x" % off)

    def write(self, off, val):
        if off == WP_IND_OFFSETS["IDX"]:
            self.idx = val & 0xFFFF
        elif off == WP_IND_OFFSETS["DATA_LO"]:
            self.lo = val
        elif off == WP_IND_OFFSETS["DATA_HI"]:
            self.hi = val
            self.mem[self.idx] = (self.lo, self.hi)
            self._advance()
        else:
            raise AssertionError("write @0x%04x" % off)


def _selftest():
    n = 1023
    # Table following the C1b pattern: 364 "real" even + 659 odd fillers.
    addrs = sorted(0x1000 + 4 * i for i in range(364))
    maxa = addrs[-1]
    addrs += [(maxa & ~3) + 5 + 2 * j for j in range(n - 364)]
    table = [(a, cmd_word(a, i)) for i, a in enumerate(addrs)]
    bus = FakeIndirectBus(n)
    load_and_verify(bus, table, log=lambda s: print("SELFTEST| " + s))
    assert bus.mem[0] == table[0] and bus.mem[511] == table[511]
    assert bus.mem[1022] == table[1022] and len(bus.mem) == n
    assert table[0][1] == CMD_DAQ_PC_AXIS          # real: slot 0, Cmd 0x41
    assert table[511][1] == (511 << 8) | CMD_NONE  # filler: Cmd NONE
    # Negative: wrong table length and a manipulated slot must both raise.
    for bad_call in (
            lambda: load_table(bus, table[:-1]),
            lambda: verify_slot(bus, 5, table[5][0] ^ 4, table[5][1], n)):
        try:
            bad_call()
        except WpLoadError:
            pass
        else:
            raise AssertionError("expected WpLoadError")
    print("SELFTEST| WP_LOAD_INDIRECT_SELFTEST_PASS (n=%d)" % n)


if __name__ == "__main__":
    _selftest()
