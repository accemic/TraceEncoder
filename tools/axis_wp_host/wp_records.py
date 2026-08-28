#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""wp_records.py -- Parser for the 4-word watchpoint record of the ct_axis_wp_shim.

Record format (fixed by package D0, `rtl/board_kv260/ct_axis_wp_shim.sv`
header + `docs/handoffs/D0_axis_shim.md`; one record = 4 x 32-bit words,
little-endian on the wire like everywhere on the KV260 window):

    W0  PC          instruction address (DAQ_PC_CURR element 0)
    W1  DirectData  (element 1)
    W2  Timestamp   TS[31:0] (element 2, CT_EN_AXIS_TS)
    W3  Meta        {8'h00, core_id[3:0], tstrb[11:0], tid[7:0]}
                    [7:0] tid, [19:8] tstrb, [23:20] core_id, [31:24] = 0

Validation per record (flag errors, do NOT raise -- the stream from the
board can contain garbage and the reader must count instead of dying):
  * W3[31:24] must be 0 (reserved bits; the shim drives them hard 0).
  * tstrb plausibility: tstrb is 1 strobe bit per tdata byte (12 bits for
    96 bit). The elements are 32-bit words -> each element group
    (bits [3:0] = W0, [7:4] = W1, [11:8] = W2) must be EITHER fully set
    OR fully clear, and element 0 (PC) must be present. A partial strobe
    within an element, or a record without PC, cannot be produced on the
    WP path and counts as implausible (documented heuristic -- the
    encoder strobes element-wise).

Stream splitting: the word count must be a multiple of 4; a remainder of
1..3 words (or 1..3 bytes for the byte parser) is "malformed" and is
counted and reported, not raised.
"""
from __future__ import annotations

import struct

W3_RESERVED_MASK = 0xFF000000   # W3[31:24] must be 0
TSTRB_ELEM0 = 0x00F             # strobes of the PC element
TSTRB_ELEM1 = 0x0F0
TSTRB_ELEM2 = 0xF00


class Record:
    """A parsed 4-word watchpoint record.

    `errors` is a list of plain-text findings; empty == record valid.
    `index` is the record index in the parsed stream (0-based).
    """

    __slots__ = ("index", "pc", "direct", "ts", "tid", "tstrb", "core_id",
                 "errors")

    def __init__(self, index: int, w0: int, w1: int, w2: int, w3: int):
        self.index = index
        self.pc = w0 & 0xFFFFFFFF
        self.direct = w1 & 0xFFFFFFFF
        self.ts = w2 & 0xFFFFFFFF
        self.tid = w3 & 0xFF
        self.tstrb = (w3 >> 8) & 0xFFF
        self.core_id = (w3 >> 20) & 0xF
        self.errors: list[str] = []
        if w3 & W3_RESERVED_MASK:
            self.errors.append("W3[31:24]!=0 (0x%02X)" % ((w3 >> 24) & 0xFF))
        for name, mask in (("elem0/PC", TSTRB_ELEM0),
                           ("elem1/DirectData", TSTRB_ELEM1),
                           ("elem2/TS", TSTRB_ELEM2)):
            part = self.tstrb & mask
            if part not in (0, mask):
                self.errors.append("tstrb partial in %s (tstrb=0x%03X)"
                                   % (name, self.tstrb))
        if not (self.tstrb & TSTRB_ELEM0):
            self.errors.append("tstrb: PC element absent (tstrb=0x%03X)"
                               % self.tstrb)

    @property
    def valid(self) -> bool:
        return not self.errors

    def __repr__(self) -> str:
        return ("Record(#%d core=%d pc=0x%08X direct=0x%08X ts=0x%08X "
                "tid=0x%02X tstrb=0x%03X%s)"
                % (self.index, self.core_id, self.pc, self.direct, self.ts,
                   self.tid, self.tstrb,
                   "" if self.valid else " INVALID:" + ";".join(self.errors)))


class StreamResult:
    """Result of the stream splitting.

    records            all records (including invalid ones -- see Record.errors)
    tail_words         remainder words (< 4) at the end of the stream, raw
    n_malformed_words  len(tail_words)
    n_malformed_bytes  remainder bytes (< 4) for the byte parser, else 0
    """

    __slots__ = ("records", "tail_words", "n_malformed_words",
                 "n_malformed_bytes")

    def __init__(self, records, tail_words, n_malformed_bytes=0):
        self.records: list[Record] = records
        self.tail_words: list[int] = tail_words
        self.n_malformed_words = len(tail_words)
        self.n_malformed_bytes = n_malformed_bytes

    @property
    def n_records(self) -> int:
        return len(self.records)

    @property
    def n_valid(self) -> int:
        return sum(1 for r in self.records if r.valid)

    @property
    def n_invalid(self) -> int:
        return self.n_records - self.n_valid


def parse_words(words) -> StreamResult:
    """32-bit word list -> records. Remainder (len % 4) is counted, not raised."""
    words = [w & 0xFFFFFFFF for w in words]
    n_full = len(words) // 4
    records = [Record(i, words[4 * i], words[4 * i + 1],
                      words[4 * i + 2], words[4 * i + 3])
               for i in range(n_full)]
    return StreamResult(records, words[4 * n_full:])


def parse_bytes(data: bytes) -> StreamResult:
    """Byte stream (little-endian 32-bit words) -> records.

    Both remainder bytes (len % 4) AND remainder words (word count % 4) are
    counted.
    """
    n_bytes_tail = len(data) % 4
    usable = len(data) - n_bytes_tail
    words = list(struct.unpack("<%dI" % (usable // 4), data[:usable]))
    res = parse_words(words)
    return StreamResult(res.records, res.tail_words, n_bytes_tail)


def split_by_core(records) -> dict:
    """Group records by core_id (valid records only; order is preserved)."""
    out: dict[int, list[Record]] = {}
    for r in records:
        if r.valid:
            out.setdefault(r.core_id, []).append(r)
    return out
