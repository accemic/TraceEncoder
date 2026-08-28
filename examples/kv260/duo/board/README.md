<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/duo/board — package, deploy, run, verdict

`duo_board_gate.sh` takes the [`../fpga/`](../fpga/) flow's routed `.bit` all
the way to a board verdict: package it into a loadable KV260 app, deploy it,
run both cores with CTTE armed, pull the merged ring back, decode it
per-core, and print `### DUO_BOARD PASS`/`FAIL`.

Bash port of an internal predecessor repository
(Phase 4b of that repository's board bring-up), folded together with this
repository's own [`../../common/board/package_kv260_app.py`](../../common/board/package_kv260_app.py)
and [`../../common/board/deploy_kv260_app.sh`](../../common/board/deploy_kv260_app.sh)
so one command replaces what used to be two separate manual steps (packaging
was previously done by a different predecessor-repository script that the
PowerShell original assumed had already run). The full port log is an internal
document, not part of this repository; it records two places where the
current repository state, not the ps1's literal text, was followed (register map unchanged for `duo`; `cva6_linux`'s
reserved-memory overlay grew from v3 to v4 in between — the sibling
`../../cva6_linux/board/` README documents that one).

## Usage

```bash
# From a routed bitstream:
examples/kv260/duo/board/duo_board_gate.sh --bit examples/kv260/duo/fpga/proj/duo_kv260.runs/impl_1/duo_kv260_top.bit

# Reuse an already-packaged app dir (skips package_kv260_app.py):
examples/kv260/duo/board/duo_board_gate.sh --skip-package --app-dir /tmp/duo_ctrace_kv260

# With prefix-check oracles from a sim run (none ship in this migrated tree
# yet -- see "What's not wired up" below):
examples/kv260/duo/board/duo_board_gate.sh --bit <bit> \
    --oracle0 tb_duo_ps_devmem.core0.retired.pcs \
    --oracle1 tb_duo_ps_devmem.core1.retired.pcs
```

Run `duo_board_gate.sh --help` for the full option list (board IP, jump
host, board user/sudo password, PL clock label, run window, program name,
work directory, `--closure-verify` hook).

All three board gates spell the PL-clock option the same way:
**`--pl-mhz <68|75|100>`**, forwarded to the same
`common/board/kv260_plclk.sh` label. This gate used to spell it `--plmhz`
(no hyphen between `pl` and `mhz`); that spelling stays accepted as an
undocumented alias so older invocations and logs keep working.

Requires `ssh`/`scp` reaching the jump host (`--jump`/`KV260_JUMP`, no default), the KV260
board reachable from there, `py`/`python3` on the workstation, and this
repository's `bin/cttd-*` decoder (resolved via
[`../../../../scripts/ct_env.sh`](../../../../scripts/ct_env.sh), same as
every other decode-driving script in this tree).

## Sequence

1. **Package** — `package_kv260_app.py --bit <bit> --app duo_ctrace_kv260`
   (skippable with `--skip-package --app-dir <dir>`).
