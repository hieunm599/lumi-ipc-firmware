#!/usr/bin/env python3
"""Host-only checks: python3 contrib/test-pack-t23n-nor8.py."""

import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPT = Path(__file__).with_name("pack-t23n-nor8.py")
SPEC = importlib.util.spec_from_file_location("packer", SCRIPT)
packer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packer)


def uimage(kind, compression):
    payload = b"test payload"
    header = bytearray(64)
    struct.pack_into(">7I", header, 0, 0x27051956, 0, 0, len(payload), 0, 0, zlib.crc32(payload))
    header[28:32] = bytes((5, 5, kind, compression))
    struct.pack_into(">I", header, 4, zlib.crc32(header))
    return bytes(header) + payload


class PackTest(unittest.TestCase):
    def setUp(self):
        rootfs = bytearray(96)
        rootfs[:4] = b"hsqs"
        struct.pack_into("<HH", rootfs, 28, 4, 0)
        struct.pack_into("<Q", rootfs, 40, 96)
        self.inputs = [bytes(packer.SPL_PAD) + uimage(5, 4), uimage(2, 3), bytes(rootfs)]

    def test_offsets_and_erased_regions(self):
        image = packer.pack(*self.inputs)
        self.assertEqual(len(image), 8388608)
        for offset, data in zip((0, 0x50000, 0x250000), self.inputs):
            self.assertEqual(image[offset:offset + len(data)], data)
            image[offset:offset + len(data)] = b"\xff" * len(data)
        self.assertEqual(image, b"\xff" * 8388608)

    def test_invalid_inputs(self):
        for index, capacity in enumerate((0x40000, 0x200000, 0x500000)):
            for invalid in (b"", b"x" * (capacity + 1), b"invalid header"):
                inputs = self.inputs.copy()
                inputs[index] = invalid
                with self.assertRaises(ValueError):
                    packer.pack(*inputs)
        inputs = self.inputs.copy()
        inputs[1] = inputs[1][:-1] + b"X"
        with self.assertRaisesRegex(ValueError, "CRC"):
            packer.pack(*inputs)

    def test_nor16_keeps_partition_offsets(self):
        small = packer.pack(*self.inputs)
        large = packer.pack(*self.inputs, flash_mib=16)
        self.assertEqual(len(large), 16777216)
        self.assertEqual(large[:len(small)], small)
        self.assertEqual(large[len(small):], b"\xff" * 8388608)
        with self.assertRaises(ValueError):
            packer.pack(*self.inputs, flash_mib=4)

    def test_existing_output_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            args = [sys.executable, str(SCRIPT)]
            for name, data in zip(("uboot", "kernel", "rootfs"), self.inputs):
                path = Path(directory, name)
                path.write_bytes(data)
                args.extend((f"--{name}", str(path)))
            target = Path(directory, "original-dump.bin")
            target.write_bytes(b"keep original")
            result = subprocess.run(args + ["--output", str(target)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_bytes(), b"keep original")


if __name__ == "__main__":
    unittest.main()
