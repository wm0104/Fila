import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Scripts/verify-deb-metadata.py'
VERSION = '0.8.4-3'
DATE = '2026-11-19'
CHANGES = '统一文本替换准备逻辑；整理打包结果；清空废纸篓移到右上角'


def control(version=VERSION, date=DATE, entry=None):
    if entry is None:
        entry = f'{version} | {date} | {CHANGES}'
    return (f'Package: wiki.qaq.fila\nVersion: {version}\n'
            'Architecture: iphoneos-arm64e\nMaintainer: Test <test@example.invalid>\n'
            'Description: synthetic metadata fixture, not an installable Fila build\n'
            f'X-WM0104-Release-Date: {date}\nX-WM0104-Changelog: {entry}\n')


class MetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('deb_metadata', HELPER)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def check(self, text, version=VERSION):
        self.module.validate(text, version)

    def reject(self, text, version=VERSION):
        with self.assertRaises(ValueError):
            self.check(text, version)

    def test_valid_current_entry(self):
        self.check(control())

    def test_real_leap_day(self):
        self.check(control(date='2024-02-29'))

    def test_actual_expected_version(self):
        self.reject(control(), '0.8.4-4')

    def test_forgotten_changelog_version(self):
        self.reject(control(version='0.8.4-4', entry=f'{VERSION} | {DATE} | 旧日志'), '0.8.4-4')

    def test_missing_or_empty_required_fields(self):
        for field in ('Version', 'X-WM0104-Release-Date', 'X-WM0104-Changelog'):
            lines = control().splitlines(keepends=True)
            for replacement in ('', f'{field}:\n'):
                with self.subTest(field=field, replacement=replacement):
                    self.reject(''.join(replacement if line.startswith(field + ':') else line for line in lines))

    def test_strict_calendar_dates(self):
        for date in ('2026-02-29', '1900-02-29', '2026-11-31', '2026-00-10',
                     '0000-01-01', '2026-1-19', '２０２６-11-19', '20261119', '2026-11-19T00:00:00'):
            with self.subTest(date=date):
                self.reject(control(date=date))

    def test_mismatching_dates(self):
        self.reject(control(entry=f'{VERSION} | 2026-11-18 | 内容'))

    def test_invalid_log_date(self):
        self.reject(control(entry=f'{VERSION} | 2026-02-29 | 内容'))

    def test_duplicate_fields_case_insensitive(self):
        for field, value in (('Version', VERSION), ('X-WM0104-Release-Date', DATE),
                             ('X-WM0104-Changelog', f'{VERSION} | {DATE} | 内容')):
            for name in (field, field.lower()):
                with self.subTest(field=name):
                    self.reject(control() + f'{name}: {value}\n')

    def test_entry_delimiters_and_empty_changes(self):
        for entry in (f'{VERSION}|{DATE}|内容', f'{VERSION} | {DATE} | ',
                      f'{VERSION} | {DATE} |    ', f'{VERSION} | {DATE}',
                      f'{VERSION} | {DATE} | 内容 | 更多', f'{VERSION} | {DATE} | 内容|更多',
                      f'{VERSION}  | {DATE} | 内容', f'{VERSION} | {DATE} |  内容'):
            with self.subTest(entry=entry):
                self.reject(control(entry=entry))

    def test_semicolon_items_are_nonempty_and_trimmed(self):
        for changes in ('；；', '内容；；更多', '内容； ；', '；内容', '内容；',
                        '内容； 更多', '内容 ；更多', '内容；\u3000；更多'):
            with self.subTest(changes=changes):
                self.reject(control(entry=f'{VERSION} | {DATE} | {changes}'))

    def test_single_line_no_control_characters(self):
        for char in ('\x00', '\t', '\r', '\x7f', '\x85', '\u2028', '\u2029', '\u200b'):
            with self.subTest(char=repr(char)):
                self.reject(control(entry=f'{VERSION} | {DATE} | 文{char}本'))
        self.reject(control(entry=f'{VERSION} | {DATE} | 内容\n 续行'))

    def test_version_and_date_are_single_line(self):
        self.reject(control().replace(f'Version: {VERSION}', f'Version: {VERSION}\n continuation'))
        self.reject(control().replace(f'Release-Date: {DATE}', f'Release-Date: {DATE}\n continuation'))

    def test_unrelated_description_continuation_is_allowed(self):
        self.check(control().replace('Description: synthetic', 'Description: first line\n synthetic'))

    def test_old_control_is_not_exempt(self):
        self.reject('Package: wiki.qaq.fila\nVersion: 0.8.4-2\n', '0.8.4-2')

    def test_template_matches_current_version_and_source_fields(self):
        version = subprocess.check_output(['make', '--no-print-directory', 'print-version'], cwd=ROOT, text=True).strip()
        template = (ROOT / 'Packaging/DEBIAN/control').read_text()
        self.assertIn('Version: @VERSION@\n', template)
        self.check(template.replace('@VERSION@', version), version)
        for field in ('Description: 82大佬的fila文件管理器 在原来的基础上增加一些功能',
                      'Section: 乌龙', 'SileoDepiction: https://wm0104.github.io/repo/depictions/wiki.qaq.fila/depiction.json'):
            self.assertIn(field + '\n', template)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_real_deb_both_architectures_and_rejected_metadata(self):
        with tempfile.TemporaryDirectory(prefix='fila-metadata-test-') as directory:
            work = Path(directory)
            for arch, prefix in (('iphoneos-arm64e', ''), ('iphoneos-arm64', 'var/jb/')):
                staging = work / arch
                (staging / 'DEBIAN').mkdir(parents=True)
                payload = staging / prefix / 'Applications/Fila.app/fixture.txt'
                payload.parent.mkdir(parents=True)
                payload.write_text('Synthetic test payload; NOT a Fila binary.\n')
                path = staging / 'DEBIAN/control'
                package = work / (arch + '.deb')
                for name, text, expected, success in (
                    ('good', control(), VERSION, True),
                    ('wrong-expected', control(), '0.8.4-4', False),
                    ('old-log', control(version='0.8.4-4', entry=f'{VERSION} | {DATE} | 旧日志'), '0.8.4-4', False),
                    ('missing', control().replace(f'X-WM0104-Release-Date: {DATE}\n', ''), VERSION, False),
                    ('bad-date', control(date='2026-02-29'), VERSION, False),
                    ('empty-item', control(entry=f'{VERSION} | {DATE} | 内容；；更多'), VERSION, False),
                    ('duplicate', control() + f'x-wm0104-release-date: {DATE}\n', VERSION, False),
                ):
                    with self.subTest(arch=arch, case=name):
                        path.write_text(text.replace('iphoneos-arm64e', arch))
                        subprocess.run(['dpkg-deb', '--build', '--nocheck', str(staging), str(package)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        result = subprocess.run(['python3', str(HELPER), 'deb', str(package), expected], capture_output=True, text=True)
                        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                        before = subprocess.run(['python3', str(HELPER), 'control', str(path), expected], capture_output=True, text=True)
                        self.assertEqual(before.returncode == 0, success, before.stdout + before.stderr)
                        # Production verification must reject bad metadata before native
                        # tools, and must NOT accept metadata-only synthetic payloads.
                        if shutil.which('bash'):
                            full = subprocess.run(['bash', str(ROOT / 'Scripts/verify-deb.sh'), str(package),
                                                   'wiki.qaq.fila', expected, arch, '/var/jb' if prefix else ''],
                                                  capture_output=True, text=True)
                            self.assertNotEqual(full.returncode, 0, full.stdout + full.stderr)
                            self.assertIn('package is missing' if success else 'error: DEB metadata:', full.stderr)
                        if success:
                            fields = subprocess.check_output(['dpkg-deb', '-f', str(package)], text=True)
                            self.assertIn(f'Architecture: {arch}', fields)
                            self.assertIn(f'X-WM0104-Release-Date: {DATE}', fields)


if __name__ == '__main__':
    unittest.main()
