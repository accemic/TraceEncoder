#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Resolve CTTE `.abc` dependencies into an XSIM/Vivado compile order.

WHY: create_project_kv260.tcl adds the CTTE encoder sources with plain
`add_files` (it predates this repo's `abc` build driver, see the README's
"abc flow" note) -- so it needs a file list, and this reads that list out of
the encoder's own dependency graph (`.abc`) instead of hand-maintaining one
that would silently drift on the next change.

`.abc` format:
    import  @<dir> : <name> <name> ...   # directory-qualified, repo-root-relative
    import  <name>                       # same directory as the .abc file
    read_sv  <file.sv>                   # synthesizable source
    read_sim <file.sv>                   # sim-only source

TWO-PASS PROCEDURE (and why):
  1. `.abc` DFS gives the **file set** (the transitive closure) -- the graph
     is good for that.
  2. The **order** does NOT come from the `.abc` graph, but from the actual
     `package`/`import` declarations in the .sv sources.

Reason: the `.abc` graph is cyclic (tip_pkg <-> tip_if) and does not fully
capture package dependencies. For `xvlog` only one thing matters: **a package
must be compiled before its use.** Modules/interfaces are resolved by `xelab`
later, their order does not matter. So we sort strictly by package edges --
exactly what the compiler needs, and self-correcting on the next update.

The output is still **not proof** -- it is verified by `xvlog` itself when the
project is actually elaborated.

Usage:  py abc_filelist.py <root.abc> [<root.abc> ...] [--root <CTTE root>]
Output: one file per line, dependencies first (stdout).

