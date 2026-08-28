<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Prebuilt bitstream -- the fast path

This directory holds the packaged, ready-to-load app for this demo, so you
can run it WITHOUT Vivado and without hours of synthesis:

* `tgc5b2_rvcfi/` -- `.bit.bin` (bootgen, fpga-manager format), device-tree overlay, `shell.json`, and a `MANIFEST.sha256` that verifies the set.

Provenance: **N3 build** (DDR record rings, tutorial section 10c) of
2026-08-26 — `BITSTREAM_OK`, WNS +1.550 ns, `MEMKIND_OK`, seven-leg
simulation regression green (`VERDICTS_OK`), and **verified on KV260
silicon the same day**: THIS app deployed via `--prebuilt` from zero
(manifest check, md5 on target, MAGIC read back), `BOARD_VERDICTS_OK`
over the 12-leg twin table (FIFO and DDR transports identical), and the
loss-freedom proofs of section 10c — including ~1.14 million records per
core at full tilt with a ring drop delta of 0/0.

Deploy it with the common loader (the same one the build path ends in):

```bash
bash examples/kv260/common/board/deploy_kv260_app.sh \
     --app-dir examples/kv260/tgc5b2_rvcfi/fpga/prebuilt/tgc5b2_rvcfi \
     --board <board-ip> [--jump <host>]
```

Verify before first use (and after any doubt):

```bash
cd examples/kv260/tgc5b2_rvcfi/fpga/prebuilt/tgc5b2_rvcfi && sha256sum -c MANIFEST.sha256
```

Building the bitstream yourself remains fully supported and is documented in
`examples/kv260/TUTORIAL_build_demos.md` (the per-demo build table). A
self-built bitstream will NOT be bit-identical to this one unless your tool
version and inputs match exactly -- judge it by its own gates, not by
comparing hashes against these files.
