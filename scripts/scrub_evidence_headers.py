#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Keep the numbers of a gate report, drop the machine it ran on.

`verification/evidence/` exists because a verdict has to outlive the run directory
that produced it (verification/evidence/README.md). The reports that get filed there
are written by Vivado and by our own gate scripts, and both stamp their
header with things that are true but not anybody's business once the
repository is public:

    | Host         : SOMEBOX-XY running 64-bit major release  (build 9200)
    | Command      : report_utilization -file X:/some/where/bld/util_flat.rpt
    # command : bash scripts/p7_off_neutrality.sh X:/some/where/CTTE-p7off

The workstation name and the directory layout of a developer machine are
not evidence for anything -- the numbers below them are. So this script
neutralises the header fields and leaves everything else byte-identical:
the host name becomes `<host>`, an absolute path is cut back to the
repository (or worktree) it points into and keeps its tail, so a reader
still sees *which* report of *which* run directory a line refers to.

    X:/w/ctte_worktrees/p10b_timing/bld/synth_ooc_t/util_flat.rpt
        -> <worktree>/bld/synth_ooc_t/util_flat.rpt
    X:/w/CTTE/verification/ref_final/REF_FINAL_caps22_20260804-2123_4ee06f3.txt
        -> <repo>/verification/ref_final/REF_FINAL_caps22_20260804-2123_4ee06f3.txt

Nothing else is touched. The script works on bytes and rewrites only the
matched spans, so line endings (this tree has both LF and CRLF evidence
files), trailing whitespace and every measured value stay exactly as they
were -- which is the point: a scrubbed report must still be the report.

Usage:

    py scripts/scrub_evidence_headers.py                 # scrub verification/evidence
    py scripts/scrub_evidence_headers.py --check         # report only, exit 1 if dirty
    py scripts/scrub_evidence_headers.py path/to/dir ...

It is idempotent (the placeholders contain no drive letter and no host
token, so a second run finds nothing) and therefore safe to re-run, or to
wire into a guard later. The site-specific names are options, not
constants: `--repo-dir` and `--worktree-parent` say which directory names
mark a repository root; anything else absolute falls back to
`<path>/<basename>`, which is lossy on purpose -- an unrecognised absolute
path is exactly the case where guessing would leak.
"""

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_TARGET = "verification/evidence"
DEFAULT_SUFFIXES = (".rpt", ".log")

# `| Host         : NAME running 64-bit ...` (Vivado) and `# host : NAME`
# (our own headers, should one ever grow the field). Only the name token is
# replaced; the rest of the line -- OS flavour, build number -- is generic
# and stays, because it is part of what makes a report reproducible.
HOST_RES = (
    re.compile(rb"(?mi)^(\|\s*Host\s*:\s*)(\S+)"),
    re.compile(rb"(?mi)^(#\s*host\s*:\s*)(\S+)"),
)

# An absolute path with a drive letter, up to the first character that
# cannot be part of one in these files. Kept deliberately narrow: a greedy
# pattern would swallow the rest of a command line.
WIN_PATH_RE = re.compile(rb"""[A-Za-z]:[\\/][^\s"';,)\]]*""")
# //host/share/... and \\host\share\... (UNC), and a unix home directory.
UNC_PATH_RE = re.compile(rb"""(?:\\\\|//)[A-Za-z0-9_.-]+[\\/][^\s"';,)\]]*""")
HOME_PATH_RE = re.compile(rb"""/(?:home|Users)/[^/\s"';,)\]]+""")

HOST_PLACEHOLDER = b"<host>"
REPO_PLACEHOLDER = b"<repo>"
WORKTREE_PLACEHOLDER = b"<worktree>"
PATH_PLACEHOLDER = b"<path>"
HOME_PLACEHOLDER = b"<home>"


