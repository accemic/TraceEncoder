<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/cva6_linux/board — boot Linux on the CVA6, captured with CTTE

`cva6_linux_boot_trace.sh` boots Linux on the CVA6 in the KV260's PL and
captures the boot with CTTE: it prepares the board, writes the Linux
payload into the reserved DDR window, arms the encoder, boots, pulls back
the console and trace rings, and gates on `OpenSBI`/`Linux version`/a
non-empty ring.

Bash port of an internal predecessor repository's PowerShell script
(Gate L6/L7), including that script's 2026-08-17 state (`-SyncMax`
parameter, the `mem_load.py` payload loader). The full port log is an
internal document and is not part of this repository.

## Deployment is a prerequisite, not this script's job

Same division of labour as the PowerShell original: the bitstream
`cva6_linux_kv260_top` must already be a loadable board app named `--app`
before running this script. Package + deploy it first, the same way
[`../../duo/board/duo_board_gate.sh`](../../duo/board/duo_board_gate.sh)
does end-to-end:

```bash
py examples/kv260/common/board/package_kv260_app.py \
    --bit examples/kv260/cva6_linux/fpga/proj_linux/cva6_linux_kv260.runs/impl_1/cva6_linux_kv260_top.bit \
    --app cva6_linux_ctrace_kv260
examples/kv260/common/board/deploy_kv260_app.sh --app-dir <printed app-dir>
```

## Usage

```bash
# Default: stream the payload from the build host (a Linux machine's
# sw/cva6_linux/build_payload.sh output), N-Trace, 3 s capture:
examples/kv260/cva6_linux/board/cva6_linux_boot_trace.sh

# Re-run just the arm/boot/capture steps (payload already in the window):
examples/kv260/cva6_linux/board/cva6_linux_boot_trace.sh --skip-load

# Stage a payload built locally instead of streaming from the build host:
examples/kv260/cva6_linux/board/cva6_linux_boot_trace.sh --payload /path/to/fw_payload.bin

# Decode the capture against a pcinfo (none ships in this tree yet, see below):
examples/kv260/cva6_linux/board/cva6_linux_boot_trace.sh --pcinfo boot.pcinfo
```

Run `cva6_linux_boot_trace.sh --help` for the full option list (`--proto
n|e`, `--syncmax`, `--runsec`, board/jump/user/sudo-pass, `--out`).

## Sequence

1. **Payload availability** — checks the payload's byte size (local file via
   `--payload`, or a `stat` on the jump host via `--payload-jump`, default
   `cva6_linux/out/fw_payload.bin`) before touching the board at all.
2. **Prepare** (`xmutil unloadapp` -> `xmutil loadapp` -> AFIFM port widths
   -> hold core in reset -> clear rings -> URAM one-shot) — gated by a
   **RESMEM check first**: the reserved-memory node must be present in the
   *live* boot devicetree (a `no-map` reservation never shows up in
   `/proc/iomem`, so this has to read
   `/sys/firmware/devicetree/base/reserved-memory/` directly) and the right
   size, or the run aborts rather than risk writing the guest payload into
   unreserved Ubuntu RAM.

   **This gate checks the CURRENT overlay this repository ships**
   ([`../../common/board/ctrace_resmem.dtso`](../../common/board/ctrace_resmem.dtso),
   address-plan **v4**: node `ctrace-pl-ddr@50000000`, size `0x20000000` =
   512 MiB, bumped from 256 MiB on 2026-08-10) — **not** the v3 values
   (`ctrace-pl-ddr@60000000`, 256 MiB) the PowerShell original's text literally
   checks for. That v3 node does not exist on a board carrying today's
   overlay, and a literal port of the ps1's check would false-negative
   every run. v4 is a strict superset of what this example needs: its own
   DDR-sink reset default is still `0x6000_0000`
   ([`../rtl/cva6_linux_soc_top.sv`](../rtl/cva6_linux_soc_top.sv)), and the
   guest RAM window (`0x6400_0000` + 192 MiB) ends exactly at the v4
   window's own end (`0x7000_0000`). The divergence is documented in full
   in the internal port log, which is not part of this repository.
3. **Payload into the window** — `mem_load.py` staged onto the board and run
   with `--verify` (`dd`'s `write()` path into this reserved window returns
   `Bad address` on this board's kernel; `mmap`, which `mem_load.py` uses,
   works — see that script's own header). The `--payload-jump` default
   streams the payload jump-host -> board in one hop (`cat <path> | ssh
   board '... mem_load.py'`), matching the ps1's reasoning: the payload
   already lives on the build host, so there is no reason to pull it onto
   the workstation first and push it again. `--payload <local-file>` is new
   relative to the ps1: stages a workstation-built payload via the jump
   host instead.
4. **Arm + boot** — `trTeProtocolSel` (E-Trace only, `swwel`-gated: writable
   only while `Enable=0`) if `--proto e`, `trTeInstFeatures` SrcID/SrcBits,
   `trTeControl` on (`0x0106_0067 | (SyncMax<<20)`), core released
   (`CONTROL.b0=1`), `--runsec` capture window, `trTeControl` off.
   `--syncmax` (default **6** = every 1024 instructions, the RDL reset
   value) controls `InstSyncMax[23:20]`; **0** (every 16 instructions) was
   the hard-wired value until 2026-08-17 and broke decode at the first
   `jalr` in `fw_platform_init` on every bitstream tested, by flooding the
   ring with `ResourceFull`+`ProgTraceSync` pairs that collide with the
   decoder's implicit-return reconstruction (see the script's own `--syncmax`
   help text for the full finding).
5. **Console ring** (the boot proof) — read back word-by-word from
   `0xA030_0000`, written to `console.txt`, and printed inline.
6. **Trace ring** — read back word-by-word from `0xA020_0000` (clamped to
   1 MiB, the ring's own capacity), written to `boot_<proto>.atb.bin`.
7. **Gates** — `OpenSBI` banner in the console -> `FAIL` if absent;
   `Linux version` -> `WARN` only (kernel may simply not have been reached
   yet within `--runsec`); non-empty trace ring -> `FAIL` if empty. Verdict
   `### BOOT_TRACE_OK` / `### BOOT_TRACE_INCOMPLETE` — like the ps1, this is
   an **evidence-gathering** tool: the script itself always exits 0 once it
   reaches this point (infra-level problems -- missing payload, failed
   RESMEM gate, failed prepare, a payload that didn't arrive -- still abort
   early with a nonzero exit, exactly as in the ps1).
8. **Decode** (new vs. the ps1, `--pcinfo <file>`) —
   `cttd -deco boot_<proto>.atb.bin -pcinfo <file> -pcout boot_<proto>.pcout -full`,
   printing every `Stat:` line and the decoder's exit code. **No pcinfo
   ships in this migrated tree yet** for the CVA6 Linux payload (no sim run
   producing one has been executed here) — without `--pcinfo`, this step
   prints a clear `SKIP` line instead of silently doing nothing.

## What's not wired up

- **No packaging/deploy wrapper** (unlike
  [`../../duo/board/duo_board_gate.sh`](../../duo/board/duo_board_gate.sh))
  — this script's own scope, like the ps1's, starts after the app is
  already deployed. See "Deployment is a prerequisite" above.
- **`--pcinfo`** needs a pcinfo built from this payload's OpenSBI/kernel
  listing (`sw/cva6_linux/make_listing.sh`, see
  [`../sw/README.md`](../sw/README.md)) — none is vendored in this tree.
