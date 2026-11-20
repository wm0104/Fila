"""Sileo document handoff source contracts; actual LaunchServices needs iOS."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text()


def member(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }', start) + 6]


class SileoHandoffTests(unittest.TestCase):
    def setUp(self):
        self.menu = read('Fila/Interface/FileActions/FileActions.swift')
        self.install = read('Fila/Interface/FileActions/FileActions+Install.swift')
        self.send = member(self.install, 'private func openInSileo(')
        self.action = member(self.install, 'func sileoAction(')
        self.catalog = read('Packages/FilaKit/Sources/FilaApplications/ApplicationCatalog+TrollStore.swift')

    def test_flat_action_immediately_follows_existing_open_with(self):
        self.assertIn('let opening: [UIMenuElement] = shareSheet + sileo + run + install', self.menu)
        self.assertLess(self.menu.index('if Self.isInTrash(path)'), self.menu.index('let sileo ='))
        self.assertIn('title: String(localized: "Open With…")', self.menu)
        self.assertIn('confirm { self.share([path]) }', self.menu)
        self.assertIn('return UIAction(', self.action)
        self.assertIn('title: String(localized: "Open in Sileo")', self.action)
        self.assertNotIn('UIMenu(', self.action)
        self.assertNotIn('runsPrograms', self.action)

    def test_policy_is_explicit_boolean_and_only_regular_deb(self):
        policy = read('Fila/Services/Installation/SileoOpenPolicy.swift')
        self.assertIn('info["FilaOffersSileoOpen"]', policy)
        self.assertIn('CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue', policy)
        self.assertIn('kind == .regular', policy)
        self.assertIn('pathExtension.lowercased() == "deb"', policy)
        self.assertIn('Bundle.main.infoDictionary ?? [:]', self.action)
        self.assertNotIn('hello', policy)
        self.assertNotIn('isPrivileged', policy)

    def test_existing_install_and_share_routes_are_not_replaced(self):
        original = member(self.install, 'func installAction(')
        self.assertIn('guard SystemCapabilities.runsPrograms else { return nil }', original)
        self.assertIn('promptInstallPackage(path)', original)
        self.assertNotIn('Sileo', original)
        package = member(self.install, 'private func promptInstallPackage(')
        self.assertIn('manifest.package != Bundle.main.bundleIdentifier', package)
        self.assertIn('.installPackage(path: staged.path)', package)
        self.assertIn('user: .root', package)

    def test_sends_selected_copy_without_chooser_or_confirmation(self):
        self.assertIn('applications.locate(bundleIdentifier: "org.coolstar.SileoStore")', self.send)
        self.assertIn('let dataPath = location.dataPath', self.send)
        self.assertIn('session.stage(path)', self.send)
        self.assertIn('UUID().uuidString + ".deb"', self.send)
        self.assertIn('ApplicationDocumentInbox.prepare(dataPath: dataPath, access: $0)', self.send)
        self.assertIn('FileDelivery.deliver([.local(unique.path)], into: .local(inbox), mode: .copy', self.send)
        self.assertIn('applications.openInSileo(packageAt: delivered)', self.send)
        for forbidden in ['self.share(', 'confirmDestruction(', 'AlertViewController(', 'UIApplication.shared.open', 'sileo://', 'Toast.show', 'promptInstallPackage(']:
            self.assertNotIn(forbidden, self.send)
        self.assertIn('confirm { Task { await self.openInSileo(path) } }', self.action)

    def test_delivered_copy_survives_open_or_uncertain_result(self):
        result = self.send.split('switch await applications.openInSileo', 1)[1]
        opened = result.split('case .opened:', 1)[1].split('case .unavailable:', 1)[0]
        uncertain = result.split('case .failed, .unanswered:', 1)[1]
        self.assertNotIn('.remove(', opened)
        self.assertNotIn('.remove(', uncertain)
        self.assertIn('copy is kept at \\(delivered.path)', uncertain)
        self.assertEqual(self.send.count('$0.remove('), 1)
        self.assertIn('remove(delivered.path, directory: false, overrideGuard: false)', result)
        self.assertLess(self.send.index('Self.appInstallInFlight = true'), self.send.index('await applications.locate'))
        self.assertIn('defer { Self.appInstallInFlight = false }', self.send)

    def test_narrow_transport_keeps_original_lifetime(self):
        sileo = member(self.catalog, 'public static func openInSileo(')
        self.assertIn('url.isFileURL', sileo)
        self.assertIn('url.pathExtension.lowercased() == "deb"', sileo)
        self.assertIn('usingApplication: "org.coolstar.SileoStore"', sileo)
        self.assertIn('operationToOpenResource:usingApplication:uniqueDocumentIdentifier:userInfo:delegate:', self.catalog)
        self.assertIn('uniqueDocumentIdentifier: nil, userInfo: nil, delegate: handoff', self.catalog)
        self.assertIn('.now() + 30', self.catalog)
        self.assertIn('self.completion = nil', self.catalog)
        self.assertIn('DispatchQueue.global(qos: .userInitiated).async { operation.start() }', self.catalog)
        ts = member(self.catalog, 'public static func openInTrollStore(')
        self.assertIn('["ipa", "tipa"]', ts)
        self.assertIn('usingApplication: "com.opa334.TrollStore", name: "TrollStore"', ts)

    def test_new_strings_cover_existing_languages_and_keep_path_format(self):
        strings = json.loads(read('Fila/Resources/Localizable.xcstrings'))['strings']
        languages = set(strings['Operation Failed']['localizations'])
        keys = ['Open in Sileo', 'Sileo is unavailable or cannot receive this file.', 'Sileo did not confirm opening the file. The copy is kept at %@. Check Sileo before trying again.']
        for key in keys:
            entry = strings[key]
            self.assertEqual(set(entry['localizations']), languages)
            self.assertNotIn('extractionState', entry)
            for unit in entry['localizations'].values():
                self.assertEqual(unit['stringUnit']['value'].count('%@'), key.count('%@'))
        self.assertEqual(strings['Open in Sileo']['localizations']['zh-Hans']['stringUnit']['value'], '用Sileo打开')


if __name__ == '__main__':
    unittest.main()
