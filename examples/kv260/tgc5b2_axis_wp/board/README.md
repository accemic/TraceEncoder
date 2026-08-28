<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# `tgc5b2_axis_wp/board` — KV260 board-gate driver

Board-deploy and board-gate tooling for the `tgc5b2_axis_wp` watchpoint/DAQ
testbed (see [`../README.md`](../README.md)). Ported from the predecessor repository's
`vivado/tgc5b2_axis_wp/{g1_board_run.ps1,package_c0b.ps1}` (PowerShell)
during the consolidation into this repository. The migration/verification
log for this port is an internal document and is not part of this
repository.

## What it drives

Two independent MINRES TGC5B RISC-V cores, each running a deterministic,
IRQ-paced walk over ~300 generated leaf functions, each hitting a
1023-entry indirect watchpoint table loaded into its own CTTE encoder.
Each encoder's AXIS watchpoint-hit stream goes through a `ct_axis_wp_shim`
into an `axi_fifo_mm_s` a Linux host drains via `/dev/mem`. The gate
compares what came off each FIFO against a deterministic oracle
(`sw/expected_hits.txt`, 851 hits): count equality, per-record metadata
(slot index, `tid`, `tstrb`), drop/overflow-free operation, and a
cross-core timestamp merge.

## Usage

```bash
# 1. Host artifacts + packaged bitstream (no board access)
bash wp_board_gate.sh --phase gen

# 2. Stage tooling on the board + load the app (acquire whatever hardware
#    lease your site uses for the board first)
bash wp_board_gate.sh --phase deploy --board <board-ip>

# 3. Finite walk (851 records/FIFO expected, 0 drops)
bash wp_board_gate.sh --phase runa --board <board-ip>
bash wp_board_gate.sh --phase checksa

# 4. Endless walk (continuous drain, drops/wraps expected and balanced)
bash wp_board_gate.sh --phase runb --board <board-ip>
bash wp_board_gate.sh --phase checksb

# 5. Put the board back the way it was found
bash wp_board_gate.sh --phase restore --board <board-ip>
```

Every phase is independently invocable; state lives under `--work`
(default `board/run/`, gitignored). `gen`/`checksa`/`checksb` never touch
the network; `deploy`/`runa`/`runb`/`restore` need `--board` and support
`--dry-run` (prints the exact `ssh`/`scp` commands it would run, with the
sudo password redacted, and stops before making any board contact).

`PY` resolves to `py` if present on `PATH`, else `python3` (Windows vs.
Linux workstation) — override with `PY=python3 bash wp_board_gate.sh ...`
if neither auto-detection is right for your shell.

### Phases

| Phase | Board access | Does |
|---|---|---|
| `gen` | no | derive `wp_table.txt`/`wp_real.txt`/`expected_full.txt`/`prog.hex` from `sw/` (`wp_gen.py`, C1b rules: 364 real + 659 odd filler = 1023 slots), then package `--bit` into a loadable app dir (`common/board/package_kv260_app.py`) |
| `deploy` | yes | stage `tools/axis_wp_host/*.py` + `wp_board.py` + the run/prep/restore scripts + `gen`'s generated data onto the board's `/tmp/wp_board_run/`, then load the app (`do_load()`, see below) |
| `runa` | yes | reload (`do_load()`) + `run_a.sh`: finite walk, drain after halt |
| `runb` | yes | reload (`do_load()`) + `run_b.sh`: endless walk, continuous per-FIFO drain (`--runb-drain-sec`/`--runb-max-records`) |
| `checksa` | no | `wp_check.py runa` against the fetched run-A logs |
| `checksb` | no | `wp_check.py runb` against the fetched run-B logs |
| `restore` | yes | `restore.sh`: unload, reload whatever app was active before `deploy`'s first `do_load()`, restart the dashboard, report board health |

### Parameters

