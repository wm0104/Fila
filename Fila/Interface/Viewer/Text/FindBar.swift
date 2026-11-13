import FilaBackendUI
import SnapKit
import Then
import UIKit

/// A find bar. iOS 16 has `UIFindInteraction` and this becomes four lines the
/// day the deployment target moves; until then it is a text field and two
/// chevrons.
final class FindBar: UIView {
    var onFind: ((String, Bool) -> Void)?
    var onTermChange: (() -> Void)?
    var onReplace: ((String, String, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let field = FindInputField()
    private let replacement = FindInputField()
    private let replacementControls = UIStackView()
    private let result = UILabel()

    var term: String { field.text ?? "" }
    var allowsReplacement = false {
        didSet {
            if !allowsReplacement { replacementControls.isHidden = true }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The breadcrumb is hosted by a native toolbar; use that same system material.
        let appearance = UIToolbarAppearance().then { $0.configureWithDefaultBackground() }
        backgroundColor = appearance.backgroundColor ?? .systemBackground
        let background = UIVisualEffectView(effect: appearance.backgroundEffect).then {
            $0.isUserInteractionEnabled = false
        }
        addSubview(background)
        background.snp.makeConstraints { $0.edges.equalToSuperview() }

        field.do {
            $0.placeholder = String(localized: "Find")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.returnKeyType = .search
            $0.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
            $0.addTarget(self, action: #selector(findNext), for: .editingDidEndOnExit)
            $0.addTarget(self, action: #selector(termChanged), for: .editingChanged)
        }

        let backward = UIButton(type: .system).then {
            $0.setImage(UIImage(systemName: "chevron.up"), for: .normal)
            $0.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(weight: .medium), forImageIn: .normal)
            $0.accessibilityLabel = String(localized: "Find Previous")
            $0.addTarget(self, action: #selector(findPrevious), for: .touchUpInside)
        }

        let forward = UIButton(type: .system).then {
            $0.setImage(UIImage(systemName: "chevron.down"), for: .normal)
            $0.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(weight: .medium), forImageIn: .normal)
            $0.accessibilityLabel = String(localized: "Find Next")
            $0.addTarget(self, action: #selector(findNext), for: .touchUpInside)
        }

        let done = UIButton(type: .system).then {
            $0.setTitle(String(localized: "Done"), for: .normal)
            $0.addTarget(self, action: #selector(dismiss), for: .touchUpInside)
        }

        let controls = UIStackView(arrangedSubviews: [field, backward, forward, done]).then {
            $0.spacing = FilaUI.Spacing.compact
            $0.alignment = .center
        }
        replacement.do {
            $0.placeholder = String(localized: "Replace With")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
        }
        let replace = UIButton(type: .system).then {
            $0.setTitle(String(localized: "Replace"), for: .normal)
            $0.addTarget(self, action: #selector(replaceCurrent), for: .touchUpInside)
        }
        let replaceAll = UIButton(type: .system).then {
            $0.setTitle(String(localized: "Replace All"), for: .normal)
            $0.addTarget(self, action: #selector(replaceEveryMatch), for: .touchUpInside)
        }
        replacementControls.do {
            $0.addArrangedSubview(replacement)
            $0.addArrangedSubview(replace)
            $0.addArrangedSubview(replaceAll)
            $0.spacing = FilaUI.Spacing.compact
            $0.setCustomSpacing(FilaUI.Spacing.medium, after: replace)
            $0.alignment = .center
            $0.isHidden = true
        }
        for button in [done, replace, replaceAll] {
            button.do {
                $0.titleLabel?.font = UIFontMetrics(forTextStyle: .body)
                    .scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
                $0.titleLabel?.adjustsFontForContentSizeCategory = true
            }
        }
        for button in [replace, replaceAll] {
            button.snp.makeConstraints { make in
                make.size.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
            }
        }

        result.do {
            $0.font = .preferredFont(forTextStyle: .caption1)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.textAlignment = .center
            $0.isHidden = true
        }
        let stack = UIStackView(arrangedSubviews: [controls, replacementControls, result]).then {
            $0.axis = .vertical
            $0.spacing = FilaUI.Spacing.compact
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.trailing.equalTo(layoutMarginsGuide)
            make.top.equalToSuperview().offset(FilaUI.Spacing.small)
            make.bottom.equalTo(safeAreaLayoutGuide).offset(-FilaUI.Spacing.small).priority(.high)
        }
        backward.snp.makeConstraints { make in
            make.width.equalTo(FilaUI.minimumTapTarget)
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
        forward.snp.makeConstraints { make in
            make.width.equalTo(FilaUI.minimumTapTarget)
            make.height.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
        done.snp.makeConstraints { make in
            make.size.greaterThanOrEqualTo(FilaUI.minimumTapTarget)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func becomeFirstResponderOnField() {
        field.becomeFirstResponder()
    }

    func showResult(_ text: String?) {
        result.text = text
        result.isHidden = text == nil
    }

    func showReplacement() {
        guard allowsReplacement else { return }
        isHidden = false
        replacementControls.isHidden = false
        if term.isEmpty { field.becomeFirstResponder() }
        else { replacement.becomeFirstResponder() }
    }

    @objc private func replaceCurrent() {
        guard allowsReplacement else { return }
        onReplace?(term, replacement.text ?? "", false)
    }

    @objc private func replaceEveryMatch() {
        guard allowsReplacement else { return }
        onReplace?(term, replacement.text ?? "", true)
    }

    @objc private func findNext() {
        onFind?(field.text ?? "", true)
    }

    @objc private func termChanged() {
        onTermChange?()
    }

    @objc private func findPrevious() {
        onFind?(field.text ?? "", false)
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}

private final class FindInputField: UITextField {
    private let reference = UITextField().then { $0.borderStyle = .roundedRect }

    override init(frame: CGRect) {
        super.init(frame: frame)
        borderStyle = .none
        backgroundColor = .clear
        layer.cornerRadius = 11
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    // Preserve UIKit's rounded-field metrics without its second, clipped background.
    private var nativeMetrics: UITextField {
        reference.font = font
        reference.text = text
        reference.placeholder = placeholder
        return reference
    }

    override var intrinsicContentSize: CGSize { nativeMetrics.intrinsicContentSize }
    override func textRect(forBounds bounds: CGRect) -> CGRect { nativeMetrics.textRect(forBounds: bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { nativeMetrics.editingRect(forBounds: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { nativeMetrics.placeholderRect(forBounds: bounds) }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorder()
    }

    private func updateBorder() {
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }
}
