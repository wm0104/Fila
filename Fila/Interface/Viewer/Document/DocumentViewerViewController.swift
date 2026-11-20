import FilaBackendUI
import FilaFormats
import FilaLog
import FilaProtocol
import SnapKit
import Then
import UIKit
import WebKit

/// Word, Excel, PowerPoint, Pages, Numbers, Keynote and RTF, drawn by WebKit.
///
/// WebKit converts these itself — the same conversion QuickLook shows — when
/// one arrives as a page's main resource under its MIME type. The resource is
/// served by `DocumentSchemeHandler` from the descriptor, so the bytes go from
/// the kernel to WebKit's content process with no path in between: no second
/// `open(2)`, no staged copy, and a root-only file draws like any other.
/// `QLPreviewController` cannot do that on any path: it renders in a system
/// extension that opens the URL itself, as `mobile`.
///
/// Converted documents stay offline; the converter needs its own scripts for
/// workbook tabs. When WebKit declines a type or fails to draw it, the screen
/// says so — see `documentViewerFailed`. It does not open the file as its bytes:
/// a `.docx` is a ZIP, and dropping someone into its parts reads as Fila
/// mistaking their document for an archive.
final class DocumentViewerViewController: TabContentViewController, WKNavigationDelegate {
    private let handler: DocumentSchemeHandler?
    private var webView: WKWebView?
    private var rules: WKContentRuleList?
    private var retried = false

    /// Over the page until WebKit has drawn it: conversion takes a moment,
    /// and the page is blank until then.
    private let status = StatusView(content: .loading(String(localized: "Opening…")))
    private var state = State.loading
    /// The document's own load. Only its failure is the document failing.
    private var documentNavigation: WKNavigation?

    private enum State {
        case loading
        case shown
        case abandoned
    }

    init(details: FileDetails, file: DescriptorFile) {
        let name = (details.path as NSString).lastPathComponent
        handler = FileFormat.documentMIMEType(name: name).map {
            DocumentSchemeHandler(file: file, name: name, mimeType: $0)
        }
        super.init(nibName: nil, bundle: nil)
        title = name
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(status)
        status.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        guard let handler else {
            // Open As › Document on a name WebKit has no type for.
            abandon("no document type for its name")
            return
        }
        DocumentContentRules.load { [weak self] rules in
            guard let self, state == .loading else { return }
            // Fail closed: without the rules the page could reach the network.
            guard let rules else {
                abandon("the content rules did not compile")
                return
            }
            self.rules = rules
            loadDocument(handler, rules: rules)
        }
    }

    /// Both attempts go through this one construction path. Install the rules
    /// before the first request; a fresh view cannot inherit a dead process's
    /// unfinished navigation or spend the retry on a late delegate callback.
    private func loadDocument(_ handler: DocumentSchemeHandler, rules: WKContentRuleList) {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration().then {
            $0.websiteDataStore = .nonPersistent()
            $0.defaultWebpagePreferences.allowsContentJavaScript = true
            $0.preferences.javaScriptCanOpenWindowsAutomatically = false
            $0.mediaTypesRequiringUserActionForPlayback = .all
            $0.setURLSchemeHandler(handler, forURLScheme: DocumentSchemeHandler.scheme)
            $0.userContentController.add(rules)
        }).then {
            $0.allowsLinkPreview = false
            $0.navigationDelegate = self
        }
        webView = web
        state = .loading
        status.isHidden = false
        view.insertSubview(web, belowSubview: status)
        web.snp.makeConstraints { $0.edges.equalToSuperview() }
        documentNavigation = web.load(URLRequest(url: handler.url))
    }

    private func retireWebView() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        documentNavigation = nil
    }

    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        if parent == nil, isViewLoaded {
            state = .abandoned
            retireWebView()
        }
    }

    /// Tells the container WebKit could not show the document, once.
    /// Deferred a turn: the container replaces this controller, and doing it
    /// from inside a WebKit callback or `viewDidLoad` would pull the view out
    /// from under its own caller.
    private func abandon(_ reason: String) {
        guard state != .abandoned else { return }
        state = .abandoned
        FilaLog.info("document viewer: \(reason)")
        retireWebView()
        DispatchQueue.main.async { [weak self] in
            guard let self, let container = parent as? ViewerContainerViewController else { return }
            container.documentViewerFailed(from: self)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ web: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
    ) {
        guard web === webView, let handler, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        if handler.isDocument(url) {
            // The document, or a place inside it.
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                UIApplication.shared.open(url)
            }
            return
        }
        // The converter's own pages: a workbook's sheets, a frame's blank.
        let isFrame = action.targetFrame.map { !$0.isMainFrame } ?? false
        let isConverted = ["x-apple-ql-id", "about"].contains(url.scheme?.lowercased())
        decisionHandler(isFrame && isConverted ? .allow : .cancel)
    }

    func webView(
        _ web: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void,
    ) {
        guard web === webView else { decisionHandler(.cancel); return }
        guard response.canShowMIMEType else {
            decisionHandler(.cancel)
            if response.isForMainFrame {
                abandon("WebKit cannot show \(response.response.mimeType ?? "its type")")
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, state == .loading, let navigation, navigation === documentNavigation else { return }
        state = .shown
        status.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation, error)
    }

    private func failed(_ web: WKWebView, _ navigation: WKNavigation?, _ error: Error) {
        guard web === webView, state == .loading, let navigation, navigation === documentNavigation else { return }
        let failure = error as NSError
        if failure.domain == WKError.errorDomain, failure.code == WKError.webContentProcessTerminated.rawValue {
            webViewWebContentProcessDidTerminate(web)
        } else {
            abandon("the document failed to load: \(error)")
        }
    }

    /// This callback says the process exited, not why. The identity check also
    /// folds a navigation failure and termination for the same process into one.
    func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
        guard web === webView, state != .abandoned, let handler, let rules else { return }
        let phase = state == .shown ? "after display" : "before display"
        if state == .shown, !retried {
            FilaLog.info("document viewer: WebContent ended \(phase); retrying once")
            retried = true
            retireWebView()
            DispatchQueue.main.async { [weak self] in
                guard let self, state != .abandoned else { return }
                loadDocument(handler, rules: rules)
            }
        } else {
            abandon("WebContent ended \(phase)")
        }
    }
}

/// Office conversion stays offline. Compile once and share the immutable list;
/// a failed compile never starts an unfiltered load.
@MainActor
private enum DocumentContentRules {
    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static let contentRules: String = {
        let block = #"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#
        let schemes = [DocumentSchemeHandler.scheme, "data", "x-apple-ql-id", "about", "blob"]
        let allow = schemes.map { #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"ignore-previous-rules"}}"# }
        return "[" + ([block] + allow).joined(separator: ",") + "]"
    }()

    static func load(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { completion(compiled); return }
        guard let store = WKContentRuleListStore.default() else { completion(nil); return }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        store.compileContentRuleList(forIdentifier: "wiki.qaq.fila.preview.office",
                                     encodedContentRuleList: contentRules) { list, error in
            if let error { FilaLog.warning("document content rules: \(error)") }
            compiled = list
            let callers = waiting
            waiting = []
            for caller in callers { caller(list) }
        }
    }
}
