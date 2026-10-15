#!/usr/bin/env python3
"""Validate the assembled rootfs, not the build cache; emit its exact manifest."""
import argparse
import hashlib
import gzip
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

REMOVED = ('usr/bin/ipctool', 'usr/bin/ipcinfo', 'usr/sbin/openipc-claim',
           'usr/sbin/wireguard', 'etc/init.d/S98wireguard', 'etc/wireguard.conf',
           'etc/network/interfaces.d/wg0', 'etc/init.d/S70vendor')
RETIRED = ('ipc-stream-worker', 'ipc-stream-motor', 'media-worker-p2p.t33',
           'lumi-t33gs-p2p', 'ipc-wakeword-worker', 'ipc-luvox-worker', 'voice-ram-supervisor')
REQUIRED = ('ipc-stream-core', 'ipc-stream-services',
            'ipc-stream-supervisor', 'ipc-stream-recorder',
            'lumi-config', 'lumi-snapshot-ffmpeg',
            'lumi-t33gs-relay-agent', 'utilization',
            'lumi-t33gs-motor-gpio-init')

def check(root):
    lumi = root / 'lumi'
    for name in RETIRED:
        if os.path.lexists(lumi / 'bin' / name):
            raise ValueError(f'retired compact-runtime service retained: {name}')
    profile = json.loads((lumi / 'camera-profile.json').read_text())
    if profile['version'] != 1 or profile['soc'] != 't33' or profile['flash'] != 'nor':
        raise ValueError('invalid T33/NOR profile')
    for key, enabled in profile['defaults']['modules'].items():
        if enabled and not profile['hardware'][key]:
            raise ValueError(f'unsupported default module: {key}')
    optional = ('ipc-voice-worker',) if (lumi / 'bin/ipc-voice-worker').exists() else ()
    for name in REQUIRED + optional:
        path = lumi / 'bin' / name
        if not path.is_file() or not path.stat().st_mode & 0o111:
            raise ValueError(f'missing executable: {name}')
        data = path.read_bytes()
        if name == 'ipc-stream-supervisor':
            if not data.startswith(b'#!/bin/sh\n') or b'\0' in data:
                raise ValueError('supervisor must be a POSIX shell script')
            subprocess.run(['/bin/sh', '-n', str(path)], check=True)
            continue
        if data.startswith(b'#!'):
            continue
        if data[:6] != b'\x7fELF\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 8:
            raise ValueError(f'wrong executable ABI: {name}')
        for i in range(struct.unpack_from('<H', data, 44)[0]):
            offset = struct.unpack_from('<I', data, 28)[0] + i * struct.unpack_from('<H', data, 42)[0]
            kind, start, _, _, size = struct.unpack_from('<IIIII', data, offset)
            if kind == 3 and name in ('ipc-stream-services', 'ipc-voice-worker', 'lumi-snapshot-ffmpeg'):
                raise ValueError(f'network/voice executable must be static: {name}')
            if kind == 3 and data[start:start+size].rstrip(b'\0') != b'/opt/ingenic-t33/lib/ld-uClibc-0.9.33.2.so':
                raise ValueError(f'wrong loader: {name}')
        attributes = subprocess.check_output(['readelf', '-A', str(path)], text=True)
        expected = 'Soft float' if name in ('lumi-snapshot-ffmpeg', 'ipc-stream-services', 'ipc-voice-worker') else 'Hard float'
        if 'FP ABI: ' + expected not in attributes:
            raise ValueError(f'wrong floating-point ABI: {name}')
    relay = gzip.decompress((lumi / 'bin/relay-agent.t33gs.gz').read_bytes())
    if relay[:6] != b'\x7fELF\x01\x01' or struct.unpack_from('<H', relay, 18)[0] != 8:
        raise ValueError('wrong relay ABI')
    with tempfile.NamedTemporaryFile() as executable:
        executable.write(relay); executable.flush()
        if 'FP ABI: Soft float' not in subprocess.check_output(['readelf', '-A', executable.name], text=True):
            raise ValueError('wrong relay floating-point ABI')
    for name in REMOVED:
        if os.path.lexists(root / name): raise ValueError(f'removed component retained: {name}')
    for path in root.rglob('relay-key.json'):
        raise ValueError(f'private identity embedded: {path}')
    for path in root.rglob('luvox.conf'):
        raise ValueError(f'private voice configuration embedded: {path}')
    if (root / 'usr/lib/lumi-ipc-streamer').exists(): raise ValueError('old runtime retained')
    if os.readlink(root / 'opt/ingenic-t33/lib') != '/lumi/lib': raise ValueError('SDK compatibility link invalid')
    for name in ('libimp.so', 'ld-uClibc-0.9.33.2.so'):
        if not (lumi / 'lib' / name).is_file(): raise ValueError(f'missing SDK library: {name}')
    for name in ('lumi_motor.ko', 'tnpu.ko'):
        data = (root / 'lib/modules/3.10.14/ingenic' / name).read_bytes()
        if b'vermagic=3.10.14__isvp_goat_1.0__' not in data:
            raise ValueError(f'kernel/module mismatch: {name}')
    # Root login must not retain the removed owner-claim shell.
    if 'openipc-claim' in (root / 'etc/passwd').read_text(): raise ValueError('root shell still uses claim')
    return profile

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--write-manifest', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    profile = check(root)
    files, links = {}, {}
    for path in sorted((root / 'lumi').rglob('*')):
        name = str(path.relative_to(root / 'lumi'))
        if path.is_symlink(): links[name] = os.readlink(path)
        elif path.is_file() and name != 'manifest.json':
            files[name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': oct(path.stat().st_mode & 0o777)}
    manifest = {'version': 1, 'model': profile['model'], 'files': files, 'symlinks': links}
    if args.write_manifest:
        repo = Path(__file__).resolve().parents[3]
        manifest['sources'] = {}
        for name in ('lumi-ipc-streamer', 'lumi-ipc-firmware', 'lumi-ipc-linux'):
            manifest['sources'][name] = subprocess.check_output(['git', '-C', str(repo / name), 'rev-parse', 'HEAD'], text=True).strip()
        (root / 'lumi/manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    else:
        actual = json.loads((root / 'lumi/manifest.json').read_text())
        if actual['files'] != files or actual['symlinks'] != links or actual['model'] != profile['model']:
            raise ValueError('assembled rootfs does not match manifest')
    print(f'Lumi rootfs verified: {len(files)} files, {len(links)} links, model={profile["model"]}')

if __name__ == '__main__':
    main()
