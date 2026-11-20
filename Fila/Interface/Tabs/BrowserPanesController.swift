import FilaBackendUI
import SnapKit
import Then
import UIKit

/// A push or pop stays inside its own pane. The active page supplies the
/// items for the one bottom toolbar; only an explicit close removes a pane.
final class BrowserPanesController: UIViewController, UIGestureRecognizerDelegate {
    private(set) var first: TabNavigationController
    private(set) var second: TabNavigationController?
    private(set) var active: TabNavigationController
    var navigations: [TabNavigationController] { [first, second].compactMap { $0 } }
    var focusChanged: (() -> Void)?

    private let divider = PaneDivider(frame: .zero)
    private let toolbar = UIToolbar()
    private var dividerTop: Constraint?
    private var dividerHeight: Constraint?
    private var edges: [ObjectIdentifier: (top: Constraint, bottom: Constraint)] = [:]
    private var fraction: CGFloat = 0.5
    private var available: CGFloat = 0
    private var arranging = false

    init(_ navigation: TabNavigationController) {
        first = navigation
        active = navigation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        toolbar.isHidden = true
        view.addSubview(toolbar)
        toolbar.snp.makeConstraints {
            $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            $0.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        divider.isHidden = true
        view.addSubview(divider)
        divider.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview()
            dividerTop = $0.top.equalToSuperview().constraint
            dividerHeight = $0.height.equalTo(20).constraint
        }
        divider.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
        divider.adjust = { [weak self] step in
            guard let self else { return }
            setFraction(fraction + step)
        }
        install(first)
    }

    private func install(_ navigation: TabNavigationController) {
        addChild(navigation)
        view.insertSubview(navigation.view, at: 0)
        navigation.view.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview()
            edges[ObjectIdentifier(navigation)] = ($0.top.equalToSuperview().constraint, $0.bottom.equalToSuperview().constraint)
        }
        // Notice the initial touch before the row, drag or navigation button
        // handles it. Returning false leaves all of their native gestures alone.
        let touch = UITapGestureRecognizer()
        touch.delegate = self
        navigation.view.addGestureRecognizer(touch)
        navigation.didMove(toParent: self)
    }

    func open(_ navigation: TabNavigationController) {
        guard second == nil else { return }
        loadViewIfNeeded()
        second = navigation
        fraction = 0.5
        install(navigation)
        navigations.forEach { $0.updatePaneSwitch(isOpen: true) }
        layoutPanes()
    }

    func closeOther() {
        guard let other = navigations.first(where: { $0 !== active }) else { return }
        other.willMove(toParent: nil)
        other.view.removeFromSuperview()
        edges.removeValue(forKey: ObjectIdentifier(other))
        other.removeFromParent()
        first = active
        second = nil
        first.updatePaneSwitch(isOpen: false)
        layoutPanes()
        focusChanged?()
    }

    func focus(_ navigation: TabNavigationController) {
        guard navigation !== active, navigations.contains(where: { $0 === navigation }) else { return }
        active = navigation
        layoutPanes()
        focusChanged?()
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive _: UITouch) -> Bool {
        if let pane = navigations.first(where: { $0.viewIfLoaded === recognizer.view }) { focus(pane) }
        return false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }

    func syncToolbar() {
        guard !toolbar.isHidden, let page = active.topViewController as? TabContentViewController,
              page.usesPaneToolbar, page.toolbarItems?.isEmpty != false else { return }
        let items = page.paneToolbarItems
        if toolbar.items != items { toolbar.setItems(items, animated: false) }
    }

    func layoutPanes() {
        guard isViewLoaded, !arranging, edges[ObjectIdentifier(active)] != nil else { return }
        arranging = true
        defer { arranging = false }
        guard let second else {
            toolbar.isHidden = true
            if toolbar.items != nil { toolbar.setItems(nil, animated: false) }
            divider.isHidden = true
            first.usesSharedToolbar = false
            place(first, top: 0, bottom: 0)
            return
        }
        guard edges[ObjectIdentifier(second)] != nil else { return }
        for nav in [first, second] { nav.usesSharedToolbar = true }
        toolbar.isHidden = false
        syncToolbar()
        divider.isHidden = false
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let bottom = safe.maxY - toolbar.sizeThatFits(safe.size).height
        let layout = PaneLayout(top: safe.minY, bottom: bottom, fraction: fraction)
        available = layout.available
        update(dividerTop, layout.dividerTop)
        update(dividerHeight, layout.dividerHeight)
        place(first, top: 0, bottom: layout.dividerTop - view.bounds.height)
        place(second, top: layout.dividerTop + layout.dividerHeight, bottom: bottom - view.bounds.height)
    }

    private func place(_ navigation: TabNavigationController, top: CGFloat, bottom: CGFloat) {
        guard let edge = edges[ObjectIdentifier(navigation)] else { return }
        update(edge.top, top)
        update(edge.bottom, bottom)
    }

    private func update(_ constraint: Constraint?, _ value: CGFloat) {
        if constraint?.layoutConstraints.first?.constant != value { constraint?.update(offset: value) }
    }

    @objc private func resize(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed, available > 0 else { return }
        let delta = gesture.translation(in: view).y
        gesture.setTranslation(.zero, in: view)
        setFraction(fraction + delta / available)
    }

    private func setFraction(_ value: CGFloat) {
        fraction = PaneLayout.clamped(value)
        divider.accessibilityValue = Double(fraction).formatted(.percent.precision(.fractionLength(0)))
        view.setNeedsLayout()
    }
}

private final class PaneDivider: UIView {
    var adjust: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Resize Panes")
        accessibilityTraits = .adjustable
        let grip = UIView().then {
            $0.backgroundColor = .tertiaryLabel
            $0.layer.cornerRadius = 2
            $0.isUserInteractionEnabled = false
        }
        addSubview(grip)
        grip.snp.makeConstraints {
            $0.center.equalToSuperview()
            $0.size.equalTo(CGSize(width: 32, height: 4))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func accessibilityIncrement() { adjust?(0.05) }
    override func accessibilityDecrement() { adjust?(-0.05) }
}
