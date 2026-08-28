#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Copy stdin (or a file) into physical memory through /dev/mem via mmap.

WHY NOT dd. `dd of=/dev/mem seek=...` uses write(2), and on the KV260's
Ubuntu kernel 5.15.0-1052-xilinx-zynqmp that path fails with "Bad address"
for the reserved-memory window (0x6000_0000 +256 MiB) that carries the soft
core's Linux payload -- while mmap(2) on the same range works (busybox
devmem does exactly that). Found 2026-08-17 during the cva6_linux board gate
on kria-kv260; the earlier board (kv260b) ran a kernel that accepted the
write path, which is why the driver used dd until now.

Runs ON THE BOARD (python3 is part of the Ubuntu image). Needs root.

    python3 mem_load.py --addr 0x64000000 < fw_payload.bin
    python3 mem_load.py --addr 0x64000000 --file fw_payload.bin --verify

--verify reads the range back and compares byte for byte; the exit code is
the verdict (0 ok, 3 mismatch).

WHY A 32-BIT WORD LOOP AND NOT AN mmap SLICE COPY. Until 2026-08-21 this
file wrote the payload with `m[0:n] = data`, i.e. a glibc memcpy on the
mapping. On the reserved PL window that memcpy uses NEON/unaligned stores,
and those SIGBUS on a Device-nGnRnE mapping -- the same lesson the sibling
tool phys_io.py records in its own header ("ACCESS WIDTH: strictly 32 bit
through ctypes").

The failure mode was as quiet as it gets, which is why it survived: the
write died with SIGBUS at exactly 16 MiB (measured on kria-kv260b,
2026-08-21, guest window 0x6400_0000), the calling board script swallowed
the signal with `|| true`, its DDR probe read the FIRST word of the window
-- which had been written -- and the boot that followed looked plausible
because OpenSBI and the head of the kernel are inside the first 16 MiB.
Only the tail of the image was missing. A payload of 17.7 MB therefore
booted far enough to print a kernel log and could never reach userspace.

So: write and read strictly word by word, and let the caller see a failure.
Cost on the board: ~50 s for 32 MB (measured, not estimated).
"""

import argparse
import ctypes
import mmap
import os
import sys

PAGE = mmap.PAGESIZE


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--addr", required=True, help="physical start address (hex ok)")
    ap.add_argument("--file", help="source file (default: stdin)")
    ap.add_argument("--verify", action="store_true", help="read back and compare")
    a = ap.parse_args()
    addr = int(a.addr, 0)
    if addr % PAGE:
        sys.exit("mem_load: --addr must be page aligned (%d)" % PAGE)

    data = open(a.file, "rb").read() if a.file else sys.stdin.buffer.read()
    n = len(data)
    if n == 0:
        sys.exit("mem_load: nothing to write")
    span = (n + PAGE - 1) // PAGE * PAGE

    # Pad to a whole number of 32-bit words -- the word loop below writes
    # nothing narrower, and a trailing 1..3 bytes would otherwise be dropped.
    padded = data + b"\x00" * (-n % 4)
    words = len(padded) // 4

    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        m = mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                      offset=addr)
        # ctypes view on the mapping: every store is exactly one 32-bit
        # access, which is what a Device-nGnRnE mapping accepts. See the
        # header for what the slice copy did instead.
        dst = (ctypes.c_uint32 * words).from_buffer(m)
        src = (ctypes.c_uint32 * words).from_buffer_copy(padded)
        for i in range(words):
            dst[i] = src[i]
        # no m.flush(): msync on a /dev/mem mapping is EINVAL here, and the
        # O_SYNC mapping is uncached device memory anyway (verified 2026-08-17)
        rc = 0
        if a.verify:
            for i in range(words):
                if dst[i] != src[i]:
                    print("mem_load: VERIFY MISMATCH at +0x%x (0x%08x)"
                          % (i * 4, addr + i * 4))
                    rc = 3
                    break
            else:
                print("mem_load: verify ok (%d bytes)" % n)
        del dst, src
        m.close()
        if rc == 0:
            print("mem_load: wrote %d bytes at 0x%08x" % (n, addr))
        return rc
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
