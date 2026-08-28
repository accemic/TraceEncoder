<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Security policy

CEDARtools.TraceEncoder is hardware IP plus the scripts, tools and a browser
dashboard that exercise it. A security issue here is most likely one of:

- a decoder or tool that can be made to misbehave by crafted trace bytes
  (the reference decoder itself is a separate project,
  [accemic/CTTD](https://github.com/accemic/CTTD) — report decoder issues there);
- the dashboard (`examples/dashboard/`), which serves a board's registers and
  captures over HTTP and is meant for a trusted lab network, not the internet;
- the board scripts under `examples/kv260/*/board/`, which run with `sudo` on
  the board.

## Reporting

Please **do not** open a public issue for a vulnerability. Send a report to
<info@accemic.com> (the same address [`MAINTAINERS.md`](MAINTAINERS.md) lists
for security disclosures) with:

- the affected file or component and the version / commit;
- what an attacker can do, and how to reproduce it;
- whether you want to be credited.

You will get an acknowledgement within a few working days. Fixes ship as a
normal release with a note in [`doc/release-notes.adoc`](doc/release-notes.adoc);
the reporter is credited there unless they ask not to be.

## Scope notes

- The `bin/` decoder is **fetched**, never committed, and pinned by sha256
  (`scripts/cttd.pin`). A checksum mismatch is a hard error by design; if you
  see one on a fresh download, report it — do not work around it.
- The pre-built KV260 apps under `examples/kv260/<demo>/fpga/prebuilt/` are
  tracked and verified by their own `MANIFEST.sha256`; the bundle series they
  were extracted from is recorded in `scripts/demo.pin`.
- Published KV260 bitstreams are built from the sources in this repository;
  the build recipe is `examples/kv260/TUTORIAL_build_demos.md`.