Migrated 2026-08 from an internal predecessor repository. This is a
per-example copy: there is no repository-wide tools/abc_filelist.py, and
nine example flows under examples/kv260/*/fpga/ carry byte-identical copies
of this file. Promoting it to one shared location is an open item -- it
needs a write scope wider than a single example.
"""

# PEP 563: keep every annotation lazy. This file annotates with PEP 585
# generics (dict[...], list[...]) and PEP 604 unions (Path | None), which
# are evaluated at runtime on Python < 3.9 / < 3.10 and raise
# "TypeError: 'type' object is not subscriptable" there. The repository
# documents Python >= 3.8 as supported (README "Prerequisites"), and CI
# nodes on Ubuntu 20.04 ship 3.8 -- measured 2026-08-21.
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path

IMPORT_QUALIFIED = re.compile(r"^\s*import\s+@(\S+)\s*:\s*(.+?)\s*$")
IMPORT_LOCAL = re.compile(r"^\s*import\s+([^@:\s]+)\s*$")
READ_SRC = re.compile(r"^\s*read_(?:sv|sim|vhdl)\s+(\S+)\s*$")

# --- Gaps in the encoder's own .abc metadata (verified @ pin 3a74ea5) ---------------
# If an .abc does not declare a dependency that its .sv nonetheless instantiates,
# the file is missing from the resolved set and `xelab` aborts. The encoder itself
# must not be patched (it is pinned, AD-01); so gaps are papered over here, with
# evidence.
#
# Format: "<.abc path relative to the CTTE root>": [(dir, name), ...]
ABC_GAPS: dict[str, list[tuple[str, str]]] = {
    # cvs_fifo2.abc only imports `cvsource_if2`, but cvs_fifo2.sv:30 instantiates
    # `cvsource_if`.
    # Evidence: xelab -> "ERROR: [VRFC 10-2063] Module <cvsource_if> not found while
    #                     processing module instance <qq> [.../rtl/external/stream/cvs_fifo2.sv:30]"
    "rtl/external/stream/cvs_fifo2.abc": [("rtl/external/stream", "cvsource_if")],
}

# --- Pass 2: package edges from the actual SV sources ---
SV_PACKAGE_DEF = re.compile(r"^\s*package\s+(\w+)\s*;", re.M)
SV_PKG_USE = re.compile(r"\b(\w+)\s*::")
SV_LINE_COMMENT = re.compile(r"//[^\n]*")
SV_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def sv_pkg_edges(path: Path) -> tuple[set[str], set[str]]:
    """-> (packages defined, packages used) of one .sv file.

    Comments are stripped first, otherwise a commented-out `foo::bar` would
    count as a use. Self-use (a package referencing itself) is filtered out.
    """
    try:
        txt = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return set(), set()
    txt = SV_BLOCK_COMMENT.sub(" ", txt)
    txt = SV_LINE_COMMENT.sub(" ", txt)
    defs = set(SV_PACKAGE_DEF.findall(txt))
    uses = set(SV_PKG_USE.findall(txt)) - defs
    return defs, uses


def order_by_packages(files: list[Path]) -> tuple[list[Path], list[str]]:
    """Topologically sort by package dependency (stable, cycle-tolerant)."""
    warnings: list[str] = []
    defs_of: dict[Path, set[str]] = {}
    uses_of: dict[Path, set[str]] = {}
    provider: dict[str, Path] = {}
    for f in files:
        d, u = sv_pkg_edges(f)
        defs_of[f], uses_of[f] = d, u
        for p in d:
            provider.setdefault(p, f)

    ordered: list[Path] = []
    placed: set[Path] = set()
    visiting: set[Path] = set()

    def place(f: Path):
        if f in placed or f in visiting:
            return
        visiting.add(f)
        for pkg in sorted(uses_of.get(f, ())):
            src = provider.get(pkg)
            if src is not None and src is not f:
                place(src)
        visiting.discard(f)
        if f not in placed:
            placed.add(f)
            ordered.append(f)

    # Offer package providers first (stable in input order), then the rest.
    for f in [x for x in files if defs_of.get(x)] + [x for x in files if not defs_of.get(x)]:
        place(f)

    # Self-check: report a use with no provider in the set.
    all_defs = set(provider)
    for f in files:
        missing = {p for p in uses_of[f] if p not in all_defs}
        # std:: etc. are SV builtins -- no file provides them.
        missing -= {"std", "$unit"}
        if missing:
            warnings.append(f"no provider in the file set for {sorted(missing)} (used in {f.name})")
    return ordered, warnings


class AbcGraph:
    def __init__(self, root: Path):
        self.root = root
        self._cache: dict[Path, tuple[list[str], list[Path]]] = {}

    def abc_for(self, directory: str, name: str) -> Path | None:
        p = self.root / directory / f"{name}.abc"
        return p if p.is_file() else None

    def parse(self, abc: Path) -> tuple[list[tuple[str, str]], list[Path]]:
        """-> (deps as (dir, name), source files)."""
        deps: list[tuple[str, str]] = []
        srcs: list[Path] = []
        own_dir = abc.parent.relative_to(self.root).as_posix()
        for line in abc.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.split("#", 1)[0]
            if not line.strip():
                continue
            m = IMPORT_QUALIFIED.match(line)
            if m:
                d = m.group(1)
                for n in m.group(2).split():
                    deps.append((d, n))
                continue
            m = IMPORT_LOCAL.match(line)
            if m:
                deps.append((own_dir, m.group(1)))
                continue
            m = READ_SRC.match(line)
            if m:
                srcs.append(abc.parent / m.group(1))
        # Append documented upstream gaps (see ABC_GAPS).
        rel = abc.relative_to(self.root).as_posix()
        deps.extend(ABC_GAPS.get(rel, []))
        return deps, srcs


def collect(graph: AbcGraph, roots: list[Path]) -> tuple[list[Path], list[str]]:
    """Pass 1: transitive file closure from the .abc graph (order irrelevant)."""
    files: list[Path] = []
    seen: set[Path] = set()
    stack: set[Path] = set()
    warnings: list[str] = []

    def visit(abc: Path):
        if abc in seen or abc in stack:
            return   # back edge: a cycle, deliberately broken (pass 2 does ordering)
        stack.add(abc)
        deps, srcs = graph.parse(abc)
        for d, n in deps:
            child = graph.abc_for(d, n)
            if child is None:
                warnings.append(f"unresolved: {n} (@{d}) referenced from {abc.name}")
                continue
            visit(child)
        stack.discard(abc)
        seen.add(abc)
        for s in srcs:
            if s.is_file():
                if s not in files:
                    files.append(s)
            else:
                warnings.append(f"source missing: {s}")

    for r in roots:
        visit(r)
    return files, warnings


def resolve(graph: AbcGraph, roots: list[Path]) -> tuple[list[Path], list[str]]:
    files, w1 = collect(graph, roots)
    order, w2 = order_by_packages(files)
    return order, w1 + w2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("roots", nargs="+", help=".abc entry points (repo-relative or absolute)")
    ap.add_argument("--root", default=None, help="CTTE root (default: guessed from the first .abc path)")
    ap.add_argument("--quiet", action="store_true", help="suppress warnings")
    args = ap.parse_args()

    first = Path(args.roots[0]).resolve()
    if args.root:
        croot = Path(args.root).resolve()
    else:
        croot = first
        while croot != croot.parent and not (croot / "rtl" / "ct_encoder.abc").is_file():
            croot = croot.parent
    if not (croot / "rtl").is_dir():
        print(f"ERROR: CTTE root not found (guessed: {croot})", file=sys.stderr)
        return 2

    graph = AbcGraph(croot)
    roots = [Path(r).resolve() for r in args.roots]
    for r in roots:
        if not r.is_file():
            print(f"ERROR: {r} does not exist", file=sys.stderr)
            return 2

    order, warnings = resolve(graph, roots)
    if warnings and not args.quiet:
        for w in warnings:
            print(f"[abc_filelist] WARN {w}", file=sys.stderr)
    for p in order:
        print(p.as_posix())
    return 0


if __name__ == "__main__":
    sys.exit(main())
