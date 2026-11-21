"""Source wiring contracts for the shared picker; not UIKit interaction tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PICKER = ROOT / 'Fila/Interface/FileActions/SaveDestinationViewController.swift'
PATH_BAR = ROOT / 'Packages/FilaKit/Sources/FilaBackendUI/PathBarView.swift'


class DestinationFavoritesTests(unittest.TestCase):
    def test_one_existing_path_bar_is_below_the_list_and_optional_form(self):
        source = PICKER.read_text()
        load = source.split('override func viewDidLoad()', 1)[1].split('override func viewWillAppear(', 1)[0]
        self.assertEqual(source.count('let pathBar = PathBarView()'), 1)
        self.assertIn('UIStackView(arrangedSubviews: [list])', load)
        self.assertNotIn('arrangedSubviews: [pathBar, list]', load)
        self.assertEqual(load.count('stack.addArrangedSubview(pathBar)'), 1)
        self.assertLess(load.index('stack.addArrangedSubview(form)'), load.index('stack.addArrangedSubview(pathBar)'))
        self.assertIn('make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)', load)
        self.assertIn('make.height.equalTo(FilaUI.minimumTapTarget)', load)
        self.assertNotIn('TabContentBar(', source)

    def test_current_path_opens_the_existing_anchored_favorites_panel(self):
        source = PICKER.read_text()
        self.assertIn('public var currentTap: (() -> Void)?', PATH_BAR.read_text())
        self.assertIn('pathBar.currentTap = { [weak self] in self?.presentFavoritesPanel() }', source)
        self.assertLess(source.index('pathBar.currentTap ='), source.index('pathBar.setCrumbs('))
        self.assertEqual(source.count('PathFavoritesPanelViewController('), 1)
        panel = source.split('private func presentFavoritesPanel()', 1)[1].split('private func refreshActions()', 1)[0]
        self.assertIn('bar.currentTargetFrame', panel)
        self.assertIn('frame.intersection(bar.bounds)', panel)
        self.assertIn('bar.currentContentFrame', panel)
        self.assertIn('directory: directory.path', panel)
        self.assertIn('goToPath: { [weak self] in self?.promptGoToPath() }', panel)
        self.assertIn('self?.showAncestor(URL(fileURLWithPath: path, isDirectory: true))', panel)
        self.assertIn('present(panel, animated: true)', panel)
        for forbidden in ['selection.confirm', 'commit()', 'dismiss(animated:', 'toggleFavorite(', 'UserDefaults']:
            self.assertNotIn(forbidden, panel)

    def test_original_confirmation_and_busy_guards_still_own_the_choice(self):
        source = PICKER.read_text()
        panel = source.split('private func presentFavoritesPanel()', 1)[1].split('private func refreshActions()', 1)[0]
        self.assertIn('availability != .creatingFolder', panel)
        self.assertIn('viewIfLoaded?.window != nil', panel)
        self.assertIn('navigationController?.topViewController === self', panel)
        self.assertIn('presentedViewController == nil', panel)
        actions = source.split('private func refreshActions()', 1)[1].split('private func load()', 1)[0]
        self.assertIn('confirmItem.isEnabled = availability == .ready && !(inTrash && !selection.picksFiles)', actions)
        self.assertIn('(selection.name.map(Self.isValidName) ?? true)', actions)
        self.assertIn('pathBar.isUserInteractionEnabled = availability != .creatingFolder', actions)
        self.assertIn('navigationController?.isModalInPresentation = availability == .creatingFolder', actions)
        commit = source.split('@objc private func commit()', 1)[1].split('extension SaveDestinationViewController', 1)[0]
        self.assertIn('guard selection.fileTypes == nil, confirmItem.isEnabled else { return }', commit)
        self.assertEqual(commit.count('selection.confirm(destination)'), 1)
        cancel = source.split('@objc private func cancel()', 1)[1].split('@objc private func commit()', 1)[0]
        self.assertIn('dismiss(animated: true)', cancel)
        self.assertNotIn('selection.confirm', cancel)

    def test_navigation_keeps_shared_selection_and_existing_file_modes(self):
        source = PICKER.read_text()
        navigation = source.split('private func showAncestor(', 1)[1].split('@objc private func nameChanged()', 1)[0]
        self.assertEqual(navigation.count('link: link, selection: selection'), 2)
        self.assertIn('navigation.popToViewController(existing, animated: true)', navigation)
        self.assertNotIn('selection.confirm', navigation)
        self.assertIn('types.contains((node.name as NSString).pathExtension.lowercased())', source)
        for entry in [
            'Fila/Interface/Navigation/RootSplitViewController+FileImport.swift',
            'Fila/Interface/Viewer/Archive/ArchiveBrowserViewController.swift',
            'Fila/Interface/FileActions/CompressViewController.swift',
            'Fila/Application/State/AppBackendShell.swift',
        ]:
            with self.subTest(entry=entry):
                self.assertIn('SaveDestinationViewController(', (ROOT / entry).read_text())


if __name__ == '__main__':
    unittest.main()
