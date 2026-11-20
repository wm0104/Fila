#!/usr/bin/env python3
"""Validate this run's closed DEB artifact set, not the packages' contents.

The packager verifies signatures, metadata and payloads; this checks the transfer
boundary on every runner. Never follow a manifest path or silently collect extras.
"""

import hashlib
from pathlib import Path
import re
import sys

VERSION = r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?'
DEB = re.compile(rf'wiki\.qaq\.fila_({VERSION})_iphoneos-arm64(e?)\.deb', re.ASCII)


def validate(directory):
    directory = Path(directory)
    entries = list(directory.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in entries):
        raise ValueError('artifact directory must contain regular files only')
    names = {path.name for path in entries}
    versions = {match[1] for name in names if (match := DEB.fullmatch(name))}
    if len(versions) != 1:
        raise ValueError('expected exactly one DEB version')
    version = versions.pop()
    payloads = {
        f'wiki.qaq.fila_{version}_iphoneos-arm64e.deb',
        f'wiki.qaq.fila_{version}_iphoneos-arm64.deb',
        f'Fila_{version}_dSYMs.zip',
    }
    if names != payloads | {'SHA256SUMS'}:
        raise ValueError('expected exactly two DEBs, their dSYMs and SHA256SUMS; no IPA/TIPA or extras')

    hashes = {}
    for line in (directory / 'SHA256SUMS').read_text(encoding='ascii').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line, re.ASCII)
        if not match or match[2] not in payloads or match[2] in hashes:
            raise ValueError('unexpected, duplicate or malformed checksum entry')
        hashes[match[2]] = match[1]
    if set(hashes) != payloads:
        raise ValueError('checksum list must cover exactly the two DEBs and dSYMs')
    for name, expected in hashes.items():
        digest = hashlib.sha256()
        with (directory / name).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError(f'checksum mismatch: {name}')
    return version


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: verify-deb-artifacts.py <artifact-directory>')
        print(validate(sys.argv[1]))
    except (ValueError, OSError, UnicodeError) as error:
        sys.exit(f'error: DEB artifacts: {error}')
