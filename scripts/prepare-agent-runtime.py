#!/usr/bin/env python3
"""Fetch one pinned official Node runtime, verify it, and stage agent resources."""
import hashlib
import pathlib
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request

VERSION = '22.23.4'
CHECKSUMS = {
    'arm64': '037650d0839f457747396f052073fb48333d31bf5abd3c98b74da20d89ebb1ad',
    'x64': 'f42abca7aaac61efc57d49fb42ea84fc53bbeba9a749cb03a291ce6e4e7a69c1',
}

def stage(destination):
    root = pathlib.Path(__file__).resolve().parent.parent
    arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64'}.get(platform.machine())
    if platform.system() != 'Darwin' or arch not in CHECKSUMS:
        raise RuntimeError('Mac agent packaging requires a supported macOS build host.')
    archive_name = f'node-v{VERSION}-darwin-{arch}'
    cache = root / '.build' / 'agent-node'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'{archive_name}.tar.xz'
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        try:
            with urllib.request.urlopen(f'https://nodejs.org/dist/v{VERSION}/{archive.name}', timeout=60) as response, temporary.open('wb') as output:
                shutil.copyfileobj(response, output)
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    digest = hashlib.sha256()
    with archive.open('rb') as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != CHECKSUMS[arch]:
        raise RuntimeError('Bundled Node checksum mismatch. Remove the cached archive and rebuild.')
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(['npm', 'ci', '--no-audit', '--no-fund'], cwd=root / 'agent', check=True)
    subprocess.run(['npm', 'run', 'build'], cwd=root / 'agent', check=True)
    shutil.copytree(root / 'agent' / 'dist', destination, dirs_exist_ok=True)
    with tarfile.open(archive) as source:
        for member, output in [(f'{archive_name}/bin/node', 'node'), (f'{archive_name}/LICENSE', 'NODE-LICENSE.txt')]:
            contents = source.extractfile(member)
            if contents is None:
                raise RuntimeError(f'Missing runtime resource: {member}')
            with contents, (destination / output).open('wb') as target:
                shutil.copyfileobj(contents, target)
    (destination / 'node').chmod(0o755)
    subprocess.run(['codesign', '--force', '--sign', '-', str(destination / 'node')], check=True)

if __name__ == '__main__':
    stage(pathlib.Path(sys.argv[1]).resolve())
