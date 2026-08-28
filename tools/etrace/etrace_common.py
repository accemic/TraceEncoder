# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
Shared glue for driving the vendored riscv-trace-spec reference models
(third_party/riscv-trace-spec-ref, BSD-2-Clause Siemens) without modifying
them: sys.path setup, static/user config factories matching the CTTE
E-Trace build parameters, and a synthetic-listing ElfData replacement.

The parameter set here is the single source of truth for BOTH sides of the
cross-validation: rtl/pkg/ct_pkg.sv (CT_ETRACE_* localparams) must match.
"""

import configparser
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.normpath(
    os.path.join(HERE, "..", "..", "third_party", "riscv-trace-spec-ref", "scripts")
)
sys.path.insert(0, VENDOR)

# CTTE E-Trace build parameters (mirror of ct_pkg.sv CT_ETRACE_*)
IADDRESS_WIDTH = 32
IADDRESS_LSB = 1
PRIVILEGE_WIDTH = 3
ECAUSE_WIDTH = 4
RESYNC_MAX = 10  # model: resync_max = 1 << (RESYNC_MAX + 4); MVP: effectively off


def make_scf():
    scf = configparser.ConfigParser()
    scf["Required Attributes"] = {
        "bpred_size_p": "9",
        "cache_size_p": "6",
        "call_counter_size_p": "0",
        "return_stack_size_p": "0",
        "context_width_p": "1",
        "ecause_width_p": str(ECAUSE_WIDTH),
        "iaddress_width_p": str(IADDRESS_WIDTH),
        "privilege_width_p": str(PRIVILEGE_WIDTH),
        "time_width_p": "1",
        "iaddress_lsb_p": str(IADDRESS_LSB),
        "nocontext_p": "1",
        "notime_p": "1",
    }
    return scf


def make_ucf(file_stem="etrace"):
    ucf = configparser.ConfigParser()
    ucf["required"] = {"file-stem": file_stem, "object-files": ""}
    ucf["codec"] = {
        "resync-max": str(RESYNC_MAX),
        "full-address": "false",
        "implicit-except": "false",
        "si-jump": "false",
        "implicit-return": "false",
        "branch-prediction": "false",
        "jump-target-cache": "false",
    }
    ucf["flags"] = {"use-rv32-isa": "true"}
    return ucf


def make_args(debug=False, sijump=False):
    """Namespace stand-in for the argparse globals the vendored modules use."""
    return types.SimpleNamespace(
        debug=debug, annotate=False, expected=None, decoder_input=None,
        sijump=sijump
    )



# ---- te_data / vendor-DAQ packet parsers -------------------------------
# The vendored reference models implement NO data trace (audited 2026-07-25:
# no model class, no deserialiser, dangling common/data_trace reference) --
# these parsers follow the dataTracePayload spec tables verbatim (unified
# load/store subset the CTTE DF path emits: format field 2 bits) plus the
# Accemic vendor DAQ packet (raw-framing msg_type 1: idtag[7:0] + 3x64-bit
# DQM elements, element 0 in the LSBs). Same disclosure as Format 0.

def parse_te_data(packet):
    d = {}
    packet.set_output(d)
    fmt = packet.get_bits("format", 2)
    sz = packet.get_bits("size", 2)
    diff = packet.get_bits("diff", 2)
    dl = packet.get_bits("data_len", sz) if sz else 0
    v = packet.get_bits("data", 8 * (dl + 1))
    a = packet.get_bits("address", 32)
    packet.check()
    nbytes = 1 << sz
    w = 8 * (dl + 1)
    if (v >> (w - 1)) & 1:                      # sign-extend to access width
        v |= ((1 << (8 * nbytes)) - 1) ^ ((1 << w) - 1)
    d.update(format=fmt, size=sz, diff=diff, data_len=dl,
             kind="S" if (fmt & 2) else "L",
             addr=a if (fmt & 1) else (a << sz) & 0xFFFFFFFF,
             nbytes=nbytes, value=v & ((1 << (8 * nbytes)) - 1))
    return d


def parse_daq(packet):
    d = {}
    packet.set_output(d)
    idtag = packet.get_bits("idtag", 8)
    data = packet.get_bits("data", 192)
    packet.check()
    d.update(idtag=idtag, data=data)
    return d


def make_ext_decoder(dm):
    """
    Decoder subclass implementing the optional-mode HOOKS the vendored
    baseline model deliberately stubs out (is_implicit_return returns False,
    push/pop_return_stack are no-ops). The vendored file stays verbatim.

    Implicit-return (activated by the stream itself via the SUPPORT packet's
    ioptions bit 0, model process_support): the decoder mirrors the encoder's
    return-address stack -- push the return address at every walked call, pop
    at a return when the stack is non-empty. A mispredicted (hence reported)
    return whose stack top differs would diverge loudly in cross-validation;
    the CTTE composer flags those and the encoder reports them explicitly.
    """

    class ExtDecoder(dm.Decoder):
        def is_implicit_return(self, instr):
            if not self.settings.get("implicit-return", False):
                return False
            is_ret = (
                instr.opcode == "jalr"
                and instr.rd == 0
                and instr.rs1 == 1
                and (instr.imm or 0) == 0
            ) or (instr.opcode in ("c.jr",) and instr.rs1 == 1)
            return is_ret and len(self.return_stack) > 0

        def push_return_stack(self, address):
            if not self.settings.get("implicit-return", False):
                return
            instr = self.get_instr(address)
            self.return_stack.append(address + instr.size)

        def pop_return_stack(self):
            return self.return_stack.pop()

        # Sequentially-inferable jumps (CT_SIJUMP adapter convention: an
        # adjacent auipc rd,imm / jalr _,rd,imm2 pair): the encoder side is
        # silent by construction (the adapter reclassifies the jalr as
        # INFERABLE before the eTIP), the decoder infers the target from the
        # listing pair. Synthetic cpu_model listings never contain auipc, so
        # this only engages on real-objdump (SoC) flows.
        def is_sequential_jump(self, instr, last_pc):
            if not getattr(dm.args, "sijump", False):
                return False
            if instr.opcode != "jalr" or instr.rs1 is None:
                return False
            # RETURN / CO_ROUTINE_SWAP keep stack semantics (rs1 is a link
            # register and rd differs; rd == rs1 is a plain uninferable
            # CALL per the itype table and folds like any other pair).
            if instr.rs1 in (1, 5) and instr.rd != instr.rs1:
                return False
            if instr.rs1 == 0:         # constant base: statically inferable
                return True
            prev = self.elf_data.instr.get(last_pc) if hasattr(
                self.elf_data, "instr") else None
            return (prev is not None and prev.opcode in ("auipc", "lui")
                    and prev.rd == instr.rs1)

        def sequential_jump_target(self, pc, last_pc):
            instr = self.elf_data.instr[pc]
            if instr.rs1 == 0:
                return (instr.imm or 0) & ~1
            # U-type operand in the listing is the ABSOLUTE register value
            # (objdump2listing rewrites it); the vendored U-type parser
            # stores imm = value - address, so last_pc + imm = value.
            prev = self.elf_data.instr[last_pc]
            return ((last_pc + prev.imm) + (instr.imm or 0)) & ~1

        # The MBV adapter never folds a bare jalr statically -- only the
        # sijump pair rule above does. The base model's jalr-x0 arm would
        # also miscompute the target (incr_pc on an absolute immediate).
        def is_inferable_jump(self, instr):
            if instr.opcode == "jalr":
                return False
            return super().is_inferable_jump(instr)

        def is_uninferable_jump(self, instr):
            if (instr.opcode == "jalr" and instr.rs1 == 0
                    and not getattr(dm.args, "sijump", False)):
                return True   # adapter reports it when sijump is off
            return super().is_uninferable_jump(instr)

        # ---- Format 0 (optional efficiency extensions) ----------------
        # No open third-party F0 implementation exists (riscv-trace-spec
        # models and pulp rv_tracer both stub it out) -- this parser follows
        # the spec payload tables verbatim; wire-format confidence therefore
        # rests on the spec text plus the N-Trace-cross-validated semantic
        # models, NOT on an independent implementation (documented).
        JTC_ENTRIES = 64

        def __init__(self, *a, **kw):
            super().__init__(*a, **kw)
            self.jtc = {}
            # Branch-prediction mirror (encoder-identical: 2^9 x 2-bit
            # saturating counters, index iaddr[10:2], init weakly-not-taken;
            # updated at EVERY resolved direct branch).
            self.bp_table = {}
            self.bp_pending = 0     # predictor-resolved branches to walk
            self.bp_fail = False    # ... plus one inverted (mispredict)

        @staticmethod
        def _jtc_idx(addr):
            return ((addr >> 2) ^ (addr >> 8) ^ (addr >> 14) ^ (addr >> 20)) & 0x3F

        def create_te_inst(self, msg_type, packet_length, packet):
            # TE_DATA (3) and vendor DAQ (1) packets carry no PC movement:
            # parse them (validates + consumes the payload) and skip.
            if msg_type == 3:
                parse_te_data(packet)
                return None
            if msg_type == 1:
                parse_daq(packet)
                return None
            # peek format bits without consuming: RawPacket only reads LSB-
            # first, so parse format here and dispatch F0 ourselves.
            from common.inst_trace import format_t
            te_inst = {}
            packet.set_output(te_inst)
            packet.get_bits("format", 2)
            if te_inst["format"] != 0:
                # re-dispatch the remaining fields exactly like the base
                if te_inst["format"] == format_t.SYNC:
                    self.create_sync(packet, te_inst)
                elif te_inst["format"] == format_t.ADDR:
                    self.create_addr(packet, te_inst)
                else:
                    self.create_branch(packet, te_inst)
                import decoder_model as _dm
                return _dm.TeInst(**te_inst)
            # ---- Format 0: subformat(1) then per-subformat fields -----
            packet.get_bits("subformat", 1)
            if te_inst["subformat"] == 1:
                packet.get_bits("index", 6)
                packet.get_bits("branches", 5)
                if te_inst["branches"] != 0:
                    def mapbits(b):
                        return 1 if b <= 1 else 3 if b <= 3 else 7 if b <= 7                             else 15 if b <= 15 else 31
                    packet.get_bits("branch_map", mapbits(te_inst["branches"]))
                packet.get_bits("irreport", 1)
            else:
                packet.get_bits("branch_count", 32)
                packet.get_bits("branch_fmt", 2)
                if te_inst["branch_fmt"] in (2, 3):
                    packet.get_bits(
                        "address",
                        self.settings["iaddress_width_p"]
                        - self.settings["iaddress_lsb_p"], is_hex=True)
                    packet.get_bits("notify", 1)
                    packet.get_bits("updiscon", 1)
                    packet.get_bits("irreport", 1)
            packet.check()
            import decoder_model as _dm
            return _dm.TeInst(**te_inst)

        def process_te_inst(self, te_inst):
            if getattr(te_inst, "format", None) == 0:
                if te_inst.subformat == 1:
                    # F0.1: absolute target from the mirrored cache; then
                    # exactly the F1-with-address / F2 walk semantics.
                    idx = te_inst.index
                    if idx not in self.jtc:
                        print("Error: JTC index %d not in decoder cache" % idx)
                        raise SystemExit(1)
                    # A cache hit IS a discontinuity-target report (entries
                    # are only ever installed at reported updiscon targets),
                    # and the packet has no notify/updiscon trailer -- so the
                    # walk must not stop at a linear arrival at the target.
                    # Same disambiguation the encoder signals explicitly via
                    # the updiscon flag on F1/F2/F0.0 target reports.
                    self.flags["notify"] = False
                    self.flags["updiscon"] = True
                    self.flags["irreport"] = False
                    self.stop_at_last_branch = False
                    self.address = self.jtc[idx]
                    if te_inst.branches:
                        self.branch_map |= (te_inst.branch_map << self.branches)
                        self.branches += te_inst.branches
                    self.follow_execution_path(self.address, te_inst)
                    return
                # F0.0 handled in the BP stage (see bp fields)
                self._process_f00(te_inst)
                return
            from common.inst_trace import format_t, sync_t
            if (te_inst.format == format_t.SYNC
                    and te_inst.subformat == sync_t.START
                    and te_inst.address == 0):
                # Mirror of the vendored SYNC/START arm minus its nonzero
                # sanity assert: PC 0x0 is a legitimate reset vector on the
                # MBV SoC (BRAM base), the model just never expected it.
                self.inferred_address = False
                self.address = 0
                if self.start_of_trace:
                    self.branches = 0
                    self.branch_map = 0
                if self.get_instr(self.address).is_branch:
                    self.branch_map |= te_inst.branch << self.branches
                    self.branches += 1
                if not self.start_of_trace:
                    self.follow_execution_path(self.address, te_inst)
                else:
                    self.set_pc(self.address)
                    self.report_pc(self.pc)
                    self.last_pc = self.pc
                self.start_of_trace = False
                self.irstack_depth = 0
                return
            super().process_te_inst(te_inst)

        def _process_f00(self, te_inst):
            if not self.settings.get("branch-prediction", False):
                raise SystemExit("F0.0 packet but branch-prediction not "
                                 "announced in the SUPPORT ioptions")
            count = te_inst.branch_count + 31
            if te_inst.branch_fmt == 0:
                # no address: walk count predictor-resolved branches plus
                # the one that failed; ends right behind the failed branch
                self.bp_pending += count
                self.bp_fail = True
                while self.bp_pending or self.bp_fail:
                    stop = self.next_pc(0)
                    self.report_pc(self.pc)
                    if stop:
                        raise SystemExit("F0.0 walk hit an uninferable "
                                         "discontinuity -- stream corrupt")
                return
            if te_inst.branch_fmt == 2:
                # with address: the count rides an updiscon/trap report;
                # exactly the F2 walk with predictor-resolved branches.
                # The vendored flag decompression only covers ADDR/BRANCH
                # formats -- decompress the F0.0 trailer here the same way
                # (the encoder sets the updiscon flag on target reports).
                msb = 0 if (self.msb_mask & (
                    te_inst.address << self.settings["iaddress_lsb_p"])) == 0 else 1
                self.flags["notify"] = te_inst.notify != msb
                self.flags["updiscon"] = te_inst.updiscon != te_inst.notify
                self.flags["irreport"] = te_inst.irreport != te_inst.updiscon
                self.bp_pending += count
                self.stop_at_last_branch = False
                from common.utils import twoscomp
                addr = te_inst.address << self.settings["iaddress_lsb_p"]
                if self.settings.get("full-address"):
                    self.address = addr
                else:
                    self.address += twoscomp(
                        addr, self.settings["iaddress_width_p"])
                self.follow_execution_path(self.address, te_inst)
                return
            raise SystemExit("F0.0 branch_fmt=11 (addr-fail) not exercised "
                             "by this flow -- unsupported in the mirror")

        def is_taken_branch(self, instr):
            if not instr.is_branch:
                return False
            if self.settings.get("branch-prediction", False):
                idx = (instr.address >> 2) & 0x1FF
                ctr = self.bp_table.get(idx, 1)
                pred = ctr >= 2
                if self.branches > 0:
                    # A map bit left over from a previous packet (the walk
                    # stops AT the final branch) outranks the F0.0 count.
                    taken = super().is_taken_branch(instr)
                elif self.bp_pending > 0:
                    taken = pred
                    self.bp_pending -= 1
                elif self.bp_fail:
                    taken = not pred
                    self.bp_fail = False
                else:
                    taken = super().is_taken_branch(instr)
                self.bp_table[idx] = min(3, ctr + 1) if taken                     else max(0, ctr - 1)
                return taken
            return super().is_taken_branch(instr)

        def next_pc(self, address):
            prev_pc = self.pc
            fold = self.is_implicit_return(self.get_instr(prev_pc))
            stop = super().next_pc(address)
            # Mirror of the encoder's JTC install rule: every uninferable-
            # discontinuity target it walks to (idempotent on F0.1 hits).
            # Folded returns are NOT reported by address, so the encoder
            # never installs them -- the mirror must not either.
            if (stop and not fold
                    and self.settings.get("jump-target-cache", False)
                    and self.pc == address):
                instr = self.get_instr(prev_pc)
                if self.is_uninferable_discon(instr):
                    self.jtc[self._jtc_idx(address)] = address
            # Implicit-return fold arriving AT the reported address ends the
            # walk like an explicit discontinuity arrival: the fold IS an
            # uninferable discontinuity, merely silent on the wire, and the
            # vendored stop conditions cannot see it (the IR arm of next_pc
            # is a no-cover stub upstream). Without this, a flush whose
            # target is reached by a fold walks straight past the flush
            # point (P10 soak S-1 family, seed 119061181: pre-trap flush to
            # 0x102d4 reached via a folded return, decoder ran away).
            # Guarded on an exhausted branch map: an INTERIOR fold that
            # happens to touch the address while bits are pending is not
            # the packet's endpoint. (Two interior folds onto the same
            # address with an empty map between them remain inexpressible
            # without irdepth -- irdepth width is 0 on this wire; known
            # dialect disclosure.)
            if (fold and self.pc == address
                    and not self.stop_at_last_branch
                    and self.branches <= (
                        1 if self.get_instr(self.pc).is_branch else 0)):
                stop = True
            return stop

        def process_support(self, te_inst):
            super().process_support(te_inst)
            from common.inst_trace import qual_status_t
            if te_inst.qual_status != qual_status_t.NO_CHANGE:
                self.jtc.clear()        # decoder restarts cold
                self.bp_table.clear()   # (encoder mirrors via epoch bump)
                self.bp_pending = 0
                self.bp_fail = False
                # Implicit-return mirror: the composer empties its return
                # stack at the trace-off edge and at the FIFO_OVERRUN anchor
                # (ct_L23_preproc_composer_etip.sv, both with the "clearing
                # is always SAFE" rationale) -- both reach the wire as a
                # SUPPORT packet with qual_status != NO_CHANGE. A stale
                # mirror frame surviving here would fold a post-recovery
                # return the encoder reports explicitly (P10 soak S-1
                # family, overflow leg).
                self.return_stack.clear()
                self.irstack_depth = 0

    return ExtDecoder


class ListingData:
    """
    ElfData replacement fed from a pre-generated objdump-style listing file
    (tab-separated "ADDR:\\tHEX\\topcode\\targs" lines, as produced by
    pcinfo2listing.py). Duck-types ElfData: only .get() is used by the
    decoder. No spike startup stub is injected.
    """

    def __init__(self, decoder_model_module, listing_path, tolerant=False):
        """`tolerant`: skip listing lines the reference Instruction parser
        rejects instead of aborting. Needed for listings disassembled from a
        RAW BINARY image (no section info, so data words decode as bogus
        opcodes). A skipped address is not silently wrong: if the decode ever
        walks onto it, get() reports "not found in listing" and exits.
        """
        self._dm = decoder_model_module
        self.instr = {}
        self.skipped = 0
        with open(listing_path) as fd:
            for line in fd:
                line = line.rstrip("\n")
                fields = line.split("\t")
                if len(fields) < 3:
                    continue
                address = int(fields[0].strip(" ").rstrip(":"), 16)
                assert address not in self.instr, "0x%x already added" % address
                try:
                    self.instr[address] = self._dm.Instruction(address, fields)
                except (AssertionError, ValueError, IndexError):
                    if not tolerant:
                        raise
                    self.skipped += 1
        if tolerant and self.skipped:
            print("ListingData: %d unparsable lines skipped (raw-binary listing)"
                  % self.skipped)

    def get(self, address):
        if address not in self.instr:
            print("Error: Instruction at address 0x%x not found in listing" % address)
            sys.exit(1)
        return self.instr[address]
