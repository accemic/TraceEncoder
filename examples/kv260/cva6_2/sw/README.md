<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/cva6_2/sw — guest device trees for the dual-CVA6 (AMP)

Two devicetree sources, one per guest core -- see
[`../rtl/cva6_2_soc_top.sv`](../rtl/cva6_2_soc_top.sv)'s header for the full
AMP rationale (why two guests, not one SMP kernel).

Migrated from an internal predecessor repository and
`cva6_2_kv260_core1.dts` (2026-08-17).

```
cva6_2_kv260_core0.dts   guest devicetree for core 0 (cpu@0 enabled, cpu@1 listed+disabled)
cva6_2_kv260_core1.dts   guest devicetree for core 1 (cpu@1 enabled, cpu@0 listed+disabled)
```

## No dedicated payload-build script exists for this example

Unlike [`../../cva6_linux/sw/`](../../cva6_linux/sw/) and
[`../../cva6_linux64/sw/`](../../cva6_linux64/sw/), this directory does
**not** carry its own `build_payload*.sh` -- the source repository's
`sw/cva6_linux/` directory had no `build_payload_2core.sh` or similar
either (checked directly: only the two `.dts` files above exist for the
dual-core example there). The two guest images are meant to be built by
reusing [`../../cva6_linux64/sw/build_payload_rv64.sh`](../../cva6_linux64/sw/build_payload_rv64.sh)
twice, but that script cannot simply be pointed at a different `.dts` file
from the outside: reading it shows it hardcodes its DTS input as
`"$here/cva6_kv260_rv64.dts"` (`$here` = the script's own directory) -- only
its **output** directory is overridable, via `OUT_DIR`. There is no
`DTS=` (or similar) environment-variable override in the script as
migrated.

**This migration did not invent a new script to close that gap** (it is
build-flow tooling outside this migration's RTL/TCL scope, and inventing
one would be exactly the kind of scope creep the workspace's "prepare
without inventing" rule warns against). The reproducible way to build both
guest images with the existing, unmodified scripts is:

1. Copy or symlink `build_payload_rv64.sh` (from
   `../../cva6_linux64/sw/`) into two separate working directories, each
   containing a copy of the relevant DTS renamed to `cva6_kv260_rv64.dts`
   (i.e. `cva6_2_kv260_core0.dts` -> `cva6_kv260_rv64.dts` in one
   directory, `cva6_2_kv260_core1.dts` -> `cva6_kv260_rv64.dts` in the
   other).
2. Run the script in each directory with a distinct `OUT_DIR` (e.g.
   `OUT_DIR=$PWD/out_core0` and `OUT_DIR=$PWD/out_core1`), pointing
   `BR_OUT` at the same shared RV64 Buildroot output tree in both (the
   kernel `Image` and cross toolchain are core-agnostic; only the DTB
   embedded into `fw_payload.bin` differs).

This is a manual multi-step workaround, not a committed script -- flagged
here as an open item for whoever next builds a payload for this example,
rather than silently left undocumented.

## Open items

- No dedicated payload-build script (see above) -- open item for a future
  migration step or direct follow-up work in this repository.
- The devicetrees were not board-tested during this migration (this SoC
  has not run on the board yet, per the source repository's own account,
  see the `.dts` files' own header comments) -- the `cpu1: status =
  "disabled"` precaution is a defensive design choice, not the fix of a
  measured defect.