| Flag | Default | Meaning |
|---|---|---|
| `--phase` | *(required)* | `gen\|deploy\|runa\|runb\|checksa\|checksb\|restore` |
| `--board` | — | board IP; required for `deploy`/`runa`/`runb`/`restore` |
| `--app` | `tgc5b2_axis_wp_c0b` | app name (packaged dir name, `/lib/firmware/xilinx/<app>`) |
| `--bit` | `../fpga/proj/tgc5b2_axis_wp.runs/impl_1/tgc5b2_kv260_top.bit` | routed bitstream for `gen` |
| `--work` | `board/run/` | state directory (generated data, app pkg, logs) |
| `--expected-md5` | *(empty = skip)* | if set, `gen` fails with `MD5_MISMATCH` unless the freshly packaged `bit.bin` matches |
| `--vivado-bin` | *(empty = package_kv260_app.py's own default)* | bootgen directory, only passed through if set |
| `--jump` | *(none)* | jump host (workstation → jump → board transport); `KV260_JUMP` |
| `--user` | `ubuntu` | board SSH user |
| `--sudo-pass` | `$KV260_SUDO_PASS` | board sudo password |
| `--pl-mhz` | `75` | `pl_clk0` target (this design's timing closure point, see `kv260_plclk.sh`); spelled the same in all three board gates |
| `--runb-drain-sec` | `65.0` | run B: per-FIFO continuous-drain time budget |
| `--runb-max-records` | `1600000` | run B: per-FIFO record cap (memory-safety terminator, see `run_b.sh`) |
| `--dry-run` | off | print the board-touching commands instead of running them |

## Layout

```
wp_board_gate.sh   host driver (this file's usage comment doubles as --help)
wp_gen.py          host: sw/ -> wp_table.txt/wp_real.txt/expected_full.txt/prog.hex
wp_check.py        host: G1CHECK runa/runb gate against the fetched logs
wp_board.py         board: prep/start/stop/status subcommands (imports the
                    axis_wp_host modules that get staged next to it)
prep_load.sh         board: dashboard-stop + prev-app capture + unloadapp + pl_clk0 set
prep_verify.sh       board: fpga_manager state + MAGIC readback, post-load
run_a.sh             board: finite-walk run + drain
run_b.sh             board: endless-walk run + continuous drain + rest-drain
restore.sh           board: unload, reload previous app, restart the dashboard
.gitignore            ignores --work's default output tree (run/)
```

## Design notes / deltas from the PowerShell source

The source (`g1_board_run.ps1`) drove `dtc`/install/`xmutil loadapp` itself
with a hand-rolled `-Install` flag distinguishing a first "install" reload
from a later "reload-only" one. This port instead uses the two building
blocks that already exist, unmodified, in `common/board/`:

- **`package_kv260_app.py`** replaces the source's separate
  `package_c0b.ps1` (bootgen invocation) — folded into the `gen` phase.
- **`deploy_kv260_app.sh`** replaces the dtc/install/`loadapp`/hash-verify
  half of the source's `g1_prep_install.sh`/`g1_prep_reload.sh` — called by
  `wp_board_gate.sh`'s `do_load()` function.

Neither of the two is modified by this port (per task scope); the gaps
between what they do and what this design additionally needs are closed
*around* them:

1. **No `pl_clk0` handling, no dashboard stop.** `deploy_kv260_app.sh`
   loads the app but never touches the PL clock divider and never stops
   `ctrace-dashboard` — both are load-order requirements here (the clock
   may only change while the PL is unloaded; the dashboard is the *other*
   possible master of the FIFO windows this gate's `run_a.sh`/`run_b.sh`
   read from — single-FIFO-master discipline). `do_load()` wraps every
   `deploy_kv260_app.sh` call with `prep_load.sh` (stop dashboard, capture
   the previously-active app for `restore`, unload, set `pl_clk0`)
   beforehand and `prep_verify.sh` (fpga_manager state + `MAGIC` register
   readback) after.
2. **The board-side bit.bin hash check becomes redundant, so it moved.**
   `deploy_kv260_app.sh` already verifies the bit.bin hash *at the target*
   as part of its own success path (`### DEPLOY_OK`/`### HASH_MISMATCH`).
   The source's separate `$ExpectedMd5` check therefore now runs where it
   catches problems earliest: against the *freshly packaged local*
   `bit.bin`, during `gen` (see `--expected-md5` above).
3. **`--expected-md5` has no hardcoded default.** The source pinned
   `-ExpectedMd5` to `7c7255dd66a07a43ea010e81bbb81efd` — one specific
   PowerShell-side C0b rebuild. Carrying that value forward as a default
   here would make every future `gen` run against a freshly re-synthesized
   `.bit` fail with `MD5_MISMATCH` by construction (bitstream routing is
   not guaranteed stable across resynthesis even with unchanged RTL) —
   confirmed while writing this port: a real `gen` run against the
   `.bit` already checked into this tree produced `bit.bin` md5
   `7943c7c7cb484d61d843e30e4c8db235`, which is *not* the source's pinned
   value. `--expected-md5` is therefore optional and empty by default.
4. **`deploy` also loads the app.** The source's `deploy` phase only
   staged files (`/tmp/g1`) — loading happened later, inside `runa`'s own
   prep step. Since `deploy_kv260_app.sh`'s job *is* load, and `runa`/
   `runb` each call `do_load()` again anyway (matching the source's
   per-run reload discipline: every run gets a fresh, correctly-clocked
   load), `deploy` in this port does one load cycle up front instead of
   staying load-free — nothing downstream depends on it staying
   unloaded, and a `deploy` that ends with a verified, running app is
   arguably a better gate on its own.
5. **`wp_check.py`'s `open_text()` dropped the UTF-16LE BOM-sniffing** the
   source's `g1_check.py` needed (PowerShell's `Tee-Object -FilePath`
   writes UTF-16LE by default — a real gate failure the source hit and
   fixed on 2026-08-13). The Bash port captures the same logs through
   POSIX `tee`, which is always plain UTF-8/ASCII; the workaround is now
   dead code for a tool that no longer sits in this path, so it was
   removed rather than carried forward unused.
6. **`mem_load.py`** (`common/board/`, bulk `/dev/mem` writer) was
   considered as a replacement for `wp_board.py`'s per-word RAM-load loop
   and not used: `load_ram()` writes 32-bit words through the same
   `DevMemBus` object it uses for the 3-point readback verification, which
   is the source design's actual load contract, not an implementation
   detail worth swapping out.

The **three documented KV260 deploy traps** in
[`../../README.md`](../../README.md) all apply here and are respected the
same way `deploy_kv260_app.sh` already respects them (staging dirs are
`rm -rf`'d before every `scp -r`; the PL aperture is only touched once
`prep_verify.sh` — or `deploy_kv260_app.sh`'s own active-slot check — has
established our app owns the slot; `xmutil listapps`, not `fpga_manager`
state, is what's trusted).

## Verification performed during this port (no board access)

- `bash -n`/`sh -n` clean on all shell scripts; `py -c "import ast;
  ast.parse(...)"` clean on all Python scripts.
- `wp_gen.py` run for real against the actual `sw/expected_hits.txt` +
  `sw/axis_wp_demo.hex`: `G1GEN hits=851 n_real=364 slots=1023 fill=659
  hexwords=5522` — matches the source's own documented shape (364 real +
  659 filler = 1023 slots).
- `wp_board_gate.sh --phase gen` run for real end to end (real `wp_gen.py`
  + real `bootgen` via `package_kv260_app.py` against the `.bit` already
  checked into this tree): produced a working `app_pkg/tgc5b2_axis_wp_c0b/`
  with `bit.bin`/`.dtso`/`shell.json`/`MANIFEST.sha256` and printed
  `### GEN_OK`.
- `wp_check.py` (via `wp_board_gate.sh --phase checksa`) exercised against
  two synthetic run-A fixtures built from the real `wp_gen.py` output and
  real `read_wp_stream.py --source file` decodes (not fabricated log
  text): a fully-matching fixture produced `G1CHECK runa PASS` with
  `records=851` on both FIFOs, `cross-core: max|ts0[k]-ts1[k]| = 0`, and
  `merge: 1702 records, 0 monotonicity violations` — the same shape of
  numbers as the 2026-08-17 PowerShell board run this task cites (851
  records/FIFO, cross-core Δts=0, 1702/0 merge); a fixture with one record
  dropped from core 1 produced `G1CHECK runa FAIL: fifo1: count equality
  violated (850/851 raw 850)` with a non-zero exit code, confirming the
  ported checker actually gates on the stricter "full list equality" the
  reader's own drop-tolerant `RESULT PASS` does not by itself prove (see
  `wp_check.py`'s module docstring).
- `--dry-run` exercised for `deploy`, `runa` and `restore`: each prints
  the exact command sequence and a `### DRY_RUN_OK` marker without making
  board contact; verified it does **not** also print a claimed-successful
  `### DEPLOY_OK`/similar in that path.
- Argument handling smoke-tested: missing `--board` on a board phase,
  an invalid `--phase` value, and an unknown flag all fail cleanly with a
  distinct exit code and message.

`runa`/`runb`/`checksa`/`checksb`/`restore`'s actual board legs (SSH/SCP to
a live KV260) were **not** exercised — out of this port's scope (no board
access). The assumption trail and the next-step board pass that would close
this gate are recorded in the internal port log, not in this repository.
