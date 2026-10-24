#!/usr/bin/env python3
"""Assemble a RAM-trial candidate from an explicitly checksum-pinned userspace baseline."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

EPOCH = 1770163200


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, env=None):
    subprocess.run([str(a) for a in args], check=True, env=env)


def cpio(tree, target):
    """Write deterministic root-owned newc without host root/mknod privileges."""
    with target.open('wb') as out:
        def entry(name, mode, data, inode, major=0, minor=0):
            name = name.encode() + b'\0'
            fields = (inode, mode, 0, 0, 1, EPOCH, len(data), 0, 0, major, minor, len(name), 0)
            header = b'070701' + b''.join(('%08x' % x).encode() for x in fields)
            out.write(header + name)
            out.write(bytes(-(len(header) + len(name)) % 4))
            out.write(data)
            out.write(bytes(-len(data) % 4))
        paths = sorted(tree.rglob('*'))
        for index, path in enumerate(paths, 1):
            mode = path.lstat().st_mode
            if path.is_symlink():
                data = str(path.readlink()).encode()
            elif path.is_file():
                data = path.read_bytes()
            elif path.is_dir():
                data = b''
            else:
                raise ValueError('Unexpected file in RAM archive: ' + str(path))
            entry(str(path.relative_to(tree)), mode, data, index)
        entry('dev/console', stat.S_IFCHR | 0o600, b'', len(paths) + 1, 5, 1)
        entry('dev/null', stat.S_IFCHR | 0o666, b'', len(paths) + 2, 1, 3)
        entry('TRAILER!!!', 0, b'', len(paths) + 3)
        out.write(bytes(-out.tell() % 512))


def main():
    os.environ['SOURCE_DATE_EPOCH'] = str(EPOCH)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--baseline-sha256', required=True, help='Previously verified and approved rootfs SHA256')
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--host-tools', type=Path)
    parser.add_argument('--runtime-file', nargs=3, action='append', default=[],
                        metavar=('NAME', 'PATH', 'SHA256'),
                        help='Explicitly pinned core/gateway replacement for a separately qualified derivative')
    args = parser.parse_args()
    fw = Path(__file__).resolve().parent.parent
    tools = (args.host_tools or fw / 'output/lumi-t33gs/host/bin').resolve()
    spec = importlib.util.spec_from_file_location('verify', fw / 'contrib/verify-t33gs-k4494.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    build = args.build.resolve()
    result = verifier.validate(build / 'artifacts')
    baseline = args.baseline.resolve()
    baseline_sha = args.baseline_sha256
    if len(baseline_sha) != 64 or any(c not in '0123456789abcdef' for c in baseline_sha):
        raise ValueError('Baseline SHA256 must be 64 lowercase hexadecimal characters')
    if sha(baseline / 'rootfs.squashfs') != baseline_sha:
        raise ValueError('Baseline rootfs differs from the explicitly approved checksum')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / '.assembly-in-progress').write_text('Candidate assembly incomplete; do not use for deployment.\n')
    (output / 'verification.json').unlink(missing_ok=True)
    (output / 'SHA256SUMS').unlink(missing_ok=True)
    work = Path(tempfile.mkdtemp(prefix='assembly-', dir=output))
    stage = work / 'rootfs'
    run(tools / 'unsquashfs', '-no-progress', '-no-xattrs', '-d', stage, baseline / 'rootfs.squashfs')
    shutil.rmtree(stage / 'lib/modules')
    shutil.copytree(build / 'artifacts/modules-root/lib/modules', stage / 'lib/modules', symlinks=True)
    for name in ('S35board', 'S60lumi-streamer'):
        path = stage / 'etc/init.d' / name
        text = path.read_text()
        target_path = '/lib/modules/' + result['kernelrelease'] + '/ingenic'
        if '/lib/modules/$(uname -r)/ingenic' in text or target_path in text:
            continue
        paths = set(re.findall(r'/lib/modules/[^/\s]+/ingenic', text))
        if len(paths) != 1:
            raise ValueError('Unexpected baseline module path in ' + name)
        path.write_text(text.replace(paths.pop(), target_path))
    # Runtime binaries, SDK userspace and public API remain the approved baseline.
    manifest = json.loads((stage / 'lumi/manifest.json').read_text())
    for name, item in manifest['files'].items():
        if sha(stage / 'lumi' / name) != item['sha256']:
            raise ValueError('Baseline runtime changed unexpectedly: ' + name)
    overrides = {}
    for name, source, expected in args.runtime_file:
        if name not in ('bin/ipc-stream-core', 'bin/ipc-stream-services') or name in overrides:
            raise ValueError('Unsupported or duplicate runtime replacement: ' + name)
        source = Path(source).resolve()
        if sha(source) != expected:
            raise ValueError('Runtime replacement checksum mismatch: ' + name)
        overrides[name] = {'baseline_sha256': manifest['files'][name]['sha256'], 'sha256': expected}
        shutil.copyfile(source, stage / 'lumi' / name)
        (stage / 'lumi' / name).chmod(int(manifest['files'][name]['mode'], 8))
        manifest['files'][name]['sha256'] = expected
    if overrides:
        manifest['runtime_overrides'] = overrides
        (stage / 'lumi/manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    rootfs = work / 'rootfs.squashfs'
    run(tools / 'mksquashfs', stage, rootfs, '-noappend', '-all-root', '-no-xattrs',
        '-comp', 'xz', '-b', '262144', '-processors', '4', '-all-time', str(EPOCH), '-mkfs-time', str(EPOCH),
        env={k: v for k, v in os.environ.items() if k != 'SOURCE_DATE_EPOCH'})
    if rootfs.stat().st_size > 0xc00000:
        raise ValueError('Rootfs exceeds existing 12MiB partition; candidate not published')
    ram = work / 'ram'
    for name in ('bin', 'lib', 'dev', 'proc', 'sys', 'rw', 'lower', 'newroot', 'candidate'):
        (ram / name).mkdir(parents=True)
    shutil.copy2(stage / 'bin/busybox', ram / 'bin/busybox')
    for name in ('sh', 'mount', 'mkdir', 'chroot', 'cat', 'chmod', 'grep', 'dd', 'sha256sum', 'cp', 'rm'):
        (ram / 'bin' / name).symlink_to('busybox')
    # BusyBox's exact interpreter/libc pair from the same baseline.
    shutil.copy2(stage / 'lib/libc.so', ram / 'lib/libc.so')
    (ram / 'lib/ld-musl-mipsel.so.1').symlink_to('libc.so')
    shutil.copytree(build / 'artifacts/modules-root/lib', ram / 'candidate/lib', symlinks=True)
    (ram / 'candidate/etc/init.d').mkdir(parents=True)
    for name in ('S35board', 'S60lumi-streamer'):
        shutil.copy2(stage / 'etc/init.d' / name, ram / 'candidate/etc/init.d' / name)
    baseline_bytes = (baseline / 'rootfs.squashfs').stat().st_size
    if baseline_bytes % 4096:
        raise ValueError('Baseline rootfs must be block aligned for the RAM preflight')
    (ram / 'candidate/rootfs.env').write_text('ROOTFS_BLOCKS=' + str(baseline_bytes // 4096)
        + '\nROOTFS_SHA256=' + baseline_sha + '\n')
    shutil.copy2(fw / 'contrib/t33gs-k4494-ram-init', ram / 'init')
    (ram / 'init').chmod(0o755)
    archive = work / 'trial.cpio'
    cpio(ram, archive)
    compressed = work / 'trial.cpio.gz'
    with archive.open('rb') as src, compressed.open('wb') as dst:
        with gzip.GzipFile(filename='', mode='wb', fileobj=dst, mtime=0) as zipped:
            shutil.copyfileobj(src, zipped)
    ramdisk = work / 'ramdisk.uImage'
    run(tools / 'mkimage', '-A', 'mips', '-O', 'linux', '-T', 'ramdisk', '-C', 'gzip',
        '-a', '0', '-e', '0', '-n', 'T33gs 4.4 RAM trial', '-d', compressed, ramdisk)
    sources = {str(p): sha(p) for p in [Path(__file__).resolve(), fw / 'contrib/t33gs-k4494-ram-init',
               fw / 'contrib/build-t33gs-k4494.sh', fw / 'contrib/verify-t33gs-k4494.py']}
    board = fw.parent / 'lumi-ipc-linux/kernel/ingenic/t33gs-4.4.94'
    sources.update({str(p): sha(p) for p in board.iterdir() if p.is_file()})
    sources[str(fw.parent / 'lumi-ipc-linux/kernel/ingenic/t33gs-motor/lumi_motor.c')] = sha(fw.parent / 'lumi-ipc-linux/kernel/ingenic/t33gs-motor/lumi_motor.c')
    for src, name in [(build / 'artifacts/uImage', 'uImage'), (rootfs, 'rootfs.squashfs'),
                      (ramdisk, 'ramdisk.uImage'), (build / 'artifacts/kernel.config', 'kernel.config')]:
        shutil.copy2(src, output / name)
    for name in ('manifest.json', 'camera-profile.json'):
        shutil.copy2(stage / 'lumi' / name, output / name)
    result.update({'baseline_rootfs_sha256': baseline_sha, 'runtime_overrides': overrides,
                   'rootfs_bytes': rootfs.stat().st_size,
                   'rootfs_headroom_bytes': 0xc00000 - rootfs.stat().st_size,
                   'sources': sources, 'sdk_inputs': json.loads((build / 'sdk-inputs.json').read_text()),
                   'aic_source': (build / 'artifacts/aic-source.sha256').read_text().strip(),
                   'images': {name: sha(output / name) for name in ('uImage', 'rootfs.squashfs', 'ramdisk.uImage')},
                   'status': 'RAM_TRIAL_ONLY_NOT_OTA_QUALIFIED'})
    (output / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(sha(output / name) + '  ' + name + '\n' for name in ('uImage', 'rootfs.squashfs', 'ramdisk.uImage', 'kernel.config', 'manifest.json', 'camera-profile.json', 'verification.json')))
    (output / '.assembly-in-progress').unlink()
    print('Candidate assembled; UART recovery and all board qualification gates remain pending.')


if __name__ == '__main__':
    main()
