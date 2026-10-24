#!/usr/bin/env python3
"""Validate the experimental T33gs kernel/module set before image assembly."""
import argparse
import hashlib
import json
import lzma
from pathlib import Path
import re
import struct
import zlib


def validate(root):
    release = (root / 'kernelrelease.txt').read_text().strip()
    if release != '4.4.94-lumi-t33gs':
        raise ValueError('Expected the T33gs 4.4.94 kernel release')
    image = (root / 'uImage').read_bytes()
    if len(image) < 64 or len(image) > 0x280000:
        raise ValueError('Kernel must fit the existing 2.5 MiB partition')
    magic, hcrc, _, size, _, _, dcrc, os_id, arch, kind, compression, _ = struct.unpack('>7I4B32s', image[:64])
    if magic != 0x27051956 or (os_id, arch, kind, compression) != (5, 5, 2, 3):
        raise ValueError('Expected Linux/MIPS/kernel/LZMA uImage')
    header = image[:4] + bytes(4) + image[8:64]
    if zlib.crc32(header) & 0xffffffff != hcrc:
        raise ValueError('uImage header CRC mismatch')
    if len(image) != 64 + size or zlib.crc32(image[64:]) & 0xffffffff != dcrc:
        raise ValueError('uImage payload size/CRC mismatch')
    config = set((root / 'kernel.config').read_text().splitlines())
    required = ('CONFIG_SOC_PRJ008=y', 'CONFIG_KERNEL_4_4_94=y',
                'CONFIG_CMA_SIZE_MBYTES=16', 'CONFIG_IPV6=y',
                'CONFIG_USB_DWC2_HOST=y', 'CONFIG_OVERLAY_FS=y', 'CONFIG_BLK_DEV_LOOP=y', 'CONFIG_CFG80211=y',
                '# CONFIG_INGENIC_MAC is not set', '# CONFIG_PM is not set')
    for setting in required:
        if setting not in config:
            raise ValueError('Missing required board setting: ' + setting)
    modules_root = root / 'modules-root/lib/modules'
    if sorted(p.name for p in modules_root.iterdir()) != [release]:
        raise ValueError('Mixed kernel module versions in staging root')
    modules = list((modules_root / release).rglob('*.ko'))
    required_modules = {'tx-isp-PRJ008.ko', 'sensor_sc4336_PRJ008.ko',
                        'audio.ko', 'lumi_motor.ko', 'tnpu.ko',
                        'aic_load_fw.ko', 'aic8800.ko'}
    if not required_modules <= {p.name for p in modules}:
        raise ValueError('Required T33gs modules missing from staging root')
    for path in modules:
        data = path.read_bytes()
        if data[:6] != b'\x7fELF\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 8:
            raise ValueError('Module must be ELF32 little-endian MIPS: ' + str(path))
        versions = re.findall(rb'\x00vermagic=([^\x00]+)', data)
        if len(versions) != 1 or versions[0].split()[0].decode() != release:
            raise ValueError('Module vermagic does not match kernel: ' + str(path))
    if not (modules_root / release / 'modules.dep').is_file():
        raise ValueError('Missing matching module dependency index')
    highatomic = None
    mode_file = root / 'highatomic-mode.txt'
    if mode_file.exists():
        mode = mode_file.read_text().strip()
        expected = {
            'diagnostics=0': '50ba86c154059c882b2504bedfdb6a579559846d6850330554f0cdd13e1adbcd',
            'diagnostics=1': 'b0931d3df02e39c5102cd219e50cb9600e29584a539b245a9b60993c16ebe785',
        }
        if mode not in expected:
            raise ValueError('Invalid highatomic diagnostic mode')
        source_hash = (root / 'highatomic-source.sha256').read_text().split()[0]
        if source_hash != expected[mode]:
            raise ValueError('Highatomic source hash does not match build mode')
        diagnostics = mode == 'diagnostics=1'
        if (b'lumi-highatomic: first reserve' in lzma.decompress(image[64:])) != diagnostics:
            raise ValueError('Kernel diagnostic code does not match declared build mode')
        highatomic = {'source_sha256': source_hash, 'diagnostics': diagnostics}
    files = [root / 'uImage', root / 'kernel.config', *modules]
    if highatomic is not None:
        files += [mode_file, root / 'highatomic-source.sha256']
    dma_source = root / 'dma-pool-source.sha256'
    if dma_source.exists():
        if dma_source.read_text().split()[0] != '4f04924af046fdb5ef5cd66ab2ecaea247524d940aa0e6524a8b22a48f890543':
            raise ValueError('DMA pool source hash must match the bounded preallocation patch')
        if b'failed to preallocate DMA descriptor page' not in lzma.decompress(image[64:]):
            raise ValueError('Kernel lacks declared DMA pool preallocation; rebuild the exact candidate')
        files.append(dma_source)
    result = {
        'kernelrelease': release, 'kernel_bytes': len(image),
        'kernel_headroom_bytes': 0x280000 - len(image), 'modules': len(modules),
        'files': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)},
        'board_qualified': False,
    }
    if highatomic is not None:
        result['highatomic'] = highatomic
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = validate(args.artifacts)
    except (ValueError, OSError, lzma.LZMAError) as exc:
        parser.exit(1, 'FAIL: ' + str(exc) + '\n')
    output = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(output)
    print('PASS: kernel CRC/size/config and all module ABIs; board qualification pending')


if __name__ == '__main__':
    main()
