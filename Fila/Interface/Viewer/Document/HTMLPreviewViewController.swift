import AlertController
import FilaBackendUI
import FilaFormats
import FilaLog
import FilaProtocol
import SafariServices
import SnapKit
import Then
import UIKit
import WebKit

/// A real web renderer inside the existing viewer frame. It does not share the
/// Office converter's JavaScript allowance, delegates or retry state.
final class HTMLPreviewViewController: TabContentViewController, WKNavigationDelegate, WKUIDelegate {
    private enum State { case preparing, loading, shown, failed, closed }
    private var state = State.preparing
    private let policy = HTMLPreviewPolicy()
    private var permissions = HTMLPreviewPermissions()
    private var directory: HTMLPreviewDirectory?
    private var initialDocument: HTMLPreviewDocument?
    private var handler: HTMLSchemeHandler?
    private var webView: WKWebView?
    private var currentURL: URL?
    private var loadingURL: URL?
    private var generation = 0
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let status = StatusView(content: .loading(String(localized: "Opening…")))

    init(source: HTMLPreviewSource) {
        directory = source.directory
        initialDocument = source.document
        super.init(nibName: nil, bundle: nil)
        title = source.document.details.node.name
        currentURL = try? policy.url(relativePath: source.document.relativePath)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(status)
        status.snp.makeConstraints { $0.edges.equalToSuperview() }
        refreshMenu()
        load(currentURL)
    }

    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        if parent == nil {
            state = .closed
            generation += 1
            preparation?.cancel()
            deadline?.cancel()
            retireRenderer()
            directory = nil
            initialDocument = nil
            permissions = HTMLPreviewPermissions()
        }
    }

    deinit {
        preparation?.cancel()
        deadline?.cancel()
    }

    private func refreshMenu() {
        guard let container = parent as? ViewerContainerViewController else { return }
        let script = UIAction(title: String(localized: "Allow JavaScript"), state: permissions.javaScript ? .on : .off) { [weak self] _ in
            guard let self else { return }
            permissions.javaScript.toggle()
            refreshMenu()
            load(currentURL)
        }
        let network = UIAction(title: String(localized: "Allow HTTPS"), state: permissions.https ? .on : .off) { [weak self] _ in
            guard let self else { return }
            permissions.https.toggle()
            refreshMenu()
            load(currentURL)
        }
        let retry = UIAction(title: String(localized: "Retry"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.load(self?.currentURL)
        }
        let text = UIAction(title: String(localized: "Text"), image: UIImage(systemName: "doc.text")) { [weak self, weak container] _ in
            guard let self else { return }
            container?.openHTMLAsText(from: self)
        }
        container.childMenuElements = [UIMenu(title: String(localized: "HTML Preview"), children: [script, network, retry, text])]
        container.refreshBarItems()
    }

    private func retireRenderer() {
        handler?.invalidate()
        handler = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        loadingURL = nil
    }

    private func load(_ url: URL?) {
        guard state != .closed else { return }
        generation += 1
        let ticket = generation
        preparation?.cancel()
        deadline?.cancel()
        retireRenderer()
        state = .preparing
        status.content = .loading(String(localized: "Opening…"))
        status.isHidden = false
        guard let url, policy.isHTML(url), directory != nil,
              let relativePath = try? policy.relativePath(for: url) else { fail("url"); return }
        // Remember a failed destination for an explicit Retry, never auto-retry.
        currentURL = url
        title = (relativePath as NSString).lastPathComponent
        (parent as? ViewerContainerViewController)?.htmlPreviewWillOpen(relativePath, from: self)
        let https = permissions.https
        FilaLog.info("HTML prepare generation=\(ticket) js=\(permissions.javaScript) https=\(https)")
        armDeadline(ticket)
        preparation = Task { [weak self] in
            do {
                // Content-rule compilation cannot be cancelled. Do not retain
                // a controller, directory or file across that callback wait.
                let rules = await HTMLContentRules.load(https: https)
                guard !Task.isCancelled, self?.generation == ticket, self?.state == .preparing,
                      let root = self?.directory else { return }
                guard let rules else { self?.fail("content-rules"); return }
                let prepared = self?.initialDocument
                self?.initialDocument = nil
                // Retain only the directory across a filesystem/XPC open. The
                // first response duplicates the descriptor used for detection.
                let document: HTMLPreviewDocument
                if let prepared, prepared.relativePath == relativePath { document = prepared }
                else { document = try await root.open(relativePath) }
                guard !Task.isCancelled, let self, generation == ticket, state == .preparing else { return }
                title = document.details.node.name
                (parent as? ViewerContainerViewController)?.htmlPreviewOpened(document, from: self)
                FilaLog.info("HTML rules-ready generation=\(ticket)")
                installRenderer(directory: root, document: document, rules: rules, url: url, ticket: ticket)
            } catch {
                guard !Task.isCancelled, let self, generation == ticket, state != .closed else { return }
                let code = (error as? FilaFailure)?.systemError ?? Int32(clamping: (error as NSError).code)
                fail("directory", code: code)
            }
        }
    }

    private func installRenderer(directory: HTMLPreviewDirectory, document: HTMLPreviewDocument, rules: WKContentRuleList, url: URL, ticket: Int) {
        let preferences: WKPreferences
        do { preferences = try HTMLPreviewRTCPolicy.makePreferences() }
        catch { fail("rtc-preferences"); return }
        let resources = HTMLSchemeHandler(directory: directory, document: document, policy: policy, permissions: permissions)
        resources.onFailure = { [weak self] in
            // Defer until WKURLSchemeTask's callback is off the stack before
            // stopping the web view and invalidating its other tasks.
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == ticket, state != .closed else { return }
                fail("resource")
            }
        }
        handler = resources
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration().then {
            $0.preferences = preferences
            $0.websiteDataStore = .nonPersistent()
            $0.defaultWebpagePreferences.allowsContentJavaScript = permissions.javaScript
            $0.preferences.javaScriptCanOpenWindowsAutomatically = false
            $0.mediaTypesRequiringUserActionForPlayback = .all
            $0.setURLSchemeHandler(resources, forURLScheme: HTMLPreviewPolicy.scheme)
            $0.userContentController.add(rules)
        }).then {
            $0.navigationDelegate = self
            $0.uiDelegate = self
            $0.allowsLinkPreview = false
        }
        webView = web
        loadingURL = url
        state = .loading
        view.insertSubview(web, belowSubview: status)
        web.snp.makeConstraints { $0.edges.equalToSuperview() }
        FilaLog.info("HTML load-start generation=\(ticket)")
        guard web.load(URLRequest(url: url)) != nil else { fail("load-request"); return }
    }

    private func armDeadline(_ ticket: Int) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { return }
            guard let self, generation == ticket, state == .preparing || state == .loading else { return }
            fail("timeout")
        }
    }

    /// Same StatusView as other viewers. No diagnostic page or extracted text;
    /// Retry is manual, Text is always in this page's existing ellipsis menu.
    private func fail(_ stage: String, code: Int32 = 0) {
        guard state != .closed, state != .failed else { return }
        state = .failed
        preparation?.cancel()
        deadline?.cancel()
        retireRenderer()
        FilaLog.info("HTML failed stage=\(stage) code=\(code) generation=\(generation)")
        let reason: String
        switch stage {
        case "timeout": reason = String(localized: "The preview timed out.")
        case "web-content-process": reason = String(localized: "The web content process stopped.")
        case "content-rules": reason = String(localized: "The preview's network filter could not be installed.")
        case "rtc-preferences": reason = String(localized: "The preview could not disable WebRTC safely.")
        case "directory", "resource", "url": reason = String(localized: "A local resource could not be opened safely.")
        case "navigation-blocked", "download-or-method-blocked": reason = String(localized: "Fila cannot open this link. Check the address and try again.")
        default: reason = String(localized: "iOS could not display this document. To see what is inside it, choose another format under Open As.")
        }
        status.content = .message(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Unable to Display This Document"),
            detail: reason + "\n\n" + String(localized: "HTML preview failed. Retry, or choose Text in the HTML Preview menu."),
            button: String(localized: "Retry"),
        )
        status.action = { [weak self] in self?.load(self?.currentURL) }
        status.isHidden = false
    }

    /// Safari owns its separate browsing policy. Only a validated HTTPS URL is
    /// handed off, after the existing Fila card has finished dismissing.
    private func confirmExternalLink(_ url: URL) {
        guard let destination = HTMLPreviewPolicy.externalURL(url),
              state == .loading || state == .shown,
              let container = parent as? ViewerContainerViewController,
              container.navigationController?.topViewController === container,
              viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let ticket = generation
        let message = String(localized: "This link opens in the Safari browser inside Fila.") + "\n\n" + destination.absoluteString
        let alert = AlertViewController(
            title: String.LocalizationValue("Open HTTPS Link?"),
            message: .init(message),
        ) { [weak self] context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Open"), attribute: .accent) { [weak self] in
                context.dispose { [weak self] in
                    guard let self, generation == ticket, state == .loading || state == .shown,
                          let container = parent as? ViewerContainerViewController,
                          container.navigationController?.topViewController === container,
                          viewIfLoaded?.window != nil, presentedViewController == nil else { return }
                    let browser = SFSafariViewController(url: destination)
                    present(browser, animated: true)
                }
            }
        }
        present(alert, animated: true)
    }

    func webView(_: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for _: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        // Do not create a default-configured page, reuse another viewer, or
        // route target=_blank/window.open into the system's URL dispatcher.
        return nil
    }

    func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard web === webView, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard action.targetFrame != nil else {
            decisionHandler(.cancel)
            FilaLog.info("HTML new-window request blocked")
            return
        }
        guard !action.shouldPerformDownload,
              action.request.httpMethod == nil || action.request.httpMethod == "GET" else {
            decisionHandler(.cancel)
            fail("download-or-method-blocked")
            return
        }
        if policy.isHTML(url) {
            let mainFrame = action.targetFrame?.isMainFrame == true
            if mainFrame, loadingURL?.path != url.path {
                decisionHandler(.cancel)
                // A fresh handler per main document retires stale resource work;
                // its directory capability and session permissions stay fixed.
                let ticket = generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == ticket else { return }
                    load(url)
                }
            } else {
                decisionHandler(.allow) // Includes anchors on the current page.
            }
            return
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated, HTMLPreviewPolicy.externalURL(url) != nil {
            confirmExternalLink(url)
        } else if action.targetFrame?.isMainFrame != false {
            fail("navigation-blocked")
        }
    }

    func webView(_ web: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard web === webView, let url = response.response.url, policy.isHTML(url),
              response.canShowMIMEType, response.response.mimeType == "text/html" else {
            decisionHandler(.cancel)
            if web === webView { fail("response") }
            return
        }
        FilaLog.info("HTML response main=\(response.isForMainFrame)")
        decisionHandler(.allow)
    }

    func webView(_ web: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        guard web === webView else { return }
        FilaLog.info("HTML navigation-start generation=\(generation)")
        state = .loading
        status.content = .loading(String(localized: "Opening…"))
        status.isHidden = false
        armDeadline(generation)
    }

    func webView(_ web: WKWebView, didFinish _: WKNavigation!) {
        guard web === webView, state == .loading else { return }
        deadline?.cancel()
        state = .shown
        status.isHidden = true
        currentURL = web.url ?? loadingURL
        FilaLog.info("HTML rendered generation=\(generation)")
    }

    func webView(_ web: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        navigationFailed(web, error: error)
    }

    func webView(_ web: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        navigationFailed(web, error: error)
    }

    private func navigationFailed(_ web: WKWebView, error: Error) {
        guard web === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        fail("navigation", code: Int32(clamping: (error as NSError).code))
    }

    func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
        guard web === webView else { return }
        fail("web-content-process")
    }
}

/// Compile before the first request; inability to install the filter fails
/// closed. Only two stable identifiers are used, never session capabilities.
@MainActor
private enum HTMLContentRules {
    static func load(https: Bool) async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        var permissions = HTMLPreviewPermissions()
        permissions.https = https
        let rules = permissions.contentRuleList
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "wiki.qaq.fila.preview.html.\(https ? "https" : "offline")", encodedContentRuleList: rules) { list, error in
                if error != nil { FilaLog.info("HTML content-rule compilation failed") }
                continuation.resume(returning: list)
            }
        }
    }
}
