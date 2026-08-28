# riscv-trace-spec referenceFlow models (vendored subset)

Vendored from https://github.com/riscv-non-isa/riscv-trace-spec
commit `b76926ffdf32e42e2c82f09a4586f6da80a616e5` (main, 2026-07-20), 2026-07-24.

Contents: the pure-Python E-Trace reference models from `referenceFlow/scripts/`
(`encoder_model.py`, `decoder_model.py`, `te_inst_deserialiser.py`, `common/`).
License: **BSD-2-Clause, Copyright 2019-2021 Siemens** (headers retained in every
file). The models implement the *baseline* algorithm of "Efficient Trace for
RISC-V" (v2.0 lineage, references to 1.1.3-Frozen in the docstrings).

**Two licences, do not mix them up.** The code vendored here is BSD-2-Clause,
as its per-file headers say. Upstream's repository-level licence document is
copied alongside as `UPSTREAM-SPEC-LICENSE-CC-BY-4.0.txt`; it carries the
CC-BY-4.0 legal code, which upstream applies to the trace *specification
document*, not to these Python models. The file used to be named `LICENSE`,
which read like the licence of this directory and was silently skipped by
`reuse` on top of that -- hence the explicit name and this paragraph.

Files are verbatim — **no local modifications**; the only deviation from
upstream in this directory is the *name* of the licence document above,
its content is byte-identical to upstream's `LICENSE`. Accemic drivers that import
these modules (config injection, synthetic-listing ElfData replacement) live in
`tools/etrace/`, so the vendored code stays pristine and diffable against
upstream.

Wire format produced/consumed by the models (`common/raw_write.py` /
`common/raw_file.py`), used 1:1 by the CTTE E-Trace backend (`CT_EN_ETRACE`):

- per packet: 1 header byte = `payload_len[4:0] | (msg_type << 5)`,
  msg_type 2 = te_inst; then `payload_len` payload bytes, little-endian
  (first payload byte carries the packet's LSBs: `format` in bits [1:0]).
- whole-packet sign-based compression: identical MSBs collapse to one sign
  bit, then sign-padded up to the next byte boundary.
