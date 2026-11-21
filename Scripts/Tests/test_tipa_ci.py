"""Single-TIPA CI layout contracts; fixtures here are not installable archives."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / 'Scripts/check-tipa-ci-packages.sh'
VERSION = '0.8.4-3'
TIPA = f'Fila_{VERSION}.tipa'
SYMBOLS = f'Fila_{VERSION}_dSYMs.zip'


class TipaLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fila-tipa-layout-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        for name in (TIPA, SYMBOLS):
            (self.directory / name).write_bytes(b'Layout fixture only, not an installable archive.\n')
        self.lines = [f'{hashlib.sha256((self.directory / name).read_bytes()).hexdigest()}  {name}\n'
                      for name in (TIPA, SYMBOLS)]
        self.manifest = self.directory / 'SHA256SUMS'
        self.manifest.write_text(''.join(self.lines))

    def check(self, success=False, version=VERSION):
        result = subprocess.run(['bash', str(CHECK), str(self.directory), version],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_exact_tipa_symbols_and_manifest(self):
        self.check(success=True)

    def test_no_extra_archives_hidden_files_or_directories(self):
        for name in ('other.ipa', 'other.tipa', 'other.deb', '.stale', 'unexpected-directory'):
            with self.subTest(name=name):
                extra = self.directory / name
                if name == 'unexpected-directory':
                    extra.mkdir()
                    self.check()
                    extra.rmdir()
                else:
                    extra.write_text('Not a package; negative layout fixture.\n')
                    self.check()
                    extra.unlink()
        self.check(success=True)

    def test_missing_outputs(self):
        for name in (TIPA, SYMBOLS, 'SHA256SUMS'):
            with self.subTest(name=name):
                path = self.directory / name
                data = path.read_bytes()
                path.unlink()
                self.check()
                path.write_bytes(data)

    def test_empty_outputs(self):
        for name in (TIPA, SYMBOLS, 'SHA256SUMS'):
            with self.subTest(name=name):
                path = self.directory / name
                data = path.read_bytes()
                path.write_bytes(b'')
                self.check()
                path.write_bytes(data)

    def test_linked_outputs(self):
        with tempfile.TemporaryDirectory(prefix='fila-tipa-linked-') as directory:
            target = Path(directory) / 'fixture'
            target.write_text('Not an archive.\n')
            for name in (TIPA, SYMBOLS, 'SHA256SUMS'):
                with self.subTest(name=name):
                    path = self.directory / name
                    data = path.read_bytes()
                    path.unlink()
                    path.symlink_to(target)
                    self.check()
                    path.unlink()
                    path.write_bytes(data)

    def test_invalid_or_stale_manifest(self):
        for text in (self.lines[0], self.lines[0] * 2, ''.join(self.lines) + self.lines[0],
                     ''.join(self.lines).replace(TIPA, 'old.tipa'),
                     ''.join(self.lines).replace('  ', ' ', 1),
                     'not-a-hash  ' + TIPA + '\n' + self.lines[1],
                     ''.join(self.lines) + '\n'):
            with self.subTest(text=text):
                self.manifest.write_text(text)
                self.check()

    def test_wrong_version_is_not_accepted(self):
        for version in ('0.8.4-4', '', '../bad', '0.8.4\n1'):
            with self.subTest(version=version):
                self.check(version=version)


class TipaWorkflowTests(unittest.TestCase):
    def test_ci_builds_only_the_full_composition_and_one_wrapper(self):
        source = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('branches: [ipa-dev]', source)
        self.assertEqual(source.count('run: make compile DERIVED_DATA='), 1)
        self.assertEqual(source.count('run: make _package-tipa DERIVED_DATA='), 1)
        for forbidden in ('compile-sandboxed', '_packages-sandboxed', '_packages-full',
                          '_package-deb', 'make packages', 'make ipa', '*.ipa', '*.deb'):
            self.assertNotIn(forbidden, source)
        self.assertIn('needs: [test, compile, floor-audit]', source)
        self.assertEqual(source.count('bash Scripts/check-tipa-ci-packages.sh'), 3)
        self.assertIn('run: sha256sum --check SHA256SUMS', source)
        self.assertIn('run: shasum -a 256 -c SHA256SUMS', source)
        self.assertIn('bash Scripts/audit-ios-floor.sh', source)
        self.assertEqual(source.count('${{ github.run_attempt }}-packages'), 3)

    def test_ci_uploads_one_shared_download_artifact(self):
        source = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertEqual(source.count('uses: actions/upload-artifact@'), 1,
                         'The same TIPA must not be uploaded as both build and packages artifacts.')
        self.assertNotIn('${{ github.run_attempt }}-build', source)
        artifact_names = [line.strip() for line in source.splitlines()
                          if line.strip().startswith('name: fila-tipa-')]
        self.assertEqual(len(artifact_names), 3, 'One upload and two validation downloads are required.')
        self.assertEqual(len(set(artifact_names)), 1, 'Every job must reuse the same artifact.')
        self.assertIn('retention-days: 30', source)

    def test_packaging_existing_products_does_not_build_other_wrappers(self):
        makefile = (ROOT / 'Makefile').read_text()
        recipe = makefile.split('\n_package-tipa:\n', 1)[1].split('\n\n', 1)[0]
        self.assertIn('"$(IPA_PACKAGER)" "$(APP_BUNDLE)" tipa "$(TIPA_OUTPUT)"', recipe)
        self.assertIn('"$(ENTITLEMENTS)"', recipe)
        self.assertNotIn('$(MAKE)', recipe)
        self.assertNotIn('deb', recipe)
        packager = (ROOT / 'Scripts/package-ipa.sh').read_text()
        self.assertIn('verify-ipa.sh', packager)


if __name__ == '__main__':
    unittest.main()
