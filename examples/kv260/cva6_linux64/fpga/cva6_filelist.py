#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""cva6_filelist.py -- resolves CVA6 Flist manifests into a flat file list.

Upstream builds with ${CVA6_REPO_DIR}/${TARGET_CFG}/${HPDCACHE_DIR}
substitution and nested `-F <flist>` includes (core/Flist.cva6 ->
hpdcache.Flist). XSIM/Vivado need a resolved, absolute list from us (one
path per line), or the +incdir+ directories (--incdirs).

    py cva6_filelist.py third_party/cva6_ref/core/Flist.cva6 --target cv32a6_ima_sv32_fpga
    py cva6_filelist.py ... --incdirs

Migrated 2026-08 from an internal predecessor repository. This is a
per-example copy: there is no repository-wide tools/ tree, and four example
flows carry a copy of this file (examples/kv260/{cva6_linux,cva6_linux64,
cva6_2}/fpga/ and examples/kv260/trio/tools/). Promoting it to one shared
location is an open item.

It resolves the CVA6-with-ITI fork's Flist manifest, so it needs that core
present: fetch it with examples/kv260/third_party/fetch.sh (pin and local
deltas: examples/kv260/third_party/CVA6_PIN.md). Without the fetch, the
CVA6-file-resolution step of the calling TCL flow fails with a clear,
actionable error rather than a silent or cryptic one.
"""
import argparse
import os
import sys


def resolve(flist_path, env, files, incdirs, seen):
    flist_path = os.path.abspath(flist_path)
    if flist_path in seen:
        return
    seen.add(flist_path)
    with open(flist_path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            for key, val in env.items():
                line = line.replace("${%s}" % key, val)
            if "${" in line:
                sys.exit("cva6_filelist: unresolved variable in line: " + line)
            if line.startswith("+incdir+"):
                d = os.path.normpath(line[len("+incdir+"):])
                if d not in incdirs:
                    incdirs.append(d)
            elif line.startswith("-F"):
                resolve(os.path.normpath(line.split(None, 1)[1]), env, files, incdirs, seen)
            else:
                p = os.path.normpath(line)
                if not os.path.isfile(p):
                    sys.exit("cva6_filelist: file missing: " + p)
                if p not in files:
                    files.append(p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("flist")
    ap.add_argument("--target", default="cv32a60x")
    ap.add_argument("--incdirs", action="store_true", help="print only the +incdir+ directories")
    ap.add_argument("--exclude", action="append", default=[],
                    help="substring exclusion (e.g. instr_tracer.sv)")
    args = ap.parse_args()

    flist = os.path.abspath(args.flist)
    repo = os.path.dirname(os.path.dirname(flist))  # <repo>/core/Flist.cva6 -> <repo>
    env = {
        "CVA6_REPO_DIR": repo,
        "TARGET_CFG": args.target,
        "HPDCACHE_DIR": os.path.join(repo, "core", "cache_subsystem", "hpdcache"),
    }
    files, incdirs = [], []
    resolve(flist, env, files, incdirs, set())
    # exact basename match ("counter.sv" must NOT match delta_counter.sv)
    files = [f for f in files if os.path.basename(f) not in args.exclude]
    for item in (incdirs if args.incdirs else files):
        print(item)


if __name__ == "__main__":
    main()
