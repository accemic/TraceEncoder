<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# Verification — test harness in a nutshell

A scripted CPU model is **both the stimulus and the answer key**: it drives
the encoder's instruction input *and* records what it executed. The encoder
turns that into an N-Trace byte stream; an independent reference decoder
(NexRv) turns the bytes back into a trace, which is compared to what the
model recorded. If the encoder mangles the trace, the reconstruction won't
match — and the check fails.

```mermaid
flowchart LR
    CPU["cpu_model<br/>scripted RISC-V core"]
    DUT["ct_encoder<br/>(DUT)"]
    BIN[".atb.bin<br/>N-Trace bytes"]
    NEXRV["NexRv<br/>reference decoder"]
    REF["expected<br/>PCs · data · CTXP"]
    CHK{"compare"}
    RES(["PASS / FAIL"])

    CPU -->|drives TIP| DUT -->|trace bytes| BIN --> NEXRV -->|PCs · CTXP| CHK
    CPU -.->|records what it ran| REF --> CHK
    CHK --> RES
```

NexRv reconstructs two views from the bytes: the **PC stream** (instruction
trace) and the **CTXP** export — C-Trace eXPort records for control flow
(`SYNC`, `BRANCH_*`, `CALL`, `RETURN`), memory accesses (`MEMREAD_n` /
`MEMWRITE_n`, with the data value) and instrumentation (`DAQ_*`). The cpu_model
emits the matching expected files, and each is compared.

- **Stimulus & reference** — `cpu_model` ([`tests/lib/cpu_model.sv`](../tests/lib/cpu_model.sv)): task-based scripted core (`run`, `branch_taken`, `load_data`, …); the harness `ctrace_env` wires it to the DUT.
- **Decoder** — [`bin/NexRv`](../bin/NexRv): the RISC-V N-Trace reference decoder, independent of C-Trace.
- **Check** — [`scripts/decode_and_check.sh`](../scripts/decode_and_check.sh): `--pc` (PC stream), `--ctxp` (CTXP records — memory accesses *with data values*, and DAQ instrumentation), `--data` (loads/stores, addr+size only), `--sync N`, `--disabled` (trace-off message). The memory test and the DAQ test compare via `--ctxp`; the combined test keeps `--data` (with both instruction and data tracing on, CTXP record order is not program order).

Run `make sim` (all tests + a per-category PASS/FAIL summary) or `make sim-<name>` (one). Scenarios live under [`tests/`](../tests/).
