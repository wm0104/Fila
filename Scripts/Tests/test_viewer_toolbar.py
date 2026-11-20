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

    def test_open_as_keeps_text_and_adds_html(self):
        choices = VIEWER.split('var choices: [FileFormat] = ', 1)[1].split('let openAs =', 1)[0]
        self.assertTrue(choices.startswith('[.text,'))
        self.assertIn('choices.append(.html)', choices)
        self.assertIn('case .html:', VIEWER)
        self.assertIn('HTMLPreviewViewController(source: htmlSource)', VIEWER)
        self.assertNotIn('setHTMLPolicy', VIEWER)
        self.assertNotIn('showStaticHTML', VIEWER)

    def test_html_and_xhtml_have_distinct_entry_points(self):
        formats = (ROOT / 'Packages/FilaKit/Sources/FilaFormats/FileFormat.swift').read_text()
        self.assertIn('case "html", "htm": return .html', formats)
        self.assertIn('case "xhtml": return .text', formats)
        self.assertIn('case .text:\n            return TextViewerViewController', VIEWER)

    def test_html_policy_does_not_change_office_converter(self):
        html = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewViewController.swift').read_text()
        office = (ROOT / 'Fila/Interface/Viewer/Document/DocumentViewerViewController.swift').read_text()
        self.assertIn('allowsContentJavaScript = permissions.javaScript', html)
        self.assertIn('allowsContentJavaScript = true', office)
        self.assertIn('DocumentContentRules.load', office)
        self.assertIn('StatusView(content:', html)
        self.assertIn('container.childMenuElements', html)
        self.assertIn('openHTMLAsText(from: self)', html)
        self.assertNotIn('showStaticHTML', html)
        self.assertNotIn('HTMLReadableText', html)

    def test_html_transport_preserves_declared_encodings(self):
        resources = (ROOT / 'Fila/Interface/Viewer/Document/HTMLSchemeHandler.swift').read_text()
        self.assertIn('"Content-Type": mime,', resources)
        self.assertNotIn('charset=utf-8', resources)
        fixture = ROOT / 'Tests/Viewer/HTMLPreview'
        for name in ['encoding-gbk.html', 'assets/encoding-gbk.css']:
            with self.subTest(name=name):
                data = (fixture / name).read_bytes()
                self.assertIn(b'gbk', data)
                self.assertIn('中文', data.decode('gbk'))
                with self.assertRaises(UnicodeDecodeError):
                    data.decode('utf-8')

    def test_html_capability_is_not_an_absolute_path_reopen(self):
        resources = (ROOT / 'Fila/Interface/Viewer/Document/HTMLSchemeHandler.swift').read_text()
        directory = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewDirectory.swift').read_text()
        controller = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewViewController.swift').read_text()
        operations = (ROOT / 'Packages/FilaKit/Sources/FilaFileOps/FileOperations/FileOperations+Preview.swift').read_text()
        self.assertIn('link.openPreviewDirectory(path)', directory)
        self.assertIn('link.openPreviewResource(root: descriptor, relativePath: relativePath)', directory)
        capture = operations.split('func openPreviewDirectory(', 1)[1].split('func openPreviewResource(', 1)[0]
        self.assertIn('filaOpenDirectory(canonicalPath)', capture)
        self.assertNotIn('FilaPath.canonical', capture)
        self.assertNotIn('FilaPath.resolve', capture)
        self.assertNotIn('realpath(', capture)
        self.assertIn('handler?.invalidate()', controller)
        self.assertNotIn('HTMLPreviewDirectory(path:', controller)
        self.assertNotIn('loadFileURL', resources)
        self.assertNotIn('loadHTMLString', resources)

    def test_html_sniff_and_main_response_share_an_opened_document(self):
        resources = (ROOT / 'Fila/Interface/Viewer/Document/HTMLSchemeHandler.swift').read_text()
        prepare = VIEWER.split('fileprivate func prepare()', 1)[1].split('private static func describe', 1)[0]
        self.assertLess(prepare.index('HTMLPreviewSource.capture('), prepare.index('file.read(at: 0,'))
        self.assertIn('file = captured.document.file', prepare)
        self.assertIn('document.file.duplicate()', resources)
        self.assertIn('if path == document.relativePath', resources)

    def test_html_rtc_configuration_fails_closed_before_webview_creation(self):
        controller = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewViewController.swift').read_text()
        rtc = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewRTCPolicy.swift').read_text()
        install = controller.split('private func installRenderer(', 1)[1].split('private func armDeadline(', 1)[0]
        self.assertLess(install.index('HTMLPreviewRTCPolicy.makePreferences()'), install.index('WKWebView(frame:'))
        self.assertIn('catch { fail("rtc-preferences"); return }', install)
        self.assertIn('$0.preferences = preferences', install)
        self.assertIn('let preferences = WKPreferences()', rtc)
        self.assertIn('method_getNumberOfArguments(setterMethod) == 3', rtc)
        self.assertIn('method_getNumberOfArguments(getterMethod) == 2', rtc)
        for guard in [
            'returnType(setterMethod) == "v"',
            'argumentType(setterMethod, 0) == "@"',
            'argumentType(setterMethod, 1) == ":"',
            'argumentType(getterMethod, 0) == "@"',
            'argumentType(getterMethod, 1) == ":"',
        ]:
            self.assertIn(guard, rtc)
        self.assertIn('returnType(getterMethod) == encoding', rtc)
        self.assertIn('set(preferences, setter, false)', rtc)
        self.assertIn('guard !get(preferences, getter)', rtc)
        self.assertIn('set(preferences, setter, 0)', rtc)
        self.assertIn('guard get(preferences, getter) == 0', rtc)
        self.assertNotIn('https', rtc)
        self.assertNotIn('perform(', rtc.split('switch encoding', 1)[0])
        self.assertNotIn('delete window', controller)

    def test_html_rejects_new_windows_without_a_default_configuration(self):
        controller = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewViewController.swift').read_text()
        self.assertIn('$0.uiDelegate = self', controller)
        policy = controller.split('decidePolicyFor action:', 1)[1].split('decidePolicyFor response:', 1)[0]
        self.assertLess(policy.index('guard action.targetFrame != nil'), policy.index('if policy.isHTML(url)'))
        self.assertIn('decisionHandler(.cancel)', policy)
        create = controller.split('createWebViewWith configuration:', 1)[1].split('func webView(', 1)[0]
        self.assertIn('-> WKWebView? {', create)
        self.assertIn('return nil', create)
        self.assertNotIn('WKWebView(', create)

    def test_external_https_uses_a_fila_confirmation_then_system_safari(self):
        # Source wiring only; card actions, lifecycle and Safari need iOS testing.
        controller = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewViewController.swift').read_text()
        self.assertIn('import AlertController', controller)
        self.assertIn('import SafariServices', controller)
        self.assertNotIn('UIApplication.shared.open', controller)
        self.assertNotIn('universalLinksOnly:', controller)
        self.assertNotIn('External browser opening is unavailable in this preview.', controller)
        policy = controller.split('decidePolicyFor action:', 1)[1].split('decidePolicyFor response:', 1)[0]
        self.assertIn('action.navigationType == .linkActivated', policy)
        self.assertIn('HTMLPreviewPolicy.externalURL(url)', policy)
        self.assertIn('confirmExternalLink(url)', policy)
        confirm = controller.split('private func confirmExternalLink(', 1)[1].split('func webView(', 1)[0]
        self.assertIn('let destination = HTMLPreviewPolicy.externalURL(url)', confirm)
        self.assertIn('AlertViewController(', confirm)
        self.assertIn('String.LocalizationValue("Cancel")', confirm)
        self.assertIn('String.LocalizationValue("Open")', confirm)
        self.assertLess(confirm.index('context.dispose { [weak self] in'), confirm.index('SFSafariViewController(url: destination)'))
        self.assertIn('generation == ticket', confirm)
        self.assertIn('viewIfLoaded?.window != nil', confirm)
        self.assertIn('presentedViewController == nil', confirm)
        self.assertIn('present(browser, animated: true)', confirm)
        for local_capability in ['permissions.', 'directory', 'setURLSchemeHandler', 'WKPreferences', 'loadFileURL']:
            self.assertNotIn(local_capability, confirm)

    def test_internal_html_navigation_updates_file_actions_without_recapturing_root(self):
        controller = (ROOT / 'Fila/Interface/Viewer/Document/HTMLPreviewViewController.swift').read_text()
        self.assertIn('htmlPreviewWillOpen(relativePath, from: self)', controller)
        self.assertIn('htmlPreviewOpened(document, from: self)', controller)
        follow = VIEWER.split('func htmlPreviewWillOpen(', 1)[1].split('func openHTMLAsText(', 1)[0]
        self.assertIn('htmlTarget = (target.directory, relativePath)', follow)
        self.assertIn('details = document.details', follow)
        self.assertIn('htmlTargetReady = false', follow)
        self.assertIn('htmlTargetReady = true', follow)
        self.assertIn('guard detectedFormat != .html || htmlTargetReady else { return additional }', VIEWER)
        reopen = VIEWER.split('private func open(as format:', 1)[1].split('private static func name(', 1)[0]
        self.assertIn('target.directory.open(target.relativePath)', reopen)
        load = controller.split('private func load(', 1)[1].split('private func installRenderer(', 1)[0]
        self.assertNotIn('permissions = HTMLPreviewPermissions()', load)


if __name__ == '__main__':
    unittest.main()
