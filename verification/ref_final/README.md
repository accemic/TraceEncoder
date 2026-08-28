<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: ISC
-->

# REF_FINAL manifest archive — append-only

The byte-neutrality gate ("a new feature does not change existing
streams") compares a fresh build against a **pinned** md5 family. That
family is minted by [`scripts/r2_final_mint.sh`](../../scripts/r2_final_mint.sh)
into `bld/r2_final_manifest.txt`.

`bld/` is gitignored, and a re-mint keeps exactly **one** generation of
history (`bld/r2_final_manifest.prev.txt`). Two consecutive mints
therefore destroy the older family for good — including the family that
an already-closed package was measured against. That is not acceptable
for evidence a certification argument may rest on.

**Rule: every minted family is archived here before the next mint.**
`scripts/r2_final_mint.sh` does it mechanically — once for the outgoing
family (before it is overwritten) and once for the new one (so the
current pin is never the single generation that lives only in `bld/`).
The archive is *append-only* — a file in this directory is never
edited or deleted, only added to. File naming:

```
REF_FINAL_caps<N>_<YYYYMMDD-HHMM>_<head-sha>.txt
```

where `<N>` is the CAPS **width** of the profile the family was minted
from (`NEXUS_MSG_CFG_CAPS_WIDTH`, i.e. bits `0 .. N-1`). The manifest
header records the mint time, the HEAD, the supersession reason, the
superseded family and — since 2026-08-05 — the **CAPS word** the
profile emits, so each file is self-describing.

## `families.tsv` — the machine-readable index

`families.tsv` carries one line per archived family:

```
file <TAB> caps_value <TAB> caps_width <TAB> minted <TAB> head <TAB> derivation <TAB> reason
```

`caps_value` is the key. It is a pure function of the `CT_EN_*`
switches (`ct_pkg::ct_cfgmsg_caps`), so
[`scripts/ref_family.py`](../../scripts/ref_family.py) can compute it
for any build and for any revision:

```bash
py scripts/ref_family.py caps                       # this working tree
py scripts/ref_family.py caps --rev <sha>           # the profile at <sha>
py scripts/ref_family.py select --pkg <ct_pkg.sv>   # -> FAMILY=<path>
```

The `derivation` column says where the value came from: `header` for
families minted with the CAPS line, `recomputed-from-<sha>` for the two
legacy families, whose word was derived from `ct_pkg.sv` at their mint
HEAD. Both recomputed values reproduce the numbers documented
independently at the time (`0x27ffbf` for the P3 family, `0x7fffbf`
for the P4/P7 one).

## Why a package may need an older family

A family is minted from the **HEAD full profile**. Once a later package
adds a CAPS bit, the pinned family carries that bit, and a build with
the later feature compiled out can no longer reproduce it *by
construction*. The OFF-neutrality of an earlier package must therefore
be measured against the family whose CAPS set matches its own OFF
configuration — which is why the older files stay readable here.

A gate must never pick "the family minted last". `p7_off_neutrality.sh`
did, and after another package re-minted the pinned file two minutes
later the gate reported `BYTE NEUTRALITY: DRIFT` for a build that had
not drifted at all (P7 audit A-1). Selection is now mechanical
(`ref_family.py select`) and the chosen family — file, CAPS word, mint
HEAD — is printed into the gate log.

One nuance since 2026-08-13 (M0 merge `22ee86a3`): a re-mint whose byte
delta was proven **without** a CAPS change (C0b pipe deepening + P0-02
cadence reset — the word stays `0x7fffbf`) leaves several families with
the *same* CAPS word in this append-only archive. Among same-word
families `select` picks the **newest mint stamp** and prints the
passed-over siblings as `FAMILY_SUPERSEDES`; an older comparison is
reproduced deliberately via the gates' `REF=<path>` override. A word
*mismatch* remains the hard error it always was.

## Current archive

| File | CAPS | Minted | HEAD | Reason |
|---|---|---|---|---|
| `REF_FINAL_caps22_20260804-2123_4ee06f3.txt` | bit 21 (+ reserved 19/20) | 2026-08-04 21:23 | `4ee06f3` | P3 DF address compression |
| `REF_FINAL_caps23_20260805-1037_a04b37b.txt` | bits 19/20 (P4) + 22 (P7) | 2026-08-05 10:37 | `a04b37b` | P4 Device ID + Watchpoint; P7 DF drop rode along |