def neutralise_path(token: bytes, repo_dir: str, worktree_parent: str) -> bytes:
	"""Cut an absolute path back to the root it points into, keep the tail.

	Order matters: the *last* recognised root wins, so a path that walks
	through several candidates ends up relative to the innermost one.
	"""
	norm = token.replace(b"\\", b"/")
	segs = norm.split(b"/")
	repo = repo_dir.encode()
	parent = worktree_parent.encode()

	cut = None  # (index of first tail segment, placeholder)
	for i, seg in enumerate(segs):
		if seg == parent and i + 1 < len(segs):
			cut = (i + 2, WORKTREE_PLACEHOLDER)
		elif seg == repo:
			cut = (i + 1, REPO_PLACEHOLDER)
		elif seg.startswith(repo + b"-"):
			cut = (i + 1, WORKTREE_PLACEHOLDER)
	if cut is None:
		# Unrecognised: keep only the file name. Lossy on purpose.
		return PATH_PLACEHOLDER + b"/" + segs[-1] if segs[-1] else PATH_PLACEHOLDER
	start, placeholder = cut
	tail = segs[start:]
	return placeholder + (b"/" + b"/".join(tail) if tail else b"")


def scrub(data: bytes, repo_dir: str, worktree_parent: str) -> "tuple[bytes, int]":
	"""Return the scrubbed bytes and the number of substitutions made."""
	count = 0

	def host_sub(m):
		nonlocal count
		if m.group(2) == HOST_PLACEHOLDER:
			return m.group(0)
		count += 1
		return m.group(1) + HOST_PLACEHOLDER

	for host_re in HOST_RES:
		data = host_re.sub(host_sub, data)

	def path_sub(m):
		nonlocal count
		count += 1
		return neutralise_path(m.group(0), repo_dir, worktree_parent)

	data = WIN_PATH_RE.sub(path_sub, data)
	data = UNC_PATH_RE.sub(path_sub, data)

	def home_sub(m):
		nonlocal count
		count += 1
		return HOME_PLACEHOLDER

	data = HOME_PATH_RE.sub(home_sub, data)
	return data, count


def iter_files(targets, suffixes):
	for target in targets:
		p = Path(target)
		if p.is_file():
			yield p
		elif p.is_dir():
			for f in sorted(p.rglob("*")):
				if f.is_file() and f.suffix in suffixes:
					yield f
		else:
			print(f"scrub_evidence_headers: no such path: {p}", file=sys.stderr)


def main(argv=None):
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("targets", nargs="*", default=[DEFAULT_TARGET],
	                help=f"files or directories to scrub (default: {DEFAULT_TARGET})")
	ap.add_argument("--check", action="store_true",
	                help="do not write; exit 1 if anything would change")
	# Derived, not guessed: this used to default to the name of ONE developer's
	# checkout, so on every other tree the scrubber quietly matched nothing.
	repo_dir_default = REPO.name
	ap.add_argument("--repo-dir", default=repo_dir_default,
	                help=f"directory name of the repository root "
	                     f"(default: this tree's own, {repo_dir_default})")
	ap.add_argument("--worktree-parent", default="ctte_worktrees",
	                help="directory holding sibling worktrees (default: ctte_worktrees)")
	ap.add_argument("--suffix", action="append", default=None,
	                help=f"file suffix to consider (repeatable; default: {' '.join(DEFAULT_SUFFIXES)})")
	args = ap.parse_args(argv)

	suffixes = tuple(args.suffix) if args.suffix else DEFAULT_SUFFIXES
	targets = args.targets or [DEFAULT_TARGET]

	touched = 0
	subs = 0
	seen = 0
	for f in iter_files(targets, suffixes):
		seen += 1
		before = f.read_bytes()
		after, n = scrub(before, args.repo_dir, args.worktree_parent)
		if after == before:
			continue
		touched += 1
		subs += n
		verb = "would scrub" if args.check else "scrubbed"
		print(f"  [{verb}] {f.as_posix()} ({n} substitution{'s' if n != 1 else ''})")
		if not args.check:
			f.write_bytes(after)

	print(f"scrub_evidence_headers: {seen} file(s) examined, "
	      f"{touched} {'would change' if args.check else 'changed'}, {subs} substitution(s)")
	if args.check and touched:
		return 1
	return 0


if __name__ == "__main__":
	sys.exit(main())
