# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
Deserialize a raw te_inst byte stream (reference-raw framing) and print one
line per packet with all decoded fields — the E-Trace sibling of a Nexus
message dump. Uses the vendored reference deserializer unmodified.

Usage: py dump_te.py <stream.te_inst_raw>
"""

import sys

import etrace_common


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1

    import decoder_model as dm
    from common.raw_file import RawFile
    from common import utils

    utils.init_debug(False)
    dm.args = etrace_common.make_args()
    scf = etrace_common.make_scf()

    class NullElf:
        def get(self, a):
            raise SystemExit("dump_te does not walk the program image")

    dec = etrace_common.make_ext_decoder(dm)(scf, sys.stdout, NullElf(), expected=[])
    n = 0
    with open(sys.argv[1], "rb") as fd:
        rf = RawFile(fd)
        while rf.has_data():
            def handler(mt, ln, pkt):
                if mt == 3:
                    return ("td", etrace_common.parse_te_data(pkt))
                if mt == 1:
                    return ("daq", etrace_common.parse_daq(pkt))
                return ("ti", dec.create_te_inst(mt, ln, pkt))
            tag, te = rf.process_packet(handler)
            n += 1
            if tag == "td":
                print("%3d tdat %s addr=%s bytes=%d value=%s (fmt=%d diff=%d)"
                      % (n, te["kind"], hex(te["addr"]), te["nbytes"],
                         hex(te["value"]), te["format"], te["diff"]))
                continue
            if tag == "daq":
                print("%3d vdaq idtag=%s data=%s"
                      % (n, hex(te["idtag"]), hex(te["data"])))
                continue
            d = {k: v for k, v in te.__dict__.items() if v is not None}
            fmt = d.pop("format", None)
            sub = d.pop("subformat", None)
            head = "f%s%s" % (getattr(fmt, "value", fmt),
                              getattr(sub, "value", "") if sub is not None else "")
            flat = " ".join(
                "%s=%s" % (k, hex(v) if k in ("address", "tval") and isinstance(v, int)
                           else getattr(v, "value", v))
                for k, v in d.items())
            print("%3d %-4s %s" % (n, head, flat))
    print("# %d packets" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
