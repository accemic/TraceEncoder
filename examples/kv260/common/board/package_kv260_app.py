#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Package a built KV260 example bitstream into a loadable app (and bundle).

Input:  a routed .bit (from the example's fpga/ flow) + an app name.
Output: an app directory  <out>/<app>/  with
            <app>.bit.bin   (bootgen, Kria fpga-manager format)
            <app>.dtso      (from kv260_app.dtso.in, @APP@ filled in)
            shell.json
            MANIFEST.sha256 (sha256 of every file above)
        and with --bundle additionally <out>/<app>-<version>.tar.gz -- a
        DETERMINISTIC tarball (sorted entries, fixed mtime/uid/gid, gzip
        without timestamp), so the same inputs give the same checksum on
        every rebuild. That determinism is what makes the published checksum
        of a demo bundle worth anything.

The dtbo is deliberately NOT built here: dtc lives on the board, not on the
workstation (deploy scripts compile it there -- see the predecessor repository board
flows this packaging was lifted from).

USAGE
    py examples/kv260/common/board/package_kv260_app.py \
        --bit <path>.bit --app mbv_ctrace_kv260 [--bundle --version vX]

Exit codes: 0 ok - 2 bad arguments / missing input - 3 bootgen failed.
"""

import argparse
import gzip
import hashlib
import io
import os
import subprocess
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))


def die(code, msg):
    sys.stderr.write("package_kv260_app: %s\n" % msg)
    sys.exit(code)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_bootgen(vivado_bin, bit, out_bitbin, workdir):
    bif = os.path.join(workdir, "package.bif")
    with open(bif, "w", newline="\n") as fh:
        fh.write("all:\n{\n\t%s\n}\n" % bit)
    bootgen = os.path.join(vivado_bin, "bootgen.bat" if os.name == "nt" else "bootgen")
    cmd = [bootgen, "-arch", "zynqmp", "-image", bif, "-o", out_bitbin, "-w"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_bitbin):
        die(3, "bootgen failed (%d):\n%s%s" % (r.returncode, r.stdout, r.stderr))


def deterministic_targz(src_dir, names, out_path):
    """tar.gz of `names` (relative to src_dir) with all history scrubbed."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for n in sorted(names):
            p = os.path.join(src_dir, n)
            ti = tar.gettarinfo(p, arcname=n)
            ti.mtime = 0
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            with open(p, "rb") as fh:
                tar.addfile(ti, fh)
    with open(out_path, "wb") as fh:
        with gzip.GzipFile(fileobj=fh, mode="wb", mtime=0) as gz:
            gz.write(buf.getvalue())


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bit", required=True, help="routed .bit from the example's fpga flow")
    ap.add_argument("--app", required=True, help="app name, e.g. mbv_ctrace_kv260")
    ap.add_argument("--vivado-bin", default=r"C:\Xilinx\2026.1\Vivado\bin",
                    help="directory holding bootgen")
    ap.add_argument("--out", default=None,
                    help="output directory (default: <bit dir>/app_pkg)")
    ap.add_argument("--bundle", action="store_true",
                    help="additionally write <app>-<version>.tar.gz + .sha256")
    ap.add_argument("--version", default="dev",
                    help="version string of the demo series (e.g. v1.0.1-demo2)")
    args = ap.parse_args()

    bit = os.path.abspath(args.bit)
    if not os.path.exists(bit):
        die(2, "no such .bit: %s" % bit)
    out = os.path.abspath(args.out or os.path.join(os.path.dirname(bit), "app_pkg"))
    appdir = os.path.join(out, args.app)
    os.makedirs(appdir, exist_ok=True)

    # 1. bit.bin
    bitbin = os.path.join(appdir, args.app + ".bit.bin")
    run_bootgen(args.vivado_bin, bit, bitbin, appdir)

    # 2. dtso from the template
    tmpl = open(os.path.join(HERE, "kv260_app.dtso.in"), encoding="utf-8").read()
    with open(os.path.join(appdir, args.app + ".dtso"), "w", newline="\n") as fh:
        fh.write(tmpl.replace("@APP@", args.app))

    # 3. shell.json
    shell = open(os.path.join(HERE, "shell.json"), "rb").read()
    with open(os.path.join(appdir, "shell.json"), "wb") as fh:
        fh.write(shell)

    # 3b. Linux-payload apps (cva6_linux*, rocket*) boot a soft core out of a
    # reserved PS-DDR window that ONLY the boot devicetree can carve out; the
    # runtime xmutil overlay above cannot. Without ctrace_resmem.dtso applied
    # once per board the kernel hands the window out and the core boots into
    # foreign memory. A demo bundle that omits it is not usable stand-alone
    # (audit 2026-08-18), so it ships with these apps, plus a one-page note.
    names = [args.app + ".bit.bin", args.app + ".dtso", "shell.json"]
    if args.app.startswith(("cva6_linux", "rocket")):
        for extra in ("ctrace_resmem.dtso",):
            data = open(os.path.join(HERE, extra), "rb").read()
            with open(os.path.join(appdir, extra), "wb") as fh:
                fh.write(data)
            names.append(extra)
        note_text = (
            "ONE-TIME BOARD SETUP for Linux-payload apps (%s)\n"
            "The soft core boots from a reserved PS-DDR window. Apply ctrace_resmem.dtso to the\n"
            "BOOT devicetree once per board (needs a reboot), e.g. on the KV260 Ubuntu image:\n"
            "  dtc -@ -I dts -O dtb -o ctrace_resmem.dtbo ctrace_resmem.dtso\n"
            "  # merge into the boot DT / user-override.dtb per your image's overlay mechanism, reboot,\n"
            "  ls /sys/firmware/devicetree/base/reserved-memory/   # must list ctrace-pl-ddr@...\n"
            "The runtime overlay %s.dtso (xmutil loadapp) does NOT do this. Board driver:\n"
            "examples/kv260/cva6_linux/board/cva6_linux_boot_trace.sh in https://github.com/accemic/TraceEncoder\n"
        ) % (args.app, args.app)
        with open(os.path.join(appdir, "BOARD_SETUP.txt"), "w", newline="\n") as fh:
            fh.write(note_text)
        names.append("BOARD_SETUP.txt")

    # 4. manifest
    with open(os.path.join(appdir, "MANIFEST.sha256"), "w", newline="\n") as fh:
        for n in names:
            fh.write("%s  %s\n" % (sha256_of(os.path.join(appdir, n)), n))
    print("app-dir %s" % appdir)
    for n in names:
        print("  %-28s %s" % (n, sha256_of(os.path.join(appdir, n))[:12]))

    # 5. bundle
    if args.bundle:
        bname = "%s-%s.tar.gz" % (args.app, args.version)
        bpath = os.path.join(out, bname)
        deterministic_targz(appdir, names + ["MANIFEST.sha256"], bpath)
        bsum = sha256_of(bpath)
        with open(bpath + ".sha256", "w", newline="\n") as fh:
            fh.write("%s  %s\n" % (bsum, bname))
        print("bundle  %s\n  sha256 %s" % (bpath, bsum))
    return 0


if __name__ == "__main__":
    sys.exit(main())
