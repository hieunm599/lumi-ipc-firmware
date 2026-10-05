#!/usr/bin/env python3
"""Pack local T23N artifacts using isvp_common.h's 2 MiB kernel/5 MiB rootfs layout.

This creates a fresh image, not a factory dump with device-specific data.
The SPL is expected to use upstream isvp_t23_sfcnor (DDR2, 64 MiB).
"""

import argparse
import hashlib
from pathlib import Path
import struct
import zlib

FLASH_SIZE = 0x800000
PARTITIONS = (
    ("uboot", 0x000000, 0x40000),
    ("env", 0x040000, 0x10000),
    ("kernel", 0x050000, 0x200000),
    ("rootfs", 0x250000, 0x500000),
    ("rootfs_data", 0x750000, 0xB0000),
)
SPL_PAD = 26624


def check_uimage(data, image_type, compression):
    if len(data) < 64:
        raise ValueError("truncated uImage")
    magic, hcrc, _, size, _, _, dcrc = struct.unpack_from(">7I", data)
    if magic != 0x27051956 or size != len(data) - 64:
        raise ValueError("invalid uImage magic or payload size")
    header = data[:4] + bytes(4) + data[8:64]
    if zlib.crc32(header) != hcrc or zlib.crc32(data[64:]) != dcrc:
        raise ValueError("uImage CRC mismatch")
    if data[29:32] != bytes((5, image_type, compression)):
        raise ValueError("unexpected uImage architecture/type/compression")


def pack(uboot, kernel, rootfs, flash_mib=8):
    if flash_mib not in (8, 16):
        raise ValueError("only 8 or 16 MiB NOR is supported")
    inputs = dict(uboot=uboot, kernel=kernel, rootfs=rootfs)
    for name, _, capacity in PARTITIONS:
        if name in inputs and not 0 < len(inputs[name]) <= capacity:
            raise ValueError(f"{name}: empty or exceeds {capacity} bytes")
    # MIPS firmware/LZO after padded SPL; MIPS Linux kernel/LZMA.
    check_uimage(uboot[SPL_PAD:], 5, 4)
    check_uimage(kernel, 2, 3)
    if kernel[28] != 5:
        raise ValueError("kernel is not Linux")
    if len(rootfs) < 96 or rootfs[:4] != b"hsqs":
        raise ValueError("rootfs is not little-endian SquashFS")
    used = struct.unpack_from("<Q", rootfs, 40)[0]
    if struct.unpack_from("<HH", rootfs, 28) != (4, 0) or not 96 <= used <= len(rootfs):
        raise ValueError("invalid SquashFS version or bytes_used")
    image = bytearray(b"\xff" * (flash_mib * 1024 * 1024))
    for name, offset, _ in PARTITIONS:
        if name in inputs:
            image[offset:offset + len(inputs[name])] = inputs[name]
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flash-mib", type=int, choices=(8, 16), default=8)
    for name in ("uboot", "kernel", "rootfs", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args()
    try:
        image = pack(args.uboot.read_bytes(), args.kernel.read_bytes(), args.rootfs.read_bytes(), args.flash_mib)
        # Exclusive creation: never overwrite inputs, existing dumps or releases.
        with args.output.open("xb") as output:
            output.write(image)
        if args.output.read_bytes() != image:
            raise ValueError("output read-back differs")
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"{hashlib.sha256(image).hexdigest()}  {args.output.name}")


if __name__ == "__main__":
    main()