2. **Deploy** — `deploy_kv260_app.sh --app-dir <dir> ...` (staging on both
   hops, dtbo compiled on the board, hash-verified at the target — see that
   script's own header for the three deploy traps it guards against).
3. **Board sequence** — generated as a heredoc, pushed workstation ->
   jump host -> board, run via `sudo -S bash`:
   - `xmutil unloadapp` -> **set `pl_clk0` via
     [`kv260_plclk.sh`](../../common/board/kv260_plclk.sh)** -> `xmutil
     loadapp` -- in that order, and a **second** time even though `deploy_
     kv260_app.sh` already loaded the app once: the deploy's load happened
     at whatever clock was already active (an `xmutil` runtime overlay only
     sets `firmware-name`, never `PL0_REF_CTRL`), so only this second cycle
     actually guarantees the frequency for the capture that follows. Aborts
     (`PLCLK_SCRIPT_MISSING`/`PLCLK_FAILED`) rather than silently running at
     the wrong clock.
   - reads back the loaded bitstream's `.bit.bin` md5 (`BITBIN_MD5`) so a
     captured trace can always be tied back to a specific build;
   - loads the MBV program (`../../mbv/sw/build/<prog>.bin`, built on
     demand via that example's own `make` if missing) word-by-word into
     RAM0 (`0xA010_0000`) and the TGC5B `hello_trace.hex`
     (`examples/kv260/common/tgc5b/prog/`) into RAM1 (`0xA008_0000`);
   - arms both CTTE encoders (`FEAT` SrcID/SrcBits RMW, then
     `trTeControl` enable), starts both cores collectively (`CONTROL.b0`),
     runs for `--runsec` (default **0.02 s** — 0.05 s wraps the 1 MiB ring,
     see the anchor-class gate below), disarms, flushes (`CONTROL.b2`), and
     reads back `TRACE_BYTES`/`STATUS`;
   - reads the merged ATB ring word-by-word from `0xA020_0000`.
4. **Anchor-class gate** (new vs. the PowerShell original, not optional) — if
   `TRACE_BYTES > 0x100000` (the ring wrapped) or `STATUS.trace_wrapped` is
   set, the gate fails **before** attempting a decode: a wrapped ring
   re-syncs mid-stream without an enable event, which the decoder cannot
   anchor, and every board decode failure this project has hit traces back
   to exactly that class. `--runsec` stays low specifically to avoid it.
5. **Decode** — words merged to bytes, then
   `cttd -deco trace.bin -target 0 -pcinfo mbv.pcinfo -pcout duo.core0.pcout -target 1 -pcinfo tgc.pcinfo -pcout duo.core1.pcout -src 2 -stat`
   (SRC field tells the two cores' beats apart in the funnelled stream).
6. **Per-core prefix check** — `scripts/check_pcout_vs_retired.py <pcout> <oracle> --label coreN --ref-prefix-ok`
   if `--oracle0`/`--oracle1` was given (a sim run's `retired.pcs`: the full
   reference sequence must appear as a **prefix** of the board-decoded one,
   since the board run is longer than any sim reference and the one-shot
   ring holds the stream's start). **Without an oracle: `SKIP`, loudly — not
   `PASS`.** No such oracle currently ships in this migrated tree (no xsim
   run has been executed here yet); see "What's not wired up" below.
7. **Verdict** — `### DUO_BOARD PASS` (both cores decoded, no core check
   FAILed — SKIPs don't block it) or `### DUO_BOARD FAIL`.

## What's not wired up (by design)

- **`--closure-verify <cmd>`** is an extension point only: it runs the given
  command with the board log path as its one argument and prints its output,
  but a nonzero exit only warns — it does **not** re-implement
  `kv260_closure_verify.ps1`'s timing-closure-database lookup (that logic
  reads data this repository does not carry, and the task that produced this
  port explicitly scoped it out).
- **`--oracle0`/`--oracle1`** need a `retired.pcs`-style reference (the
  actual retiring PC sequence from a sim run of `tb_duo_ps_devmem` or
  equivalent). None exists in this migrated tree — the `duo` example's
  Vivado/xsim flow has been adapted by review but not executed end-to-end
  (see [`../README.md`](../README.md)'s own verification section). Once a
  sim run produces one, point these two flags at it.

## Register map assumed (unchanged from the PowerShell original)

CTRL `0xA000_0000` | ENC0 `0xA001_0000` | ENC1 `0xA002_0000` | RAM1
`0xA008_0000` | RAM0 `0xA010_0000` | TRACE `0xA020_0000` — see
[`../rtl/duo_soc_top.sv`](../rtl/duo_soc_top.sv)'s `@details` header for the
full, current register list (this script only ever touches `CONTROL`,
`STATUS`, `TRACE_BYTES`, and each encoder's `trTeInstFeatures`/`trTeControl`
CSR; the newer additive DDR4/PIB/funnel sink registers documented there stay
at their inert reset defaults throughout this flow).
