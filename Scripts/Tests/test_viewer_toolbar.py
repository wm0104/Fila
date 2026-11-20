"""Viewer menu and single-navigation ownership contracts; UIKit needs iOS verification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
VIEWER = (ROOT / 'Fila/Interface/Viewer/Shared/ViewerRegistry.swift').read_text()


class ViewerToolbarTests(unittest.TestCase):
    def test_tabs_own_one_navigation_and_guard_its_removal(self):
        container = (ROOT / 'Fila/Interface/Tabs/TabContainerViewController.swift').read_text()
        self.assertIn('tabs[id] = Content(navigation: navigation)', container)
        self.assertIn(r'tabs.values.map(\.navigation)', container)
        close = container.split('func confirmClosingTab(', 1)[1].split('private func showConnecting()', 1)[0]
        self.assertLess(close.index('!navigation.refusesRemoving(navigation.viewControllers)'), close.index('viewer?.confirmReplacement'))

    def test_open_as_html_is_available_once_immediately_after_text(self):
        choices = VIEWER.split('var choices: [FileFormat] = ', 1)[1].split('let openAs =', 1)[0]
        self.assertRegex(choices, r'^\[\.text\]\s+if FileFormat\.detect\(name: fileName\) == \.html \{ choices\.append\(\.html\) \}')
        self.assertEqual(choices.count('append(.html)'), 1)
        self.assertIn('case .html: "HTML"', VIEWER)


if __name__ == '__main__':
    unittest.main()
