import FilaBackendUI
import SnapKit
import Then
import UIKit

/// A tab keeps its real navigation stacks. The focused stack fills the window
/// so UIKit lays out its bars normally; only its folder list is shortened.
/// The other stack fits alongside that list, with no duplicate bars. A viewer
/// or editor takes the full window until Back returns to the pair of folders.
final class BrowserPanesController: UIViewController, UIGestureRecognizerDelegate {
    private(set) var first: TabNavigationController
    private(set) var second: TabNavigationController?
    private(set) var active: TabNavigationController
    var navigations: [TabNavigationController] { [first, second].compactMap { $0 } }
    private var other: TabNavigationController? { active === first ? second : first }
    var focusChanged: (() -> Void)?

    private let divider = PaneDivider(frame: .zero)
    private var fraction: CGFloat = 0.5
    private var region = CGRect.zero
    private var horizontal = false
    private weak var limitedList: UICollectionView?
    private var lastRects: [CGRect] = []
    private var arranging = false
    private lazy var headings: [UIButton] = [makeHeading(), makeHeading()]

    init(_ navigation: TabNavigationController) {
        first = navigation
        active = navigation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        install(first)
        for control in headings + [divider as UIView] {
            view.addSubview(control)
            control.isHidden = true
        }
        divider.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
        divider.adjust = { [weak self] step in
            guard let self else { return }
            setFraction(fraction + step)
        }
    }

    private func makeHeading() -> UIButton {
        let button = UIButton(type: .system).then {
            $0.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.titleLabel?.lineBreakMode = .byTruncatingMiddle
            $0.backgroundColor = .secondarySystemBackground
        }
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let index = headings.firstIndex(where: { $0 === button }), navigations.indices.contains(index) else { return }
            focus(navigations[index])
        }, for: .touchUpInside)
        return button
    }

    private func install(_ nav: TabNavigationController) {
        addChild(nav)
        view.insertSubview(nav.view, at: 0)
        nav.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        // Observe the initial touch, before a file row, long press or drag
        // dispatches to the shell. The recognizer never claims the gesture.
        let touch = UITapGestureRecognizer()
        touch.delegate = self
        nav.view.addGestureRecognizer(touch)
        nav.didMove(toParent: self)
    }

    func open(_ navigation: TabNavigationController) {
        guard second == nil else { return }
        loadViewIfNeeded()
        second = navigation
        navigation.suppliesBars = false
        fraction = 0.5
        install(navigation)
        view.sendSubviewToBack(active.view)
        layoutPanes()
    }

    func closeOther() {
        guard let other else { return }
        restoreList()
        other.willMove(toParent: nil)
        other.view.removeFromSuperview()
        other.removeFromParent()
        first = active
        second = nil
        layoutPanes()
        focusChanged?()
    }

    func focus(_ navigation: TabNavigationController) {
        guard navigation !== active, navigations.contains(where: { $0 === navigation }) else { return }
        restoreList()
        active.suppliesBars = false
        active = navigation
        active.view.isHidden = false
        active.suppliesBars = true
        active.view.snp.remakeConstraints { $0.edges.equalToSuperview() }
        view.sendSubviewToBack(active.view)
        layoutPanes()
        focusChanged?()
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive _: UITouch) -> Bool {
        if let other, gesture.view === other.view { focus(other) }
        return false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }

    private func restoreList() {
        if let list = limitedList, let page = list.superview {
            list.snp.remakeConstraints {
                $0.top.bottom.equalToSuperview()
                $0.leading.trailing.equalTo(page.safeAreaLayoutGuide)
            }
        }
        limitedList = nil
        lastRects = []
    }

    private func place(_ item: UIView, in rect: CGRect) {
        item.snp.remakeConstraints {
            $0.left.equalToSuperview().offset(rect.minX)
            $0.top.equalToSuperview().offset(rect.minY)
            $0.width.equalTo(rect.width)
            $0.height.equalTo(rect.height)
        }
    }

    func layoutPanes() {
        guard isViewLoaded, !arranging, active.parent === self else { return }
        if let other, other.viewIfLoaded?.superview !== view { return }
        arranging = true
        defer { arranging = false }
        let page = active.topViewController
        let list = (page as? FileBrowserViewController)?.collectionView ?? (page as? FileServiceBrowserViewController)?.collectionView
        guard let other, let list, let pageView = page?.viewIfLoaded, list.superview === pageView else {
            restoreList()
            other?.view.isHidden = true
            headings.forEach { $0.isHidden = true }
            divider.isHidden = true
            return
        }
        if limitedList !== list { restoreList(); limitedList = list }
        region = pageView.convert(pageView.safeAreaLayoutGuide.layoutFrame, to: view).intersection(view.bounds)
        guard !region.isNull, min(region.width, region.height) > 1 else { return }
        let layout = PaneLayout(region: region, host: view.bounds.size, fraction: fraction)
        horizontal = layout.horizontal
        let index = active === first ? 0 : 1
        let local = pageView.convert(layout.lists[index], from: view)
        let inactive = layout.lists[1 - index]
        let geometry = layout.headings + [local, inactive, layout.divider]
        if lastRects != geometry {
            lastRects = geometry
            place(list, in: local)
            place(other.view, in: inactive)
            for i in headings.indices { place(headings[i], in: layout.headings[i]) }
            place(divider, in: layout.divider)
            divider.setAxis(horizontal: horizontal)
            divider.accessibilityValue = Double(fraction).formatted(.percent.precision(.fractionLength(0)))
        }
        other.view.isHidden = false
        for (i, nav) in navigations.enumerated() {
            let heading = headings[i]
            let title = nav.topViewController?.navigationItem.title ?? nav.topViewController?.title
            if heading.title(for: .normal) != title { heading.setTitle(title, for: .normal) }
            heading.isHidden = false
            if heading.isSelected != (nav === active) { heading.isSelected = nav === active }
            heading.tintColor = nav === active ? view.tintColor : .secondaryLabel
        }
        divider.isHidden = false
    }

    @objc private func resize(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let delta = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        let length = horizontal ? region.width - divider.bounds.width : region.height - divider.bounds.height
        if length > 0 { setFraction(fraction + (horizontal ? delta.x : delta.y) / length) }
    }

    private func setFraction(_ value: CGFloat) {
        fraction = PaneLayout.clamped(value)
        layoutPanes()
    }
}

private final class PaneDivider: UIView {
    var adjust: ((CGFloat) -> Void)?
    private let grip = UIView().then {
        $0.backgroundColor = .tertiaryLabel
        $0.layer.cornerRadius = 2
        $0.isUserInteractionEnabled = false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Resize Panes")
        accessibilityTraits = .adjustable
        addSubview(grip)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func setAxis(horizontal: Bool) {
        grip.snp.remakeConstraints {
            $0.center.equalToSuperview()
            $0.size.equalTo(horizontal ? CGSize(width: 4, height: 32) : CGSize(width: 32, height: 4))
        }
    }

    override func accessibilityIncrement() { adjust?(0.05) }
    override func accessibilityDecrement() { adjust?(-0.05) }
}
