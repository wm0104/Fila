"""Exercise payload kind/metadata checks; native signing stays in packaging integration tests."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_payload', ROOT / 'Scripts/verify-payload.py')
VERIFY = importlib.util.module_from_spec(spec)
spec.loader.exec_module(VERIFY)
ABSENT = object()


class SileoPackagingTests(unittest.TestCase):
    def check_payload(self, kind, marker=ABSENT, accepted=True):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Fila.app'
            action = app / 'PlugIns/FilaSaveAction.appex'
            action.mkdir(parents=True)
            info = {
                'CFBundleIdentifier': 'wiki.qaq.fila', 'CFBundleExecutable': 'Fila',
                'CFBundleShortVersionString': '0.8.4', 'FilaVersion': '0.8.4-4',
                'CFBundleVersion': VERIFY.setting('Version.xcconfig', 'CURRENT_PROJECT_VERSION'),
                'MinimumOSVersion': VERIFY.setting('Base.xcconfig', 'IPHONEOS_DEPLOYMENT_TARGET'),
                'CFBundleSupportedPlatforms': ['iPhoneOS'],
                'FilaAppGroupIdentifier': 'group.wiki.qaq.fila',
            }
            if marker is not ABSENT:
                info['FilaOffersSileoOpen'] = marker
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            extension = {key: info[key] for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'FilaVersion', 'FilaAppGroupIdentifier', 'MinimumOSVersion')}
            extension.update(CFBundleIdentifier='wiki.qaq.fila.saveaction', NSExtension={'NSExtensionPointIdentifier': 'com.apple.ui-services'})
            (action / 'Info.plist').write_bytes(plistlib.dumps(extension))
            argv = ['verify-payload.py', str(app), kind, '0.8.4-4']
            if kind == 'deb':
                argv += ['filad', 'fila-archive']
            # Only binary signature work is stubbed; the real main checks metadata.
            with patch.object(VERIFY, 'binary') as binary, patch.object(VERIFY.sys, 'argv', argv):
                if accepted:
                    VERIFY.main()
                    self.assertEqual(binary.call_count, 4 if kind == 'deb' else 2)
                else:
                    with self.assertRaisesRegex(ValueError, 'FilaOffersSileoOpen'):
                        VERIFY.main()
                    binary.assert_not_called()

    def test_only_tipa_with_true_marker_is_accepted(self):
        self.check_payload('tipa', True)
        for kind in ('deb', 'ipa'):
            self.check_payload(kind)

    def test_tipa_missing_or_wrong_type_marker_is_rejected_before_signatures(self):
        for marker in (ABSENT, False, 1, 'true'):
            with self.subTest(marker=marker):
                self.check_payload('tipa', marker, accepted=False)

    def test_marker_in_other_kinds_is_rejected_even_when_false(self):
        for kind in ('deb', 'ipa'):
            for marker in (True, False, 1, 'true'):
                with self.subTest(kind=kind, marker=marker):
                    self.check_payload(kind, marker, accepted=False)

    def test_native_tipa_regression_is_wired_into_full_packaging(self):
        makefile = (ROOT / 'Makefile').read_text()
        full = makefile.split('_packages-full:\n', 1)[1].split('_packages-sandboxed:', 1)[0]
        self.assertIn('Tests/test-packaging.py" --tipa-only "$(dir $(APP_BUNDLE))"', full)
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('make _packages-full DERIVED_DATA=', workflow)
        script = (ROOT / 'Tests/test-packaging.py').read_text()
        self.assertIn('if tipa_only:', script)
        self.assertIn('test_sileo_tipa(products, Path(workspace))', script)

    def test_packager_changes_only_the_staged_tipa_before_signing(self):
        source = (ROOT / 'Scripts/package-ipa.sh').read_text()
        marker = '/usr/libexec/PlistBuddy -c \'Add :FilaOffersSileoOpen bool true\' "$payload_app/Info.plist"'
        self.assertEqual(source.count(marker), 1)
        self.assertIn('if [[ "$kind" == tipa ]]; then\n    ' + marker, source)
        self.assertLess(source.index('/usr/bin/ditto "$app_bundle" "$payload_app"'), source.index(marker))
        self.assertLess(source.index(marker), source.index('ldid -S"$staging/app-entitlements.plist"'))
        for path in ('Packaging/Fila-Info.plist', 'Scripts/package-deb.sh'):
            self.assertNotIn('FilaOffersSileoOpen', (ROOT / path).read_text())


if __name__ == '__main__':
    unittest.main()
