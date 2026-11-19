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
/// workbook tabs. HTML uses the same single descriptor but starts scriptless
/// and offline. Its optional scripts and HTTPS never apply to another viewer.
///
/// When WebKit declines the type or fails to draw it, the screen says so —
/// see `documentViewerFailed`. It does not open the file as its bytes: a
/// `.docx` is a ZIP, and dropping someone into its parts reads as Fila
/// mistaking their document for an archive.
final class DocumentViewerViewController: TabContentViewController, WKNavigationDelegate {
    private let handler: DocumentSchemeHandler?
    private let policy: DocumentPreviewPolicy
    private let file: DescriptorFile
    private lazy var webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration().then {
        // Nothing a document does outlives the screen.
        $0.websiteDataStore = .nonPersistent()
        $0.defaultWebpagePreferences.allowsContentJavaScript = policy.allowsScripts
        $0.preferences.javaScriptCanOpenWindowsAutomatically = false
        $0.mediaTypesRequiringUserActionForPlayback = .all
        if let handler {
            $0.setURLSchemeHandler(handler, forURLScheme: DocumentSchemeHandler.scheme)
        }
    }).then {
        // A link preview loads the link, which is the network by another door.
        $0.allowsLinkPreview = false
        $0.navigationDelegate = self
    }

    /// Over the page until WebKit has drawn it: conversion takes a moment,
    /// and the page is blank until then.
    private let status = StatusView(content: .loading(String(localized: "Opening…")))
    private var state = State.loading
    /// The document's own load. Only its failure is the document failing.
    private var documentNavigation: WKNavigation?

    private enum State {
        case loading
        case shown
        /// The content process died once after the page was shown, and the
        /// page was loaded again. A second death gives up.
        case reloaded
        case abandoned
    }

    init(details: FileDetails, file: DescriptorFile, policy: DocumentPreviewPolicy = .office) {
        self.policy = policy
        self.file = file
        let name = (details.path as NSString).lastPathComponent
        let mime = policy == .office ? FileFormat.documentMIMEType(name: name) : "text/html"
        handler = mime.map {
            DocumentSchemeHandler(file: file, name: name, mimeType: $0, contentSecurityPolicy: policy.contentSecurityPolicy)
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

        view.addSubview(webView)
        view.addSubview(status)
        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        status.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        guard let handler else {
            // Open As › Document on a name WebKit has no type for.
            abandon("no document type for its name")
            return
        }
        if policy != .office {
            let action = UIAction(title: String(localized: "Allow Scripts and HTTPS for This Preview"),
                                  state: policy == .interactiveHTML ? .on : .off) { [weak self] _ in
                guard let self else { return }
                (parent as? ViewerContainerViewController)?.setHTMLPolicy(
                    policy == .offlineHTML ? .interactiveHTML : .offlineHTML, file: file, from: self,
                )
            }
            (parent as? ViewerContainerViewController)?.childMenuElements = [action]
        }
        DocumentContentRules.load(policy) { [weak self] rules in
            guard let self, state == .loading else { return }
            // Fail closed: without the rules the page could reach the network.
            guard let rules else {
                abandon("the content rules did not compile")
                return
            }
            webView.configuration.userContentController.add(rules)
            documentNavigation = webView.load(URLRequest(url: handler.url))
        }
    }

    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        if parent == nil, isViewLoaded {
            state = .abandoned
            webView.stopLoading()
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
        webView.stopLoading()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (parent as? ViewerContainerViewController)?.documentViewerFailed(from: self)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
    ) {
        guard let handler, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        if policy != .office {
            // HTTPS opt-in is for subresources, never another page or app.
            decisionHandler(action.targetFrame?.isMainFrame == true && handler.isDocument(url) ? .allow : .cancel)
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
        _: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void,
    ) {
        guard response.canShowMIMEType else {
            decisionHandler(.cancel)
            if response.isForMainFrame {
                abandon("WebKit cannot show \(response.response.mimeType ?? "its type")")
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        guard state == .loading || state == .reloaded else { return }
        if state == .loading {
            state = .shown
        }
        status.removeFromSuperview()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error)
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error)
    }

    /// The document's own load failing before it was shown is the document
    /// failing to open. Any other navigation is one the policy refused.
    private func failed(_ navigation: WKNavigation?, _ error: Error) {
        guard state == .loading, let navigation, navigation === documentNavigation else { return }
        abandon("the document failed to load: \(error)")
    }

    /// The content process is gone — memory, usually. Before the page was
    /// shown that is the document being too much for it; after, the system
    /// reclaimed it in the background, and the page is loaded again, once.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        switch state {
        case .shown:
            state = .reloaded
            webView.reload()
        case .loading, .reloaded:
            abandon("WebKit's content process ended")
        case .abandoned:
            break
        }
    }
}

/// Keep the converter's and both HTML policies separate, including concurrent
/// opens in different tabs. A failed compile never starts an unfiltered load.
@MainActor
private enum DocumentContentRules {
    private static var compiled: [DocumentPreviewPolicy: WKContentRuleList] = [:]
    private static var waiting: [DocumentPreviewPolicy: [(WKContentRuleList?) -> Void]] = [:]

    static func load(_ policy: DocumentPreviewPolicy, _ completion: @escaping (WKContentRuleList?) -> Void) {
        if let list = compiled[policy] { completion(list); return }
        guard let store = WKContentRuleListStore.default() else { completion(nil); return }
        waiting[policy, default: []].append(completion)
        guard waiting[policy]?.count == 1 else { return }
        store.compileContentRuleList(forIdentifier: "wiki.qaq.fila.preview." + policy.rawValue,
                                     encodedContentRuleList: policy.contentRules(documentScheme: DocumentSchemeHandler.scheme)) { list, error in
            if let error { FilaLog.warning("document content rules: \(error)") }
            compiled[policy] = list
            for caller in waiting.removeValue(forKey: policy) ?? [] { caller(list) }
        }
    }
}
