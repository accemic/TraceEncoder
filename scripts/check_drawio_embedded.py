#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""A drawing lives in exactly one file, and that file is the image.

Every `*.drawio.png` / `*.drawio.svg` in this tree carries its own draw.io
source inside it -- the XML rides in a PNG text chunk or an SVG `content`
attribute -- so opening the image in draw.io recovers the editable drawing.
That is the whole convention, and it has two failure modes this guard closes:

  1. A SIBLING `.drawio` file appears next to the image. Now there are two
     copies of one drawing and nothing keeps them equal. Measured on
     2026-08-21, before this guard existed: doc/images/specs-overlap.drawio
     and the XML inside specs-overlap.drawio.png had already diverged in
     representation (expanded vs. base64+deflate) -- same content that day,
     but nothing would have said so on the day they stopped matching.

  2. An image loses its embedded source -- exported without draw.io's `-e`,
     or run through an optimiser that strips ancillary chunks. The picture
     still looks right, so review passes, and the drawing is simply gone.
     That is not a cosmetic loss: the PNG is the source.

The guard therefore asserts, for every tracked `*.drawio.png|svg`:
  * no sibling `<name>.drawio` exists, and
  * the embedded source is present and parses as draw.io XML.

Re-export after editing with:
    drawio -x -f png -e -s 2 -b 0 -o <name>.drawio.png <name>.drawio
    python3 scripts/check_drawio_embedded.py

Exit 0 = every drawing is self-contained, 1 = at least one is not.
"""

import base64
import re
import struct
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def _png_source(data: bytes):
    """Return the draw.io XML in a PNG's tEXt/zTXt/iTXt chunk, or None."""
    off = 8
    while off + 8 <= len(data):
        (length,) = struct.unpack(">I", data[off:off + 4])
        ctype = data[off + 4:off + 8]
        body = data[off + 8:off + 8 + length]
        if ctype in (b"tEXt", b"zTXt", b"iTXt"):
            key, _, rest = body.partition(b"\0")
            if key in (b"mxfile", b"mxGraphModel"):
                if ctype == b"zTXt":
                    rest = zlib.decompress(rest[1:])   # drop the method byte
                elif ctype == b"iTXt":
                    rest = rest.split(b"\0", 3)[-1]
                text = rest.decode("utf-8", "replace")
                # draw.io URL-encodes the chunk payload.
                if "%3C" in text or "%3c" in text:
                    text = urllib.parse.unquote(text)
                return text
        off += 12 + length
        if ctype == b"IEND":
            break
    return None


def _svg_source(data: bytes):
    """Return the draw.io XML in an SVG `content` attribute, or None."""
    m = re.search(rb'content="([^"]*)"', data)
    if not m:
        return None
    from html import unescape
    return unescape(m.group(1).decode("utf-8", "replace"))


def _parses(text: str) -> bool:
    """draw.io stores the model either expanded or base64+deflate-compressed."""
    if text is None:
        return False
    try:
        if "<mxGraphModel" not in text:
            payload = re.search(r"<diagram[^>]*>([^<]+)</diagram>", text)
            if not payload:
                return False
            raw = zlib.decompress(base64.b64decode(payload.group(1)), -15)
            text = urllib.parse.unquote(raw.decode("utf-8"))
        return any(True for _ in ET.fromstring(text).iter("mxCell"))
    except Exception:
        return False


def main() -> int:
    tracked = subprocess.run(
        ["git", "-C", str(REPO), "ls-files"],
        capture_output=True, text=True, check=True).stdout.split()

    images = [f for f in tracked if f.endswith((".drawio.png", ".drawio.svg"))]
    if not images:
        print("[check_drawio_embedded] ERROR: no *.drawio.png|svg tracked -- "
              "this guard would pass over nothing")
        return 1

    failures = []
    for rel in sorted(images):
        path = REPO / rel
        sibling = Path(str(path)[: -len(path.suffix)])   # strip .png / .svg
        if sibling.exists():
            failures.append(
                f"  [FAIL] {sibling.relative_to(REPO)} sits next to {rel}. "
                f"The image already carries the source; a second copy has "
                f"nothing keeping it equal. Delete the sibling.")

        data = path.read_bytes()
        src = _png_source(data) if rel.endswith(".png") else _svg_source(data)
        if not _parses(src):
            failures.append(
                f"  [FAIL] {rel} carries no readable draw.io source. Re-export "
                f"WITH draw.io's -e flag: drawio -x -f "
                f"{'png -e -s 2 -b 0' if rel.endswith('.png') else 'svg -e'} "
                f"-o {rel} <source>.drawio")

    if failures:
        print("\n".join(failures))
        print(f"[check_drawio_embedded] {len(failures)} failure(s)")
        return 1

    print(f"[check_drawio_embedded] OK: {len(images)} drawing(s), each its own "
          f"editable source, no sibling duplicates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
