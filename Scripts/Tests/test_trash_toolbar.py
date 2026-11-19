"""Source contracts for the trash toolbar; UIKit behavior needs iOS verification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
BROWSER = ROOT / 'Fila/Interface/Browser/FileBrowserViewController.swift'
ACTIONS = ROOT / 'Fila/Interface/Browser/FileBrowserViewController+FileActions.swift'


def member(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n    }', start) + 6]


class TrashToolbarTests(unittest.TestCase):
    def setUp(self):
        self.browser = BROWSER.read_text()
        self.actions = ACTIONS.read_text()

    def test_trash_has_one_button_inside_the_more_button(self):
        bar = member(self.browser, 'private var barItems:')
        self.assertRegex(bar, r'if isTrash\s*\{\s*return \[moreItem\(\), emptyTrashItem\(\)\]')
        self.assertEqual(bar.count('emptyTrashItem()'), 1)
        self.assertIn('!isTrash', bar)
        self.assertIn('[clipboardItem]', bar)

    def test_more_menu_no_longer_offers_empty_trash(self):
        menu = member(self.browser, 'func makeMoreMenu()')
        self.assertIn('folderAction: isTrash ? nil : newMenu()', menu)
        self.assertNotIn('emptyTrash', menu)
        self.assertIn('folderAction: UIMenuElement?', self.actions)
        self.assertIn('folderAction.map { [$0] } ?? []', self.actions)
        self.assertNotIn('func emptyTrashAction()', self.actions)

    def test_button_is_a_reused_symbol_item_with_an_accessible_name(self):
        button = member(self.browser, 'private lazy var emptyTrashButton')
        self.assertIn('UIBarButtonItem(', button)
        self.assertIn('image: UIImage(systemName: "trash")', button)
        self.assertIn('self?.emptyTrash()', button)
        self.assertIn('accessibilityLabel = String(localized: "Empty Trash")', button)
        self.assertNotIn('UIBarButtonItem(title:', button)
        self.assertNotIn('customView:', button)
        self.assertNotIn('UILabel', button)

    def test_button_state_uses_all_items_and_disables_during_loading(self):
        state = member(self.browser, 'private func emptyTrashItem()')
        self.assertIn('emptyTrashButton.isEnabled = !items.isEmpty && !isLoading', state)
        self.assertIn('emptyTrashButton.isEnabled ? .systemRed : .tertiaryLabel', state)
        self.assertIn('return emptyTrashButton', state)
        self.assertNotIn('visible', state)
        load = member(self.browser, 'override func load()')
        self.assertRegex(load, r'if isTrash\s*\{\s*_ = emptyTrashItem\(\)')

    def test_final_and_streaming_snapshots_refresh_the_trash_button(self):
        snapshot = member(self.browser, 'override func snapshotDidApply()')
        self.assertIn('if isEditing || isTrash {', snapshot)
        self.assertIn('updateChrome()', snapshot)

    def test_clear_reuses_permanent_delete_and_rechecks_current_state(self):
        clear = member(self.actions, 'func emptyTrash()')
        self.assertIn('guard isTrash, !items.isEmpty, !isLoading else { return }', clear)
        self.assertIn('delete(items.map(path(of:)), permanently: true)', clear)
        self.assertNotIn('visible', clear)
        self.assertNotIn('startDelete', clear)

    def test_selection_still_hides_top_actions(self):
        chrome = member(self.browser, 'func updateChrome(')
        self.assertIn('trailingNavigationItems = []', chrome)
        self.assertIn('trailingNavigationItems = barItems', chrome)
        self.assertIn('self.delete(selectedPaths())', self.browser)


if __name__ == '__main__':
    unittest.main()
