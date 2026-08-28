#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""phys_io.py -- block-wise physical memory I/O on the KV260. Runs ON THE BOARD.

    sudo python3 phys_io.py write 0x64000000 fw_payload.bin
    sudo python3 phys_io.py read  0xA0200000 0x100000 > trace.bin
    sudo python3 phys_io.py read  0x60000000 0x400000 -o sink.bin

WHY A DEDICATED TOOL AND NOT `dd if=/dev/mem`:
  * `dd` uses read()/write() on /dev/mem. For `no-map` reserved ranges (the
    PL-DDR window) and for the AXI-Lite aperture the kernel answers with
    **"Bad address"** on that path -- there is no kernel mapping for it. Only
    mmap works (measured on the board 2026-07-27).
  * `busybox devmem` can do it, but only ONE word per process invocation: a
    1 MiB trace ring would be 262,144 process starts.

ACCESS WIDTH: strictly 32 bit through ctypes. A glibc memcpy (an mmap slice
assignment) uses NEON/unaligned stores and SIGBUSes on Device-nGnRnE
mappings -- the same lesson is recorded in the dashboard server.

This is the read/write counterpart of `mem_load.py` (which only writes).
The board boot recipes under `examples/dashboard/boot/` call it as
`/tmp/phys_io.py`; `board_dashboard_install.sh` stages it there.
"""
import ctypes
import mmap
import os
import struct
import sys

PAGE = 0x1000


def _map(fd, addr, length, prot):
    page = addr & ~(PAGE - 1)
    off = addr - page
    mlen = (off + length + PAGE - 1) & ~(PAGE - 1)
    m = mmap.mmap(fd, mlen, mmap.MAP_SHARED, prot, offset=page)
    return m, off


def phys_write_bulk(addr, data):
    """Slice copy for writing -- DOES NOT WORK ON THE RESERVED PL WINDOW.

    Measured 2026-07-28: the reserved PL window is `no-map` and /dev/mem maps
    it as device memory. glibc's NEON memcpy faults there with SIGBUS. For
    READING the slice copy is fine (64 MiB in 1.08 s), for WRITING it is not
    -- there the ctypes word loop stays mandatory. This function remains for
    genuine, mapped DDR.

    A 47 MB Linux image is 11.7 million words; as a ctypes word loop that
    takes minutes and keeps the host under load far longer than necessary.
    For the AXI-Lite aperture the word loop stays mandatory -- glibc's NEON
    memcpy SIGBUSes there.
    """
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        m, off = _map(fd, addr, len(data), mmap.PROT_READ | mmap.PROT_WRITE)
        m[off:off + len(data)] = data
        m.flush()
        m.close()
    finally:
        os.close(fd)
    return len(data)


def phys_write(addr, data):
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        m, off = _map(fd, addr, len(data), mmap.PROT_READ | mmap.PROT_WRITE)
        words = struct.unpack("<%dI" % (len(data) // 4), data)
        for i, w in enumerate(words):
            ctypes.c_uint32.from_buffer(m, off + 4 * i).value = w
        m.close()
    finally:
        os.close(fd)
    return len(data)


def phys_read_bulk(addr, length):
    """Like phys_read, but as a slice copy -- ONLY for ordinary DDR.

    The DDR sink buffer is ordinary memory, so a memcpy is allowed there and
    is ~100x faster than the word loop (64 MiB are 16.7 million single
    accesses). For the AXI-Lite aperture this is FORBIDDEN: that range is
    mapped Device-nGnRnE, where glibc's NEON memcpy SIGBUSes.
    """
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        m, off = _map(fd, addr, length, mmap.PROT_READ | mmap.PROT_WRITE)
        data = m[off:off + length]
        m.close()
    finally:
        os.close(fd)
    return data


def phys_read(addr, length):
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        # PROT_READ|PROT_WRITE although we only read: ctypes.from_buffer
        # demands a writable buffer ("underlying buffer is not writable"),
        # and only ctypes guarantees the 32-bit access width.
        m, off = _map(fd, addr, length, mmap.PROT_READ | mmap.PROT_WRITE)
        out = bytearray(length)
        nw = length // 4
        for i in range(nw):
            struct.pack_into("<I", out, 4 * i,
                             ctypes.c_uint32.from_buffer(m, off + 4 * i).value)
        m.close()
    finally:
        os.close(fd)
    return bytes(out)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    op = argv[1]
    addr = int(argv[2], 0)
    if op in ("write", "writebulk"):
        with open(argv[3], "rb") as f:
            data = f.read()
        n = phys_write_bulk(addr, data) if op == "writebulk" else phys_write(addr, data)
        sys.stderr.write("WROTE %d bytes @0x%08x\n" % (n, addr))
    elif op in ("read", "readbulk"):
        length = int(argv[3], 0)
        data = phys_read_bulk(addr, length) if op == "readbulk" else phys_read(addr, length)
        if "-o" in argv:
            path = argv[argv.index("-o") + 1]
            with open(path, "wb") as f:
                f.write(data)
            sys.stderr.write("READ %d bytes @0x%08x -> %s\n" % (len(data), addr, path))
        else:
            sys.stdout.buffer.write(data)
            sys.stderr.write("READ %d bytes @0x%08x\n" % (len(data), addr))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
