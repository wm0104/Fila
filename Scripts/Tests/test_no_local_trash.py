"""UI source contracts complement LocalDeletionTests, not device UI verification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NoLocalTrashTests(unittest.TestCase):
    def test_browser_and_shortcuts_share_the_daemon_only_trash_gate(self):
        actions = (ROOT / 'Fila/Interface/FileActions/FileActions.swift').read_text()
        gate = actions.split('static var backendHasTrash: Bool {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('FileSession.shared.hello?.isPrivileged == true', gate)
        deletion = (ROOT / 'Fila/Interface/FileActions/FileActions+Delete.swift').read_text()
        self.assertIn('if Self.movesToTrash, !permanently', deletion)
        self.assertIn('PermanentDeleteConfirmation.present(', deletion)
        intents = (ROOT / 'Fila/Shortcuts/WriteIntents.swift').read_text()
        self.assertIn('let permanent = permanently || !FileActions.backendHasTrash', intents)
        self.assertIn('useTrash: !permanent', intents)

    def test_settings_do_not_offer_the_removed_feature_without_a_daemon(self):
        menu = (ROOT / 'Fila/Interface/Settings/GeneralSettingsMenu.swift').read_text()
        self.assertIn('let trash: [UIMenuElement] = FileActions.backendHasTrash ? [', menu)
        self.assertIn('] + trash + [', menu)
        page = (ROOT / 'Fila/Interface/Settings/GeneralSettingsViewController.swift').read_text()
        self.assertIn('case .fileOperations: FileActions.backendHasTrash ? 1 : 0', page)

    def test_private_trash_api_and_directory_creation_are_gone(self):
        roots = [ROOT / 'Packages/FilaKit/Sources/FilaClient', ROOT / 'Packages/FilaKit/Sources/FilaFileOps']
        for root in roots:
            for path in root.rglob('*.swift'):
                with self.subTest(path=str(path.relative_to(ROOT))):
                    source = path.read_text()
                    self.assertNotIn('privateTrashBase', source)
                    self.assertNotIn('wiki.qaq.fila/Trash', source)
        service = (roots[0] / 'LocalFileService.swift').read_text()
        self.assertIn('guard !job.useTrash, job.kind != .restore else {', service)
        self.assertIn('throw FilaFailure(errno: ENOTSUP', service)


if __name__ == '__main__':
    unittest.main()
