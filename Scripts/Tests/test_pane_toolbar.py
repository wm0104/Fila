"""UIKit ownership contracts for toggling the same tab in and out of dual pane."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PAGE = (ROOT / 'Packages/FilaKit/Sources/FilaBackendUI/TabContentViewController.swift').read_text()
NAV = (ROOT / 'Fila/Interface/Navigation/TabNavigationController.swift').read_text()
PANES = (ROOT / 'Fila/Interface/Tabs/BrowserPanesController.swift').read_text()
VIEWER = (ROOT / 'Fila/Interface/Viewer/Shared/ViewerRegistry.swift').read_text()


class PaneToolbarTests(unittest.TestCase):
    def test_toolbar_items_have_only_one_host_including_selection_mode(self):
        self.assertIn('usesPaneToolbar ? [] : (toolbarOverride ?? standardToolbarItems)', PAGE)
        self.assertIn('usesPaneToolbar ? (toolbarOverride ?? standardToolbarItems) : []', PAGE)
        self.assertIn('if usesPaneToolbar != oldValue { applyToolbar(animated: false) }', PAGE)
        self.assertIn('let items = page.paneToolbarItems', PANES)
        self.assertNotIn('let items = page.toolbarItems', PANES)

    def test_release_the_old_host_before_installing_items_in_the_other(self):
        single, split = PANES.split('if !split {', 1)[1].split('guard let second,', 1)
        self.assertLess(single.index('toolbar.setItems(nil,'), single.index('nav.usesSharedToolbar = false'))
        self.assertLess(split.index('nav.usesSharedToolbar = true'), split.index('syncToolbar()'))
        self.assertIn('for case let page as TabContentViewController in viewControllers', NAV)
        self.assertIn('page.usesPaneToolbar = usesSharedToolbar', NAV)
        self.assertIn('content.usesPaneToolbar = usesSharedToolbar', NAV)

    def test_open_as_html_is_available_once_immediately_after_text(self):
        choices = VIEWER.split('var choices: [FileFormat] = ', 1)[1].split('let openAs =', 1)[0]
        self.assertRegex(choices, r'^\[\.text\]\s+if FileFormat\.detect\(name: fileName\) == \.html \{ choices\.append\(\.html\) \}')
        self.assertEqual(choices.count('append(.html)'), 1)
        self.assertIn('case .html: "HTML"', VIEWER)


if __name__ == '__main__':
    unittest.main()
