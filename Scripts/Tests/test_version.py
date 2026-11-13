from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def parse_settings(text):
    return dict(re.findall(r'^([A-Za-z_]\w*)[ \t]*=[ \t]*([^\r\n]*)', text, re.M))


class VersionTests(unittest.TestCase):
    def test_display_version_and_bundle_version_are_separate(self):
        config = (ROOT / 'Configuration/Version.xcconfig').read_text()
        settings = parse_settings(config)
        self.assertRegex(settings['MARKETING_VERSION'], r'^\d+\.\d+\.\d+$')
        full = settings['MARKETING_VERSION'] + settings['FILA_VERSION_SUFFIX'].strip()
        self.assertRegex(full, r'^\d+\.\d+\.\d+(-\d+)?$')
        self.assertRegex(settings['CURRENT_PROJECT_VERSION'], r'^\d+$')
        for name in ['Fila-Info.plist', 'FilaSaveAction-Info.plist']:
            text = (ROOT / 'Packaging' / name).read_text()
            for key, value in settings.items():
                text = text.replace('$(' + key + ')', value.strip())
            self.assertEqual(plistlib.loads(text.encode())['FilaVersion'], full)

    def test_empty_suffix_does_not_consume_the_next_setting(self):
        settings = parse_settings('MARKETING_VERSION = 1.2.3\nFILA_VERSION_SUFFIX = \nCURRENT_PROJECT_VERSION = 268\n')
        self.assertEqual(settings['FILA_VERSION_SUFFIX'], '')
        self.assertEqual(settings['CURRENT_PROJECT_VERSION'], '268')

    @unittest.skipUnless(shutil.which('bash') and Path('/usr/bin/ditto').exists(), 'Version setter publication requires macOS ditto')
    def test_real_setter_handles_revision_and_reset_without_bumping_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            (root / 'Configuration').mkdir()
            script = root / 'Scripts/apply-version.sh'
            shutil.copy2(ROOT / 'Scripts/apply-version.sh', script)
            config = root / 'Configuration/Version.xcconfig'
            config.write_text('MARKETING_VERSION = 0.8.4\nCURRENT_PROJECT_VERSION = 268\n')
            for version, base, suffix in [('0.8.4-1', '0.8.4', '-1'), ('1.2.3', '1.2.3', ''), ('1.2.3-2', '1.2.3', '-2')]:
                subprocess.run(['bash', str(script), version], check=True, capture_output=True, timeout=10)
                text = config.read_text()
                self.assertEqual(parse_settings(text)['FILA_VERSION_SUFFIX'], suffix)
                self.assertIn('MARKETING_VERSION = ' + base + '\n', text)
                self.assertIn('FILA_VERSION_SUFFIX = ' + suffix + '\n', text)
                self.assertIn('CURRENT_PROJECT_VERSION = 268\n', text)
            before = config.read_bytes()
            for invalid in ['0.8.4.1', '0.8.4-', '0.8.4-1-2', 'x', '0.8.4\nVersion: 2']:
                result = subprocess.run(['bash', str(script), invalid], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(config.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
