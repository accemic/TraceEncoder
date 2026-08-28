#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Analysis of the decoded PC stream: symbols, live window, hot list.

What happens here, and what does NOT:

* **Symbolisation** from a `System.map`/`nm` file (`addr type name`). Pure
  lookup work, no estimation.
* **Window alignment** to Nexus message boundaries. The reference decoder
  aborts when a byte stream does not start with MSEO='00' (`NexRvDeco.c`:
  "Message must start from MSEO='00'", return -2). A slice out of a ring
  buffer practically always starts in the middle of a message -- so before
  decoding, the stream is advanced to the first byte AFTER an MSEO='11' (end
  of message) and cut behind the last such byte. The decoder itself
  deliberately emits no PCs before the first sync message ("Do not emit
  speculative PCs before the first synchronization message"), so the start of
  a window yields no wrong addresses.
* **Call analysis** only where it is exact: with the C extension disabled
  every instruction is 4 bytes long, so `pc_next != pc + 4` is precisely a
  control transfer. If the transfer hits the start of a symbol it is a call;
  if it hits the remembered return address it is a return. On cores WITH the
  C extension that stride does not hold -- then the depth is NOT computed
  (`depth = None`) instead of inventing a number.
* **Coverage** here is function coverage, not instruction coverage, and it
  refers exclusively to the windows that were actually decoded. That is why
  the field is called `functions_seen` and carries its frame of reference in
  its name.
"""
import bisect
import re
import time
from pathlib import Path

# Nexus MSEO encoding (the low two bits of every byte):
#   00 = byte inside a message     01 = end of field
#   11 = end of message            10 = not allowed
MSEO_END = 0x3


def align_to_messages(raw: bytes):
    """Trim to whole Nexus messages.

    Returns (payload, dropped_head, dropped_tail). Empty result if the
    window does not contain two message boundaries.
    """
    if not raw:
        return b"", 0, 0
    start = -1
    for i, b in enumerate(raw):
        if (b & 0x3) == MSEO_END:
            start = i + 1
            break
    if start < 0 or start >= len(raw):
        return b"", len(raw), 0
    end = -1
    for i in range(len(raw) - 1, start - 1, -1):
        if (raw[i] & 0x3) == MSEO_END:
            end = i + 1
            break
    if end <= start:
        return b"", start, len(raw) - start
    return raw[start:end], start, len(raw) - end


class SymbolTable:
    """`System.map`/`nm` symbols, address-ordered, with bisect lookup."""

    LINE = re.compile(r"^\s*([0-9a-fA-F]{4,16})\s+([a-zA-Z])\s+(\S+)")
    # executable symbols only -- data objects would dilute the coverage
    TEXT_TYPES = set("tTwW")

    def __init__(self):
        self.addrs = []          # sorted start addresses
        self.names = []          # same index
        self.ends = []           # start address of the following symbol (upper bound)
        self.source = None
        self.count = 0

    @classmethod
    def from_text(cls, text, source=None):
        st = cls()
        rows = []
        for line in text.splitlines():
            m = cls.LINE.match(line)
            if not m:
                continue
            if m.group(2) not in cls.TEXT_TYPES:
                continue
            rows.append((int(m.group(1), 16), m.group(3)))
        rows.sort()
        # Duplicate addresses: keep the first name (aliases like _text/_start)
        for a, n in rows:
            if st.addrs and st.addrs[-1] == a:
                continue
            st.addrs.append(a)
            st.names.append(n)
        st.ends = st.addrs[1:] + [st.addrs[-1] + 0x1000 if st.addrs else 0]
        st.source = source
        st.count = len(st.addrs)
        return st

    @classmethod
    def from_file(cls, path):
        p = Path(path)
        return cls.from_text(p.read_text(encoding="utf-8", errors="replace"), str(p))

    def lookup(self, pc):
        """(name, start, offset) or (None, None, None)."""
        if not self.addrs:
            return None, None, None
        i = bisect.bisect_right(self.addrs, pc) - 1
        if i < 0 or pc >= self.ends[i]:
            return None, None, None
        return self.names[i], self.addrs[i], pc - self.addrs[i]

    def is_entry(self, pc):
        if not self.addrs:
            return False
        i = bisect.bisect_left(self.addrs, pc)
        return i < len(self.addrs) and self.addrs[i] == pc

    # The distance to the next symbol is the function size ONLY inside one
    # contiguous text region. At the edge of a region the next symbol points
    # into a different address space, and the "size" becomes the gap: measured
    # 1,522,223,620 B for `handshake` (the last symbol before the jump from
    # the physical to the virtual kernel copy). A treemap with a rectangle
    # like that is not merely ugly, it is wrong.
    MAX_FUNC_BYTES = 8192

    def sizes(self):
        """(name, addr, size, clamped) per symbol.

        `size` is the distance to the next symbol, capped at MAX_FUNC_BYTES;
        `clamped` says whether it was capped -- that lets the caller show how
        much of the area is an estimate rather than a measurement.
        """
        for i, a in enumerate(self.addrs):
            raw = max(0, self.ends[i] - a)
            yield self.names[i], a, min(raw, self.MAX_FUNC_BYTES), raw > self.MAX_FUNC_BYTES


class CallSites:
    """Call and return sites from `dis_to_symbols.py --sites`.

    The point is exactness instead of heuristics: whether a control transfer
    is a call is decided by the INSTRUCTION at the departure address (`jal`/
    `jalr` with rd=ra), not by whether the target happens to be the start of a
    symbol. The latter was measurably wrong -- assembler labels such as
    `_try_lottery` in OpenSBI are jump targets, not functions.
    """

    LINE = re.compile(r"^([CR])\s+([0-9a-fA-F]+)\s*$")

    def __init__(self):
        self.calls = set()
        self.rets = set()
        self.source = None

    @property
    def count(self):
        return len(self.calls) + len(self.rets)

    @classmethod
    def from_text(cls, text, source=None):
        cs = cls()
        for line in text.splitlines():
            m = cls.LINE.match(line)
            if not m:
                continue
            (cs.calls if m.group(1) == "C" else cs.rets).add(int(m.group(2), 16))
        cs.source = source
        return cs

    @classmethod
    def from_file(cls, path):
        p = Path(path)
        return cls.from_text(p.read_text(encoding="utf-8", errors="replace"), str(p))


class PcStreamAnalysis:
    """One decoded PC window, analysed.

    On call depth: a return target is checked not only against the topmost
    frame but against the topmost `UNWIND_SEARCH` frames. That is not a
    softening but the correction of a real defect: trap entries and
    `mret`/`sret` leave several frames at once, and when switching from the
    physical into the virtual address space (Linux sets `satp`) the stack
    carries addresses from the OLD space. Without that search the depth runs
    away monotonically -- measured 2972 frames over one boot, which is
    obviously not a stack depth.

    If the stack still stays above `STACK_LIMIT`, the pairing is lost. Then
    `depth` returns **None** plus a `depth_note` -- an unusable number is not
    displayed.
    """

    UNWIND_SEARCH = 64          # search this many frames deep for the return target
    STACK_LIMIT = 512           # above this the pairing counts as lost

    def __init__(self, pcs, symbols, fixed_width=True, sites=None):
        self.n = len(pcs)
        self.first = pcs[0] if pcs else None
        self.last = pcs[-1] if pcs else None
        self.per_func = {}          # name -> instructions
        self.transfers = 0
        self.calls = 0
        self.returns = 0
        self.unwinds = 0            # returns across multiple frames (trap/mret)
        self.depth = None
        self.depth_note = None
        self.trail = []             # function sequence (debounced)
        self.current = None
        if not pcs:
            return

        stack = []
        # Depth only with EXACT call detection: a fixed instruction width (no
        # C extension) and the call/return sites from the listing. Without the
        # sites file it is NOT computed -- the "target is a symbol start"
        # heuristic used earlier was demonstrably wrong.
        depth_ok = bool(fixed_width and sites and sites.count)
        lost = False
        prev = None
        cur_name = None
        for pc in pcs:
            name, start, _off = symbols.lookup(pc) if symbols else (None, None, None)
            # Keyed by START ADDRESS, not by name. Reason: the same kernel
            # symbol exists twice in the listing -- once physical
            # (0x6440_0000) and once virtual (0xC000_0000). A name as the key
            # counts the instructions in BOTH regions and therefore claims
            # twice as much execution as took place (measured: an identical
            # 17,572 instructions in both regions).
            key = start if start is not None else (pc & ~0xFFF)
            self.per_func[key] = self.per_func.get(key, 0) + 1
            label = name or "0x%08x" % (pc & ~0xFFF)
            if label != cur_name:
                cur_name = label
                if not self.trail or self.trail[-1] != label:
                    self.trail.append(label)
            if prev is not None and pc != prev + 4:
                self.transfers += 1
                if depth_ok and not lost:
                    if prev in sites.calls:
                        stack.append(prev + 4)
                        self.calls += 1
                        if len(stack) > self.STACK_LIMIT:
                            lost = True
                    elif prev in sites.rets:
                        # Return: normally the topmost frame. But traps,
                        # mret/sret and the phys->virt switch leave several
                        # frames at once -- hence a bounded search downwards
                        # instead of a check against the top only.
                        hit = 0
                        for d in range(1, min(len(stack), self.UNWIND_SEARCH) + 1):
                            if stack[-d] == pc:
                                hit = d
                                break
                        if hit:
                            del stack[len(stack) - hit:]
                            if hit > 1:
                                self.unwinds += 1
                        elif stack:
                            stack.pop()          # target unknown (address space switch)
                            self.unwinds += 1
                        self.returns += 1
            prev = pc
        self.current = cur_name
        if not fixed_width:
            self.depth_note = ("call depth computable only without the C extension "
                               "(otherwise pc+4 is not a valid stride)")
        elif not (sites and sites.count):
            self.depth_note = ("no call/return sites loaded -- "
                               "dis_to_symbols.py --sites produces them")
        elif lost:
            self.depth_note = ("call/return pairing lost (>%d open frames) -- "
                               "no reliable depth" % self.STACK_LIMIT)
        else:
            self.depth = len(stack)
        self.trail = self.trail[-24:]

    def top(self, k=8):
        return sorted(self.per_func.items(), key=lambda kv: -kv[1])[:k]


class InsightState:
    """Accumulator over many live windows (hot list, coverage, rate)."""

    MAX_HIST = 120                  # Sparkline-Punkte (~2 min bei 1 s)
    # Below this instruction count, bits per instruction from a single window
    # is NOT meaningful and is therefore not reported as a measurement.
    # Reason: the decoder deliberately emits no PCs before the first sync
    # message ("Do not emit speculative PCs before the first synchronization
    # message"). The bytes up to that point still count in the denominator --
    # so a window that ends shortly before a sync, or breaks off at a stream
    # boundary, otherwise yields values like 14,560 bit/instr out of 16,380 B
    # over 9 instructions (really observed on 2026-07-28 in the browser test).
    # The distortion vanishes as the window grows; below the threshold the
    # number is omitted rather than dressed up.
    MIN_INSTR_FOR_RATIO = 1000

    def __init__(self):
        self.symbols = SymbolTable()
        self.sites = CallSites()
        self.func_counts = {}       # name -> instructions (accumulated)
        self.windows = 0
        self.total_instr = 0
        self.total_bytes = 0
        self.hist = []              # [{t, bytes_per_s, instr_per_s, bits_per_instr}]
        self.decode_seconds = 0.0
        self.decode_bytes = 0
        self.decode_instr = 0
        self.last = None            # last window evaluation (dict)
        self._last_beat = None      # (t, trace_bytes) for computing the rate

    # --- Symbols -----------------------------------------------------------
    def load_symbols(self, path):
        self.symbols = SymbolTable.from_file(path)
        return self.symbols

    def set_symbols_text(self, text, source):
        self.symbols = SymbolTable.from_text(text, source)
        return self.symbols

    def load_sites(self, path):
        self.sites = CallSites.from_file(path)
        return self.sites

    # --- Rate from the monotonic hardware counters ------------------------
    def note_counters(self, t, trace_bytes, instr_per_s=None):
        """Byte rate from two samples of the monotonic TRACE_BYTES counter.

        Returns the measured byte rate, or None on the first call and after a
        counter reset (trace_clear).
        """
        prev = self._last_beat
        self._last_beat = (t, trace_bytes)
        if prev is None or t <= prev[0] or trace_bytes < prev[1]:
            return None
        return (trace_bytes - prev[1]) / (t - prev[0])

    def push_rate(self, t, bytes_per_s, instr_per_s, bits_per_instr):
        self.hist.append({"t": t, "bps": bytes_per_s, "ips": instr_per_s,
                          "bpi": bits_per_instr})
        del self.hist[:-self.MAX_HIST]

    # --- Windows -----------------------------------------------------------
    def add_window(self, pcs, raw_bytes, decode_seconds, fixed_width=True):
        a = PcStreamAnalysis(pcs, self.symbols, fixed_width, self.sites)
        for k, v in a.per_func.items():
            self.func_counts[k] = self.func_counts.get(k, 0) + v
        self.windows += 1
        self.total_instr += a.n
        self.total_bytes += raw_bytes
        self.decode_seconds += decode_seconds
        self.decode_bytes += raw_bytes
        self.decode_instr += a.n
        valid = a.n >= self.MIN_INSTR_FOR_RATIO
        self.last = {
            "instr": a.n,
            "bytes": raw_bytes,
            "bits_per_instr": (raw_bytes * 8.0 / a.n) if (a.n and valid) else None,
            "bits_per_instr_note": None if valid else (
                "window yielded only %d instructions (<%d): the bytes before the "
                "first sync message count in the denominator, so the ratio "
                "would be skewed" % (a.n, self.MIN_INSTR_FOR_RATIO)),
            "current": a.current,
            "trail": a.trail,
            "depth": a.depth,
            "depth_note": a.depth_note,
            "calls": a.calls,
            "returns": a.returns,
            "unwinds": a.unwinds,
            "transfers": a.transfers,
            "first_pc": a.first,
            "last_pc": a.last,
            "top": [{"name": n, "instr": c} for n, c in a.top(10)],
            "decode_seconds": decode_seconds,
        }
        return self.last

    # --- Aggregate -------------------------------------------------------
    def name_of(self, key):
        """Display name for a func_counts key (start address)."""
        if isinstance(key, int):
            n, s, _ = self.symbols.lookup(key)
            if n and s == key:
                return n
            return "0x%08x" % key
        return str(key)

    def hot(self, k=15):
        # `addr` as a HEX STRING: an RV64 kernel address exceeds 2**53 and as
        # a JSON number would be rounded in the browser before it is displayed
        # (0xFFFFFFC0_00xxxxxx -> ...00000000). See test_addr64.mjs.
        tot = sum(self.func_counts.values()) or 1
        rows = sorted(self.func_counts.items(), key=lambda kv: -kv[1])[:k]
        return [{"name": self.name_of(a),
                 "addr": ("0x%x" % a) if isinstance(a, int) else None,
                 "instr": c, "share": c / tot} for a, c in rows]

    def coverage(self):
        """Function coverage over ALL windows decoded so far.

        Explicitly: function coverage, not instruction coverage, and only over
        the windows that were actually decoded -- no claim about a complete
        run. Without a symbol table there is no reference size and therefore
        no ratio either.
        """
        total = self.symbols.count
        if not total:
            return {"total": 0, "seen": 0, "share": None,
                    "note": "no symbol table loaded -- no reference, so no ratio"}
        known = set(self.symbols.addrs)
        seen = len([a for a in self.func_counts if a in known])
        return {"total": total, "seen": seen, "share": seen / total,
                "scope": "function-level coverage over %d decoded windows "
                         "(%d instructions), not over the whole run"
                         % (self.windows, self.total_instr)}

    def decoder_throughput(self):
        """The measured decoder throughput of THIS host (MB/s and Minstr/s)."""
        if self.decode_seconds <= 0 or not self.decode_bytes:
            return None
        return {
            "mb_per_s": self.decode_bytes / self.decode_seconds / 1e6,
            "minstr_per_s": self.decode_instr / self.decode_seconds / 1e6,
            "samples": self.windows,
            "seconds": self.decode_seconds,
            "bytes": self.decode_bytes,
            "instr": self.decode_instr,
        }

    def reset(self):
        self.func_counts.clear()
        self.windows = self.total_instr = self.total_bytes = 0
        self.decode_seconds = 0.0
        self.decode_bytes = self.decode_instr = 0
        self.hist.clear()
        self.last = None
        self._last_beat = None

    def to_json(self):
        return {
            "windows": self.windows,
            "total_instr": self.total_instr,
            "total_bytes": self.total_bytes,
            "symbols": {"count": self.symbols.count, "source": self.symbols.source,
                        "call_sites": len(self.sites.calls),
                        "ret_sites": len(self.sites.rets),
                        "sites_source": self.sites.source},
            "last": self.last,
            "hot": self.hot(),
            "coverage": self.coverage(),
            "decoder": self.decoder_throughput(),
            "hist": self.hist[-self.MAX_HIST:],
            "t": time.time(),
        }


# ---------------------------------------------------------------------------
# Nexus message statistics straight off the wire bytes
# ---------------------------------------------------------------------------
# Deliberately WITHOUT the decoder: the MSEO framing is enough for the
# distribution of message types. A byte with MSEO='11' ends a message, the
# next byte with MSEO='00' starts the next one, and its top six bits are the
# TCODE. That is one pass over the window and costs nothing -- a full decode
# once per second would be unaffordable on the board (measured: reading the
# 114 MiB pcinfo alone costs 18 s).
TCODE_NAMES = {
    3: "DirectBranch", 4: "IndirectBranch", 8: "Error", 9: "ProgTraceSync",
    11: "DirectBranchSync", 12: "IndirectBranchSync", 27: "ResourceFull",
    28: "IndirectBranchHist", 29: "IndirectBranchHistSync",
    31: "RepeatBranch", 32: "RepeatInstruction", 33: "ProgTraceCorrelation",
    56: "Vendor-BranchPredict", 57: "Vendor-JumpTargetCache",
    58: "Vendor-Config",
}


def scan_messages(raw: bytes):
    """(counts per TCODE, message count, idle bytes) of a wire window.

    The first, partially cut fragment is skipped -- counting starts at the
    first complete message boundary, otherwise a randomly cut byte would count
    as a message type.
    """
    counts = {}
    msgs = 0
    idle = 0
    started = False
    prev_end = False
    for b in raw:
        mseo = b & 0x3
        if mseo == 0x3 and (b >> 2) == 0x3F:
            idle += 1
            prev_end = True
            continue
        if prev_end and mseo == 0x0:
            started = True
            t = (b >> 2) & 0x3F
            counts[t] = counts.get(t, 0) + 1
            msgs += 1
        prev_end = (mseo == 0x3)
    return counts, msgs, idle, started


def parse_pcout(data: bytes, limit=None):
    """`.pcout` (one `0x%08x` line per instruction) -> list of ints."""
    out = []
    for line in data.split(b"\n"):
        line = line.strip()
        if not line:
            continue
        try:
            out.append(int(line, 16))
        except ValueError:
            continue
        if limit and len(out) >= limit:
            break
    return out
