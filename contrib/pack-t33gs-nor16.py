#!/usr/bin/env python3
"""Pack PRJ008N T33gs uImage and SquashFS into the 16 MiB SPI-NOR layout."""

import argparse
import hashlib
from pathlib import Path
import struct
import zlib

FLASH_SIZE = 16 * 1024 * 1024
UBOOT = (0x000000, 256 * 1024)
KERNEL = (0x040000, 2560 * 1024)
ROOTFS = (0x2C0000, 4096 * 1024)
ENV_OFFSET = 0xFF8000
ENV_BLOCK_SIZE = 32 * 1024
ENV_DATA_SIZE = 16 * 1024


def check_uimage(data: bytes) -> None:
	if len(data) < 64:
		raise ValueError("truncated uImage")
	magic, hcrc, _, size, _, _, dcrc = struct.unpack_from(">7I", data)
	if magic != 0x27051956 or size != len(data) - 64:
		raise ValueError("invalid uImage magic or payload size")
	header = data[:4] + bytes(4) + data[8:64]
	if zlib.crc32(header) != hcrc or zlib.crc32(data[64:]) != dcrc:
		raise ValueError("uImage CRC mismatch")
	if data[28] != 5 or data[29:32] != bytes((5, 2, 3)):
		raise ValueError("expected a MIPS Linux kernel uImage with LZMA compression")


def make_environment(memory_args: str) -> bytes:
	variables = {
		"baudrate": "115200",
		"bootcmd": "sf0 probe;sf0 read 0x80600000 0x40000 0x280000;bootm 0x80600000",
		"bootdelay": "1",
		"bootargs": (
			f"console=ttyS1,115200n8 {memory_args} init=/init "
			"rootfstype=squashfs root=/dev/mtdblock2 rw "
			"mtdparts=sfc0_nor:256k(boot),2560k(kernel),4096k(root),"
			"9440k(rootfs_data),32k(env)"
		),
		"stdin": "serial",
		"stdout": "serial",
		"stderr": "serial",
		"wlandev": "aic8800d80-t33",
	}
	data = b"\0".join(f"{key}={value}".encode() for key, value in variables.items()) + b"\0\0"
	payload = data.ljust(ENV_DATA_SIZE - 4, b"\0")
	return struct.pack("<I", zlib.crc32(payload) & 0xFFFFFFFF) + payload


def pack(uboot: bytes, kernel: bytes, rootfs: bytes, memory_args: str) -> bytes:
	for name, data, (_, capacity) in (
		("SPL+U-Boot", uboot, UBOOT),
		("kernel", kernel, KERNEL),
		("rootfs", rootfs, ROOTFS),
	):
		if not data or len(data) > capacity:
			raise ValueError(f"{name} is empty or exceeds its {capacity}-byte partition")
	check_uimage(kernel)
	if len(rootfs) < 96 or rootfs[:4] != b"hsqs":
		raise ValueError("rootfs is not little-endian SquashFS")
	used = struct.unpack_from("<Q", rootfs, 40)[0]
	if struct.unpack_from("<HH", rootfs, 28) != (4, 0) or not 96 <= used <= len(rootfs):
		raise ValueError("invalid SquashFS version or bytes_used")
	if len(make_environment(memory_args)) != ENV_DATA_SIZE:
		raise ValueError("invalid U-Boot environment size")

	image = bytearray(b"\xff" * FLASH_SIZE)
	image[UBOOT[0]:UBOOT[0] + len(uboot)] = uboot
	image[KERNEL[0]:KERNEL[0] + len(kernel)] = kernel
	image[ROOTFS[0]:ROOTFS[0] + len(rootfs)] = rootfs
	env = make_environment(memory_args)
	image[ENV_OFFSET:ENV_OFFSET + len(env)] = env
	return bytes(image)


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--uboot", type=Path, required=True)
	parser.add_argument("--kernel", type=Path, required=True)
	parser.add_argument("--rootfs", type=Path, required=True)
	parser.add_argument("--memory-args", default="mem=96M@0x0 rmem=32M@0x6000000")
	parser.add_argument("--output", type=Path, required=True)
	args = parser.parse_args()
	try:
		image = pack(args.uboot.read_bytes(), args.kernel.read_bytes(), args.rootfs.read_bytes(), args.memory_args)
		# Exclusive creation protects previous builds and camera dumps.
		with args.output.open("xb") as output:
			output.write(image)
		if args.output.stat().st_size != FLASH_SIZE or args.output.read_bytes() != image:
			raise ValueError("output read-back differs")
	except (OSError, ValueError) as error:
		parser.exit(1, f"error: {error}\n")
	print(f"{hashlib.sha256(image).hexdigest()}  {args.output.name}")


if __name__ == "__main__":
	main()
