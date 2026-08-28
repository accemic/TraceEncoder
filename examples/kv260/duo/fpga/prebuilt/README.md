<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Prebuilt bitstream -- the fast path

This directory holds the packaged, ready-to-load app for this demo, so you
can run it WITHOUT Vivado and without hours of synthesis:

* `duo_ctrace_kv260/` -- `.bit.bin` (bootgen, fpga-manager format), device-tree overlay, `shell.json`, and a `MANIFEST.sha256` that verifies the set.

Provenance: Extracted verbatim from the published `v1.0.1-demo2` bundle: the tarball's sha256 matches the pin in `scripts/demo.pin` (board-gated series, built 2026-08-18/19), and the per-file `MANIFEST.sha256` verifies after extraction.

Deploy it with the common loader (the same one the build path ends in):

```bash
bash examples/kv260/common/board/deploy_kv260_app.sh \
     --app-dir examples/kv260/duo/fpga/prebuilt/duo_ctrace_kv260 \
     --board <board-ip> [--jump <host>]
```

Verify before first use (and after any doubt):

```bash
cd examples/kv260/duo/fpga/prebuilt/duo_ctrace_kv260 && sha256sum -c MANIFEST.sha256
```

Building the bitstream yourself remains fully supported and is documented in
`examples/kv260/TUTORIAL_build_demos.md` (the per-demo build table). A
self-built bitstream will NOT be bit-identical to this one unless your tool
version and inputs match exactly -- judge it by its own gates, not by
comparing hashes against these files.
