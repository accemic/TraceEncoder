<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/mbv/board — KV260 board gate

`mbv_board_gate.sh` packages a routed `.bit`, deploys it to a KV260, loads
and runs the `trace_test` bare-metal program on the real MicroBlaze-V core,
captures the on-chip CTTE ring over `devmem`, decodes it, and checks the
decoded PC sequence against a simulation oracle. It is the Bash port of
the predecessor repository's `vivado/kv260_app/mbv_board_trace.ps1` +
`board_run/board_seq.sh`, the driver that produced that repository's
2026-08-17 "PREFIX_PASS 26772/26772" gate result, using this repository's
already-migrated [`../../common/board/`](../../common/board/) packaging/
deploy tooling instead of `package_and_deploy.ps1`.

```bash
examples/kv260/mbv/board/mbv_board_gate.sh --bit <routed.bit> \
    --oracle <path-to-trace_test.retired.pcs>
```

`--bit` is the only option without a usable default (see `--oracle` below).
Run the script with no arguments to see the exit-2 message naming exactly
what is missing; the script's own header comment documents every option and
its default (board IP, jump host, board user/sudo password, run duration,
PL clock label, working directory, `--skip-deploy`).

The PL-clock option is spelled **`--pl-mhz <68|75|100>`**
(`mbv_board_gate.sh:94`), the same as in
`../../tgc5b2_axis_wp/board/wp_board_gate.sh:89` and
`../../duo/board/duo_board_gate.sh:91`.

## What it does (in order)

1. Builds `sw/build/trace_test.bin` + `.dump` (`make`, `objcopy`/`objdump`
   only — does not need the three oracle-generation Python helpers
   [`../sw/README.md`](../sw/README.md) documents as not yet vendored here).
2. Converts the `.bin` to `prog.hex` (little-endian 32-bit words, one
   8-hex-digit line each, no `0x` prefix, LF-only) and resolves a
   `prog.pcinfo` — a committed `sw/build/trace_test.pcinfo` if present,
   otherwise generated on the fly via `cttd -conv -objd`.
3. Packages the bitstream (`../../common/board/package_kv260_app.py`) and
   deploys it (`../../common/board/deploy_kv260_app.sh`) — both skipped by
   `--skip-deploy`, for reusing an app already loaded on the board.
4. Runs the on-board load-run-capture sequence over
   workstation -> jump host -> board (the board only accepts ssh from the
   jump host): sets/verifies the PL clock, loads the program into the RAM
   region, arms and starts the core, waits `--runsec`, stops it, and reads
   the trace ring back word-by-word via `devmem`.
5. Converts the captured words back to a byte stream, truncated to the
   reported `NBYTES`.
6. Decodes the byte stream with `cttd -deco ... -bp -full`
   ([`scripts/ct_env.sh`](../../../../scripts/ct_env.sh) resolves the
   right `cttd-*` binary for the current host, including the KV260's own
   aarch64 leg).
7. Compares the decoded PC sequence against `--oracle` with
   [`scripts/check_pcout_vs_retired.py`](../../../../scripts/check_pcout_vs_retired.py)
   `--ref-prefix-ok` (the board capture normally retires far more
   instructions than the shorter simulation reference — `trace_test`'s
   branch-dense loop keeps running — so the reference only has to be a
   complete *prefix* of the decode, not an exact-length match).

Every run prints four evidence lines regardless of outcome —
`### PLCLK <mhz>`, `### BITBIN_MD5 <hash>`, `### NBYTES <n>`,
`### WRAP <0|1>` — followed by `### MBV_BOARD_GATE PASS <n>/<n>` (exit 0) or
`### MBV_BOARD_GATE FAIL` (exit 1). Both numbers of `PASS <n>/<n>` are the
*reference* PC count, i.e. "all n reference PCs matched" — not
decoded-over-retired, which would read like a mismatch on every pass, since a
board capture normally decodes far more instructions than the reference has.
A wrapped ring (`WRAP 1`, `STATUS` bit0
set — the ring overwrote its own oldest bytes mid-capture) fails immediately
before decoding: `--runsec` above roughly 0.3 s wraps the 1 MiB ring on this
example, so the default (0.05 s) stays well clear of it.

## How faithful the port is

The port was checked against the artifacts of the historical run before it
ever touched a board, and those checks are worth repeating if the script is
ever rewritten again:

* the `board_seq.sh` this script generates, with the PL clock and the run
  duration normalised on both sides, is **line-for-line identical** to the
  on-board sequence of the original run — the only differences are the
  translated comments and a trailing newline;
* the generated `prog.hex` is **byte-identical** to the one the original run
  loaded (747 bytes), and the on-the-fly `prog.pcinfo` matches the original
  in its opening lines;
* the decoder CLI the verdict steps depend on (`-conv`, `-deco`, `-pcinfo`,
  `-pcout`, `-bp`, `-full`) was confirmed against the pinned CTTD binary, not
  assumed.

What was *not* checked without hardware is everything downstream of the
`scp`/`ssh` transport — the board run itself.

## The oracle

This port does not vendor a `trace_test.retired.pcs` simulation reference
into `sw/build/` (out of this step's scope — only files under this `board/`
directory were added). Until a future migration step adds one, pass
`--oracle` explicitly; the predecessor repository's own evidence trail has one at
`_testrun/kv260_refs/trace_test.retired.pcs` (26772 PCs — the number behind
the historical "PREFIX_PASS 26772/26772" result). Once a
`sw/build/trace_test.retired.pcs` exists in this tree, the script picks it up
as the default automatically and `--oracle` becomes optional.

## What this script deliberately does not do

It does not port `kv260_plclk_verify.ps1`/`kv260_closure_verify.ps1`'s full
timing-closure gate (cross-checking the configured PL clock against the
bitstream's post-route achieved frequency) — only the informational
`### PLCLK`/`### BITBIN_MD5` evidence lines. A run with `--pl-mhz` above what
a given bitstream actually closes at will *not* be caught by this script.
