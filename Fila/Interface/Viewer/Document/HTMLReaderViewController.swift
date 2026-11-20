import FilaBackendUI
import FilaClient
import SnapKit
import Then
import UIKit

/// Read-only text from the descriptor already opened. No web view, tappable
/// URLs, script execution, or file access on behalf of an element in the page.
final class HTMLReaderViewController: UIViewController {
    private let file: DescriptorFile
    private var task: Task<Void, Never>?

    init(file: DescriptorFile) {
        self.file = file
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let status = StatusView(content: .loading(String(localized: "Opening…")))
        view.addSubview(status)
        status.snp.makeConstraints { $0.edges.equalToSuperview() }
        task = Task { [weak self, file] in
            do {
                let truncated = file.byteCount > Int64(HTMLReadableText.byteLimit)
                let body = try await DescriptorIO.blocking { cancelled in
                    guard !cancelled() else { throw CancellationError() }
                    let bytes = truncated ? try file.read(at: 0, count: HTMLReadableText.byteLimit)
                        : try file.readAll(limit: Int64(HTMLReadableText.byteLimit))
                    guard !cancelled() else { throw CancellationError() }
                    return HTMLReadableText.body(from: bytes, truncated: truncated)
                }
                guard let self, !Task.isCancelled else { return }
                status.removeFromSuperview()
                let note = String(localized: "Web preview unavailable. Showing static text only.")
                let paragraph = body.isEmpty ? String(localized: "No readable text in this preview.") : body
                let text = UITextView().then {
                    $0.isEditable = false
                    $0.isSelectable = true
                    $0.dataDetectorTypes = []
                    $0.font = .preferredFont(forTextStyle: .body)
                    $0.adjustsFontForContentSizeCategory = true
                    $0.textContainerInset = FilaUI.textContainerInset
                    $0.backgroundColor = .systemBackground
                    $0.text = [note, paragraph, truncated ? String(localized: "Only the beginning of this file is shown.") : ""]
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
                view.addSubview(text)
                text.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
            } catch {
                guard !Task.isCancelled else { return }
                status.content = .message(symbol: "doc.text", title: String(localized: "Unable to Open This File"), detail: FailureMessage.text(for: error))
            }
        }
    }

    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        if parent == nil { task?.cancel() }
    }

    deinit { task?.cancel() }
}
