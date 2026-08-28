#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Fetch the pinned CTTD (CEDARtools.TraceDecoder) binary into bin/.

CTTD is the reference decoder this repository's gates decode with. It used to
live here as three committed binaries; it now lives in its own repository with
its own CI, and this script brings the pinned build back in.

WHY PYTHON AND NOT A SHELL SCRIPT. Half the developers here work on Windows,
where scripts/ct_env.sh needs a bash. A developer who has just cloned the
repository has to be able to get a decoder without first having a POSIX shell,
so this one is stdlib-only Python 3 and runs the same on both.

WHY A CHECKSUM AND NOT JUST A VERSION. A decoder that silently changed
behaviour is the worst possible thing to hand a gate: every verdict in this
repository is only worth what the decoder is. The pin therefore names the
exact sha256 per platform, and a mismatch is a hard error, never a warning.
The behavioural record of each pin lives with CTTD (its CHANGELOG), not here.

USAGE
    python3 scripts/fetch_cttd.py                  # host platform
    python3 scripts/fetch_cttd.py --platform linux-arm64   # for a board deploy
    python3 scripts/fetch_cttd.py --all            # every pinned platform
    python3 scripts/fetch_cttd.py --check          # verify what is in bin/

Exit codes: 0 ok - 2 pin file unusable - 3 download failed -
4 checksum mismatch - 5 unknown platform.
"""

import argparse
import base64
import hashlib
import os
import platform
import subprocess
import sys
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIN = os.path.join(REPO, "scripts", "cttd.pin")
BIN = os.path.join(REPO, "bin")

# Asset name per platform key, as published by the CTTD release workflow.
ASSETS = {
    "linux-x86_64": "cttd-linux-x86_64",
    "linux-arm64": "cttd-linux-arm64",
    "windows-x64": "cttd-windows-x64.exe",
}

# Keys of the pin that are neither base_url, version nor sha256.*. Filled by
# read_pin(); today there is exactly one, `auth` (see auth_header()).
PIN_OPTIONS = {}
AUTH_MODES = ("none", "git-credential")


def host_platform():
    """The platform key for the machine this runs on."""
    sysname = platform.system()
    machine = platform.machine().lower()
    if sysname == "Windows":
        return "windows-x64"
    if sysname == "Linux":
        if machine in ("aarch64", "arm64"):
            return "linux-arm64"
        return "linux-x86_64"
    die(5, "unsupported host: %s/%s -- pass --platform explicitly" % (sysname, machine))


def die(code, msg):
    sys.stderr.write("fetch_cttd: %s\n" % msg)
    sys.exit(code)


def read_pin(PIN=PIN):
    """Parse scripts/cttd.pin -> (base_url, version, {platform: sha256}).

    The format is deliberately dumb (key = value, '#' comments) so it can be
    read by eye and edited in a review without a parser in the loop.

    The path is an argument (--pin) for one reason: so this script's own happy
    path can be exercised against a file:// pin before the real CTTD release
    exists. A fetch script whose only tested behaviour is its refusal is not a
    tested fetch script.
    """
    if not os.path.exists(PIN):
        die(2, "pin file missing: %s" % PIN)
    base_url = version = None
    sums = {}
    PIN_OPTIONS.clear()
    with open(PIN, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if "=" not in line:
                die(2, "%s:%d: not a key = value line: %s" % (PIN, lineno, raw.rstrip()))
            key, val = (x.strip() for x in line.split("=", 1))
            if key == "base_url":
                base_url = val
            elif key == "version":
                version = val
            elif key.startswith("sha256."):
                sums[key[len("sha256."):]] = val.lower()
            elif key == "auth":
                if val not in AUTH_MODES:
                    die(2, "%s:%d: auth must be one of %s, not %r"
                           % (PIN, lineno, "/".join(AUTH_MODES), val))
                PIN_OPTIONS["auth"] = val
            else:
                die(2, "%s:%d: unknown key %r" % (PIN, lineno, key))
    if not base_url or not version:
        die(2, "%s: base_url and version are both required" % PIN)
    # An unfilled pin must fail loudly. A placeholder that silently downloads
    # nothing, or worse downloads something unverified, would be exactly the
    # "silent" failure this script exists to prevent.
    if "REPLACE_ME" in base_url or "REPLACE_ME" in version:
        die(2, "%s still carries placeholders -- the CTTD repository location "
               "has not been filled in. "
               "Fill base_url, version and the sha256.* lines from a real "
               "CTTD release before using this script." % PIN)
    return base_url, version, sums


def auth_header(url):
    """Authorization header for the pinned host, or None.

    Only when the pin says `auth = git-credential`. The default is to send
    NO credential, and that is not laziness: a public release host such as
    GitHub answers the asset URL with a redirect to a pre-signed storage URL,
    and a request that carries an Authorization header into that redirect is
    refused there -- so a developer who happens to hold a github.com
    credential would be locked out of a public download that works for
    everyone else. A PRIVATE mirror (a company git server without an
    anonymous asset store) opts in with the pin key, and then the fetch asks
    the same place git does: the credential helper. No credential is not an
    error either way; the request goes out unauthenticated and fetch()
    reports what came back. Git is told not to prompt: a helper that opens a
    browser or a terminal prompt from inside a fetch script is worse than a
    404.
    """
    if PIN_OPTIONS.get("auth", "none") != "git-credential":
        return None
    from urllib.parse import urlparse
    host = urlparse(url).hostname or ""
    # Belt and braces: never send a credential to GitHub, whatever the pin
    # says -- see above; a stale `auth` line must not be able to break a
    # public download.
    if host == "github.com" or host.endswith(".github.com") or host.endswith(".githubusercontent.com"):
        return None
    try:
        cred_query = "protocol=https\nhost=%s\n\n" % host
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
        out = subprocess.run(["git", "credential", "fill"],
                             input=cred_query, env=env,
                             capture_output=True, text=True, timeout=10).stdout
        d = dict(l.split("=", 1) for l in out.strip().splitlines() if "=" in l)
        if d.get("username") and d.get("password"):
            tok = base64.b64encode(
                ("%s:%s" % (d["username"], d["password"])).encode()).decode()
            return "Basic " + tok
    except Exception:
        pass
    return None


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(plat, base_url, version, sums, check_only=False, BIN=BIN):
    if plat not in ASSETS:
        die(5, "unknown platform %r (known: %s)" % (plat, ", ".join(sorted(ASSETS))))
    if plat not in sums:
        die(2, "no sha256 pinned for %s in %s" % (plat, PIN))
    asset = ASSETS[plat]
    dest = os.path.join(BIN, asset)

    if os.path.exists(dest):
        have = sha256_of(dest)
        if have == sums[plat]:
            print("ok   %s: already at the pinned build (%s)" % (asset, have[:12]))
            return
        if check_only:
            die(4, "%s: sha256 %s does not match the pin %s"
                   % (asset, have[:12], sums[plat][:12]))
        print("note %s: present but not the pinned build -- refetching" % asset)
    elif check_only:
        die(4, "%s: not present in bin/" % asset)

    url = "%s/%s/%s" % (base_url.rstrip("/"), version, asset)
    os.makedirs(BIN, exist_ok=True)
    tmp = dest + ".part"
    print("get  %s" % url)
    try:
        req = urllib.request.Request(url)
        auth = auth_header(url)
        if auth:
            req.add_header("Authorization", auth)
        with urllib.request.urlopen(req) as resp, open(tmp, "wb") as out:
            ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
            out.write(resp.read())
    except (urllib.error.URLError, OSError) as exc:
        if os.path.exists(tmp):
            os.remove(tmp)
        die(3, "download failed: %s" % exc)

    # A WEB PAGE IS NOT A DECODER, AND MUST NOT BE REPORTED AS A BAD ONE.
    #
    # Some hosts answer a request they will not serve with 200 and an HTML
    # page (a login page, a "not found" page) instead of 404 with nothing.
    # The bytes then hash to something that is not the pin, and the next
    # line below would say "checksum mismatch" -- which reads like a broken
    # release and sends the reader to look for one. It is not: it is a URL
    # that did not resolve to the asset. Measured 2026-08-19 during a
    # walkthrough of the tutorial from an outsider's point of view, where it
    # was the first blocker and cost the most time to understand.
    #
    # So: name what actually arrived. The check is on the content type and on
    # the leading bytes, because a server may omit the header.
    head = b""
    try:
        with open(tmp, "rb") as fh:
            head = fh.read(512)
    except OSError:
        pass
    looks_html = (ctype in ("text/html", "application/xhtml+xml")
                  or head[:15].lower().startswith(b"<!doctype html")
                  or head[:6].lower().startswith(b"<html"))
    if looks_html:
        os.remove(tmp)
        die(3, "\n".join([
            "the server returned an HTML page, not the %s asset." % asset,
            "  url: %s" % url,
            "  A web page in place of a binary means the URL did not resolve",
            "  to the asset: a wrong base_url or version in the pin, a release",
            "  that does not carry this asset, or a private mirror answering",
            "  with its login page. It is not a broken build -- the pinned",
            "  checksums are fine. Fix it by one of:",
            "    * opening the URL in a browser and reading what the host says;",
            "    * for a private mirror: `auth = git-credential` in the pin,",
            "      so the credential helper is asked (you have a credential",
            "      if you can clone from that host);",
            "    * fetching the asset by hand and dropping it into bin/ --",
            "      this script then verifies its sha256 like any other;",
            "    * pointing base_url in %s at a mirror you can read." % PIN,
        ]))

    got = sha256_of(tmp)
    if got != sums[plat]:
        os.remove(tmp)
        die(4, "checksum mismatch for %s\n  pinned: %s\n  got:    %s\n"
               "A decoder that is not the pinned one invalidates every verdict "
               "it produces -- refusing." % (asset, sums[plat], got))
    os.replace(tmp, dest)
    if not asset.endswith(".exe"):
        os.chmod(dest, 0o755)
    print("ok   %s (%s)" % (asset, got[:12]))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--platform", help="platform key (default: this host)")
    ap.add_argument("--all", action="store_true", help="fetch every pinned platform")
    ap.add_argument("--check", action="store_true",
                    help="verify bin/ against the pin, download nothing")
    ap.add_argument("--pin", default=PIN, help="pin file (default: scripts/cttd.pin)")
    ap.add_argument("--dest", default=BIN, help="target directory (default: bin/)")
    args = ap.parse_args()

    base_url, version, sums = read_pin(args.pin)
    plats = sorted(sums) if args.all else [args.platform or host_platform()]
    for p in plats:
        fetch(p, base_url, version, sums, check_only=args.check, BIN=args.dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
