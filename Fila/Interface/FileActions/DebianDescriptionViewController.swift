import FilaBackendUI
import SnapKit
import Then
import UIKit

/// A local draft; only Done returns text to the packing form.
final class DebianDescriptionViewController: UIViewController {
    private let textView = UITextView()
    private let text: String
    private let complete: (String) -> Void

    init(text: String, complete: @escaping (String) -> Void) {
        self.text = text
        self.complete = complete
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Description")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Cancel")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Done"), style: .done, target: self, action: #selector(commit),
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.do {
            $0.text = text
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.smartQuotesType = .no
            $0.smartDashesType = .no
            $0.smartInsertDeleteType = .no
            $0.keyboardDismissMode = .interactive
            $0.alwaysBounceVertical = true
            $0.accessibilityLabel = String(localized: "Description")
        }
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view.layoutMarginsGuide)
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
    }

    @objc private func commit() {
        view.endEditing(true)
        let edited = textView.text ?? ""
        dismiss(animated: true) { self.complete(edited) }
    }
}
