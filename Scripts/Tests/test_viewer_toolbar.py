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

    def test_open_as_has_no_html_preview(self):
        choices = VIEWER.split('var choices: [FileFormat] = ', 1)[1].split('let openAs =', 1)[0]
        self.assertTrue(choices.startswith('[.text,'))
        self.assertNotIn('.html', choices)
        self.assertNotIn('case .html:', VIEWER)
        self.assertNotIn('setHTMLPolicy', VIEWER)
        self.assertNotIn('showStaticHTML', VIEWER)

    def test_html_extensions_use_source_editor(self):
        formats = (ROOT / 'Packages/FilaKit/Sources/FilaFormats/FileFormat.swift').read_text()
        self.assertIn('case "html", "htm", "xhtml": return .text', formats)
        self.assertIn('case .text:\n            TextViewerViewController', VIEWER)

    def test_html_preview_only_sources_are_removed(self):
        for name in ['DocumentPreviewPolicy.swift', 'HTMLReadableText.swift', 'HTMLReaderViewController.swift']:
            with self.subTest(name=name):
                self.assertFalse((ROOT / 'Fila/Interface/Viewer/Document' / name).exists())


if __name__ == '__main__':
    unittest.main()
