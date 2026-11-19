#!/usr/bin/env python3
"""Validate current Fila release metadata, from rendered control or a real deb."""
import datetime
import re
import subprocess
import unicodedata
import sys
from pathlib import Path


def validate(control, expected_version):
    required = ('version', 'x-wm0104-release-date', 'x-wm0104-changelog')
    fields = {}
    current = None
    # Split only on LF so embedded CR and Unicode line separators stay visible.
    for line in control.split('\n'):
        if not line:
            continue
        if line.startswith((' ', '\t')):
            if current is None or current in required:
                raise ValueError('release metadata must be single-line fields')
            continue
        name, separator, value = line.partition(':')
        if not separator or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*', name):
            raise ValueError('malformed control field')
        current = name.lower()
        if current in fields:
            raise ValueError(f'duplicate control field: {name}')
        fields[current] = value.removeprefix(' ')
    for name in required:
        value = fields.get(name, '')
        if not value or value != value.strip() or any(
            unicodedata.category(char) in ('Cc', 'Cf', 'Cs', 'Zl', 'Zp') for char in value
        ):
            raise ValueError(f'{name} must be nonempty, single-line and free of control characters')
    if fields['version'] != expected_version:
        raise ValueError('Version does not match expected package version')
    release_date = fields['x-wm0104-release-date']
    if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', release_date):
        raise ValueError('X-WM0104-Release-Date must be ISO YYYY-MM-DD')
    datetime.date.fromisoformat(release_date)
    entry = fields['x-wm0104-changelog'].split(' | ')
    if (len(entry) != 3 or any(not part or part != part.strip() or '|' in part for part in entry)
            or entry[0] != expected_version or entry[1] != release_date):
        raise ValueError('X-WM0104-Changelog must be <Version> | <Release-Date> | <nonempty changes>')
    if any(not item or item != item.strip() for item in entry[2].split('；')):
        raise ValueError('X-WM0104-Changelog items must be nonempty and trimmed, separated by ；')


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('control', 'deb'):
        sys.exit('usage: verify-deb-metadata.py <control|deb> <path> <expected-version>')
    kind, path, version = sys.argv[1:]
    try:
        # Request the raw control member, not dpkg's normalized field values.
        raw = (subprocess.check_output(['dpkg-deb', '--info', path, 'control'])
               if kind == 'deb' else Path(path).read_bytes())
        validate(raw.decode('utf-8'), version)
    except (OSError, UnicodeError, ValueError, subprocess.CalledProcessError) as error:
        print(f'error: DEB metadata: {error}', file=sys.stderr)
        return 65
    print(f'Verified DEB release metadata ({version}): {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
