<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# E-Trace host tools

Accemic-side drivers around the **vendored** RISC-V trace-spec reference
models in [`../../third_party/riscv-trace-spec-ref/`](../../third_party/riscv-trace-spec-ref/)
(BSD-2-Clause, Siemens). The models stay pristine and diffable against
upstream — everything this repository needs to drive them (config injection,
a synthetic listing in place of an ELF, CTXP export) lives here instead of as
a patch over there.

That separation is the point of the directory: when a CTTE E-Trace stream and
the reference disagree, the reference is known to be unmodified.

| File | Role |
|---|---|
| `etrace_common.py` | The glue: `sys.path` setup, static/user config factories matching the CTTE E-Trace build parameters, synthetic-listing `ElfData` replacement. Everything else imports this. |
| `etrace_decode.py` | Raw `te_inst` byte stream + listing → reconstructed PC sequence (one hex PC per line). The workhorse of the `cli_etrace*` gates. |
| `etrace_ctxp_ref.py` | The same input decoded into CTXP control-flow records — a second, independent decoder over identical bytes, so the CTTD exporter is audited rather than trusted. |
| `dump_te.py` | One line per packet with all decoded fields; the E-Trace sibling of a Nexus message dump. |
| `etrace_data_check.py` | Cross-validates data-trace (DF) and vendor-DAQ packets against the testbench oracles. |
| `mk_goldvec.py` | Golden-vector generator: reference encoder → `.te_inst_raw` → reference decoder round-trip (`tests/etrace/vectors/`). |
| `pcinfo2listing.py` | NexRv PCInfo → synthetic objdump-style listing (the decoder classifies by mnemonic, so a canonical instruction per type is enough). |
| `objdump2listing.py` | Real `riscv objdump -d -M no-aliases,numeric` output → the same 4-field listing format. |

## Usage

The tools are normally invoked by the gate scripts
([`../../scripts/cli_etrace_test.sh`](../../scripts/cli_etrace_test.sh),
`cli_etrace_ctxp_test.sh`), which is also where a worked call sequence can be
read off. Standalone:

```
py tools/etrace/dump_te.py <stream.te_inst_raw>
py tools/etrace/pcinfo2listing.py <run.nexrv.info> <run.objdump>
py tools/etrace/etrace_decode.py -i <stream.te_inst_raw> -l <run.objdump> -o <run.pctrace>
```

Prerequisite is `py`/`python3` only — these are pure-Python host tools; no
simulator and no board is involved.
