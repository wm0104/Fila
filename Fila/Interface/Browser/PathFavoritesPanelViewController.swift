import AlertController
import FilaBackendUI
import FilaProtocol
import SnapKit
import Then
import UIKit

// Keep UIKit's swipe-action titles in the same scale as the panel's labels.
private let panelTextScale: CGFloat = 0.95

/// The favourites, in the panel the path bar's current crumb opens.
///
/// A menu is a list you can only tap: its rows have no long press and no
/// grips. This is that same list with the two gestures a menu has no room
/// for — a long press picks a row up and the rows below it step aside, and a
/// swipe renames or removes it. Both are the system's own: the lift and the
/// reorder are `UICollectionView`'s interactive movement, the swipe is a list
/// configuration's swipe actions, and this file animates neither.
///
/// The whole list is a little larger than the menu it replaced, including
/// the system's swipe buttons; its gestures and transitions stay the same.
final class PathFavoritesPanelViewController: UIViewController {
    private static let contentScale: CGFloat = 1.12 * panelTextScale
    static let panelWidth: CGFloat = 232 * 1.12
    private static let fixedRowHeight: CGFloat = 42 / panelTextScale
    /// Rows on screen before the list scrolls: five, read as a list rather
    /// than as a page.
    private static let visibleFavouriteRows = 5
    private static let cornerRadius: CGFloat = 20
    private static let horizontalInset: CGFloat = 14

    private let directory: String
    private let open: (String) -> Void
    private let goToPath: () -> Void
    private let sourceRect: CGRect?
    private let originRect: CGRect?
    private let dismissalRect: () -> CGRect?
    private let session = FileSession.shared

    /// The rows in the user's order: the stored path and the name it shows.
    private var favourites: [(path: String, name: String)] = []

    private let contentView = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    /// The two rows that never scroll: the path prompt and this folder in or
    /// out of the favourites. Only the list below them moves.
    private let fixedBar = UIView()
    private let goToPathRow = PanelRowView()
    private let toggleRow = PanelRowView()
    /// A list, so that a row can be swiped and so that a long press can move
    /// it the way UIKit moves a cell: the layout is the one that carries the
    /// swipe actions, and the collection view is the one that carries the
    /// interactive movement.
    private lazy var collectionView: UICollectionView = {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.showsSeparators = true
        var separator = UIListSeparatorConfiguration(listAppearance: .plain)
        separator.topSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 0)
        separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 0)
        configuration.separatorConfiguration = separator
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self else { return nil }
            return self.swipeActions(at: indexPath)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        return UICollectionView(frame: .zero, collectionViewLayout: layout).then {
            $0.backgroundColor = .clear
            $0.dataSource = self
            $0.delegate = self
            $0.register(PanelCell.self, forCellWithReuseIdentifier: PanelCell.reuseIdentifier)
        }
    }()

    init(
        directory: String,
        sourceRect: CGRect?,
        originRect: CGRect?,
        dismissalRect: @escaping () -> CGRect?,
        goToPath: @escaping () -> Void,
        open: @escaping (String) -> Void,
    ) {
        self.directory = directory
        self.sourceRect = sourceRect
        self.originRect = originRect
        self.dismissalRect = dismissalRect
        self.goToPath = goToPath
        self.open = open
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.18
        view.layer.shadowRadius = 18
        view.layer.shadowOffset = CGSize(width: 0, height: 8)

        contentView.do {
            $0.backgroundColor = .clear
            $0.layer.cornerRadius = Self.cornerRadius / Self.contentScale
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
            // Scale inside the animated view so UIKit's swipe labels grow too.
            $0.transform = CGAffineTransform(scaleX: Self.contentScale, y: Self.contentScale)
            view.addSubview($0)
            $0.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.width.equalToSuperview().dividedBy(Self.contentScale)
                make.height.equalToSuperview().dividedBy(Self.contentScale)
            }
        }
        blurView.do {
            contentView.addSubview($0)
            $0.snp.makeConstraints { make in make.edges.equalToSuperview() }
        }
        fixedBar.do {
            contentView.addSubview($0)
            $0.snp.makeConstraints { make in
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(Self.fixedRowHeight * 2)
            }
        }
        let fixedStack = UIStackView(arrangedSubviews: [goToPathRow, toggleRow]).then {
            $0.axis = .vertical
            $0.distribution = .fillEqually
        }
        fixedBar.addSubview(fixedStack)
        fixedStack.snp.makeConstraints { make in make.edges.equalToSuperview() }
        goToPathRow.configure(title: String(localized: "Go to Path…"), image: nil)
        goToPathRow.addTarget(self, action: #selector(tappedGoToPath), for: .touchUpInside)
        toggleRow.addTarget(self, action: #selector(tappedToggleFolder), for: .touchUpInside)

        contentView.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.top.equalTo(fixedBar.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        collectionView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(reorder(_:))))

        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updatePreferredSize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.shadowPath = UIBezierPath(
            roundedRect: view.bounds,
            cornerRadius: Self.cornerRadius,
        ).cgPath
    }

    /// The panel is as tall as the rows it shows; the presentation controller
    /// reads this and animates the frame to match.
    private func updatePreferredSize() {
        let screen = view.window?.bounds.size ?? CGSize(width: 375, height: 812)
        let width = min(Self.panelWidth, screen.width - 32)
        var height = Self.fixedRowHeight * 2
        if !favourites.isEmpty {
            let shown = min(favourites.count, Self.visibleFavouriteRows)
            height += favouriteRowHeight * CGFloat(shown)
        }
        preferredContentSize = CGSize(
            width: width,
            height: min(height * Self.contentScale, screen.height * 0.72),
        )
        // A short screen can clip the list even when it has five rows or fewer.
        let listHeight = preferredContentSize.height / Self.contentScale - Self.fixedRowHeight * 2
        collectionView.isScrollEnabled = favouriteRowHeight * CGFloat(favourites.count) > listHeight + 0.5
    }

    // MARK: - Rows

    private func reload() {
        favourites = session.favoritePaths.map { path in
            (path: path, name: session.favoriteName(for: path) ?? Self.folderName(path))
        }
        let favourite = session.isFavorite(directory)
        toggleRow.configure(
            title: favourite
                ? String(localized: "Remove")
                : String(localized: "Add to Favorites"),
            image: UIImage(systemName: favourite ? "star.slash" : "star"),
        )
        collectionView.reloadData()
        updatePreferredSize()
    }

    /// The name a row shows when the user gave it none: the folder's own.
    private static func folderName(_ path: String) -> String {
        path == "/" ? "/" : URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Reorder

    /// The one gesture the platform already knows how to animate: the row
    /// leaves its place, the rows below step aside, and it lands where the
    /// finger lets go. Nothing here draws any of that.
    @objc private func reorder(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(
                at: gesture.location(in: collectionView),
            ) else { return }
            collectionView.beginInteractiveMovementForItem(at: indexPath)
        case .changed:
            collectionView.updateInteractiveMovementTargetPosition(gesture.location(in: collectionView))
        case .ended:
            collectionView.endInteractiveMovement()
        default:
            collectionView.cancelInteractiveMovement()
        }
    }

    /// Two actions, in this order: the first is the one at the trailing edge,
    /// so removal sits furthest out and a full swipe removes — which is what
    /// this list did before it had a second action. Both are painted opaque:
    /// the row underneath is a folder name and a path, and a translucent
    /// button showed them through.
    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard favourites.indices.contains(indexPath.row) else { return nil }
        let path = favourites[indexPath.row].path
        let remove = UIContextualAction(
            style: .destructive,
            title: String(localized: "Remove"),
        ) { [weak self] _, _, done in
            guard let self else { return done(false) }
            session.toggleFavorite(path)
            reload()
            done(true)
        }
        remove.backgroundColor = .systemRed
        let rename = UIContextualAction(
            style: .normal,
            title: String(localized: "Rename Favorite"),
        ) { [weak self] _, _, done in
            guard let self else { return done(false) }
            promptRename(path)
            done(true)
        }
        rename.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [remove, rename])
    }

    // MARK: - Actions

    private func promptRename(_ path: String) {
        let own = Self.folderName(path)
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Rename Favorite"),
            message: String.LocalizationValue(
                "Enter the name this folder shows in this list. Clear the field to show the folder's own name.",
            ),
            placeholder: String.LocalizationValue("Name"),
            text: session.favoriteName(for: path) ?? own,
            doneButtonText: String.LocalizationValue("Rename Favorite"),
            onConfirm: { [weak self] name in
                self?.session.renameFavorite(path, to: name)
                self?.reload()
            },
        )
        present(alert, animated: true)
    }

    @objc private func tappedGoToPath() {
        let go = goToPath
        dismiss(animated: true) { DispatchQueue.main.async { go() } }
    }

    @objc private func tappedToggleFolder() {
        session.toggleFavorite(directory)
        reload()
    }
}

// MARK: - Collection

extension PathFavoritesPanelViewController: UICollectionViewDataSource {
    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
        favourites.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PanelCell.reuseIdentifier,
            for: indexPath,
        ) as! PanelCell
        guard favourites.indices.contains(indexPath.row) else { return cell }
        let row = favourites[indexPath.row]
        cell.configure(
            title: row.name,
            subtitle: row.path,
            image: FilePresentation.image(kind: .directory, name: row.name),
        )
        return cell
    }
}

extension PathFavoritesPanelViewController: UICollectionViewDelegate {
    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard favourites.indices.contains(indexPath.row) else { return }
        let path = favourites[indexPath.row].path
        let open = self.open
        dismiss(animated: true) { open(path) }
    }

    func collectionView(_: UICollectionView, moveItemAt source: IndexPath, to destination: IndexPath) {
        guard favourites.indices.contains(source.row) else { return }
        let moved = favourites.remove(at: source.row)
        favourites.insert(moved, at: min(destination.row, favourites.count))
        // The order the user left the rows in. The backend refuses a list that
        // is not the stored set, so a drag that raced a removal elsewhere
        // writes nothing rather than bringing the removed row back.
        session.setFavoriteOrder(favourites.map { $0.path })
    }
}

// MARK: - Presentation

extension PathFavoritesPanelViewController: UIViewControllerTransitioningDelegate {
    func animationController(
        forPresented _: UIViewController,
        presenting _: UIViewController,
        source _: UIViewController,
    ) -> UIViewControllerAnimatedTransitioning? {
        PanelAnimator(presenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        PanelAnimator(presenting: false)
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source _: UIViewController,
    ) -> UIPresentationController? {
        PanelPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            sourceRect: sourceRect,
            originRect: originRect,
            dismissalRect: dismissalRect,
        )
    }
}

/// Dims what is behind the panel, keeps the panel above the bar the crumb
/// sits on, and grows it out of that crumb — the way the menu it replaces
/// arrived.
private final class PanelPresentationController: UIPresentationController {
    private let sourceRect: CGRect?
    private let originRect: CGRect?
    private let dismissalRect: () -> CGRect?
    private let dimmingView = UIView().then {
        $0.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        $0.alpha = 0
    }

    init(
        presentedViewController: UIViewController,
        presenting: UIViewController?,
        sourceRect: CGRect?,
        originRect: CGRect?,
        dismissalRect: @escaping () -> CGRect?,
    ) {
        self.sourceRect = sourceRect
        self.originRect = originRect
        self.dismissalRect = dismissalRect
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        // The size is the panel's own, and the panel has not loaded its view
        // yet the first time this is asked: loading it here is what makes the
        // first frame the right one rather than a zero rect corrected later.
        _ = presentedViewController.view
        let measured = presentedViewController.preferredContentSize
        let size = measured.width > 0 && measured.height > 0
            ? measured
            : CGSize(width: PathFavoritesPanelViewController.panelWidth, height: 100)
        let bounds = container.bounds
        let inset = container.safeAreaInsets
        // The anchor arrives in window space, which is where the bar measured
        // it; only the container knows its own.
        let anchor = sourceRect.map { container.convert($0, from: nil) }
        let anchorX = anchor.map { $0.maxX } ?? bounds.midX
        var x = anchorX - size.width + 40
        x = min(max(x, inset.left + 8), bounds.width - size.width - inset.right - 8)
        var y = (anchor?.minY ?? bounds.maxY) - size.height - 8
        y = max(y, inset.top + 8)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }
        dimmingView.frame = container.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.insertSubview(dimmingView, at: 0)
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissPanel)))

        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.dimmingView.alpha = 1
        })
    }

    var transitionSourceRect: CGRect? {
        guard let container = containerView else { return nil }
        return (originRect ?? sourceRect).map { container.convert($0, from: nil) }
    }

    var dismissalSourceRect: CGRect? {
        guard let container = containerView else { return nil }
        return dismissalRect().map { container.convert($0, from: nil) }
    }

    override func dismissalTransitionWillBegin() {
        // The panel's own way out is the animator's — one continuous shrink
        // while it fades; this only takes the dimming with it.
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.dimmingView.alpha = 0
        })
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        containerView?.setNeedsLayout()
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.containerView?.layoutIfNeeded()
        }
    }

    // Frame layout must not clear a transform while either transition is running.
    var isTransitioning = false

    override func containerViewDidLayoutSubviews() {
        super.containerViewDidLayoutSubviews()
        dimmingView.frame = containerView?.bounds ?? .zero
        guard !isTransitioning else { return }
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    @objc private func dismissPanel() {
        presentedViewController.dismiss(animated: true)
    }
}

// MARK: - Cell

/// How tall a favourite's row is: a name, the path under it, and the folder
/// picture the two fixed rows above the list also carry.
private let favouriteRowHeight: CGFloat = 54 * 0.97 / panelTextScale

/// A favourite, as a row of a system list: the folder picture on the leading
/// edge, the name, the path under it. The stock list cell is used on purpose —
/// its swipe is the system's own, so the row travels under the finger while the
/// buttons come in from the trailing edge, instead of being drawn on top of it.
private final class PanelCell: UICollectionViewListCell {
    static let reuseIdentifier = "PathFavoritesPanelCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.snp.makeConstraints { make in
            make.height.equalTo(favouriteRowHeight)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(title: String, subtitle: String?, image: UIImage?) {
        var content = UIListContentConfiguration.subtitleCell()
        content.image = image
        content.imageProperties.maximumSize = CGSize(width: 24 / panelTextScale, height: 24 / panelTextScale)
        content.imageProperties.reservedLayoutSize = CGSize(width: 24 / panelTextScale, height: 24 / panelTextScale)
        content.text = title
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .subheadline)
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingTail
        content.secondaryText = subtitle
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .caption2)
        // One line, cut in the middle: the middle of a path says which folder
        // it is, both ends say where, and the panel is narrower than a row.
        // Left to itself this configuration wraps instead, and a long path
        // filled three lines of the panel.
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        contentConfiguration = content
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
    }
}


/// One of the two rows that stay put above the list: a title, an optional
/// picture on the trailing edge, and the hairline a cell carries.
private final class PanelRowView: UIControl {
    private let titleLabel = UILabel().then {
        $0.font = UIFont.preferredFont(forTextStyle: .footnote)
        $0.textColor = .label
        $0.lineBreakMode = .byTruncatingTail
    }
    private let icon = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    private let separator = UIView().then { $0.backgroundColor = .separator }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        let row = UIStackView(arrangedSubviews: [titleLabel, icon]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = 8
            $0.isUserInteractionEnabled = false
        }
        addSubview(row)
        row.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.trailing.equalToSuperview().offset(-14)
            make.centerY.equalToSuperview()
        }
        icon.snp.makeConstraints { make in
            make.width.height.equalTo(20 / panelTextScale)
        }
        addSubview(separator)
        separator.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.trailing.bottom.equalToSuperview()
            make.height.equalTo(0.5)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(title: String, image: UIImage?) {
        titleLabel.text = title
        icon.image = image
        icon.isHidden = image == nil
        icon.tintColor = .label
        accessibilityLabel = title
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? UIColor.tertiarySystemFill : .clear
        }
    }
}


/// UIKit owns the spring and the fade independently: text appears gradually,
/// while the panel itself grows from (and returns to) the tapped path.
private final class PanelAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) {
        self.presenting = presenting
        super.init()
    }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        PathFavoritesTransition.duration
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        let viewKey: UITransitionContextViewKey = presenting ? .to : .from
        guard let controller = context.viewController(forKey: key), let panel = context.view(forKey: viewKey) else {
            context.completeTransition(false)
            return
        }
        let presentation = controller.presentationController as? PanelPresentationController
        if presenting {
            panel.frame = context.finalFrame(for: controller)
            context.containerView.addSubview(panel)
        }
        let source = presenting ? presentation?.transitionSourceRect
            : (presentation?.dismissalSourceRect ?? presentation?.transitionSourceRect)
        let originalFrame = panel.frame
        let originalSuperview = panel.superview
        let originalIndex = originalSuperview?.subviews.firstIndex(of: panel) ?? 0
        let frame = panel.convert(panel.bounds, to: context.containerView)
        let shadowPadding = panel.layer.shadowRadius * 2
            + max(abs(panel.layer.shadowOffset.width), abs(panel.layer.shadowOffset.height))
        let collapsed = presenting
            ? PathFavoritesTransition.collapsed(frame: frame, source: source)
            : PathFavoritesTransition.dismissal(frame: frame, source: source, shadowPadding: shadowPadding)
        presentation?.isTransitioning = true
        var clippingView: UIView?
        if !presenting, let source, originalSuperview != nil {
            // Clip only the moving panel and its shadow, never the path or dimming view.
            let clipping = UIView(frame: PathFavoritesTransition.dismissalClip(in: context.containerView.bounds, source: source))
            clipping.clipsToBounds = true
            context.containerView.addSubview(clipping)
            let localFrame = panel.convert(panel.bounds, to: clipping)
            clipping.addSubview(panel)
            panel.frame = localFrame
            clippingView = clipping
        }
        if presenting {
            panel.transform = collapsed
            panel.alpha = 0
        }
        let duration = transitionDuration(using: context)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: presenting ? 0.8 : 0.9,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState],
        ) {
            panel.transform = self.presenting ? .identity : collapsed
        } completion: { _ in
            if let clippingView, let originalSuperview {
                panel.transform = .identity
                originalSuperview.insertSubview(panel, at: min(originalIndex, originalSuperview.subviews.count))
                panel.frame = originalFrame
                clippingView.removeFromSuperview()
            }
            if context.transitionWasCancelled {
                panel.transform = .identity
                panel.alpha = 1
            }
            presentation?.isTransitioning = false
            context.completeTransition(!context.transitionWasCancelled)
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            panel.alpha = self.presenting ? 1 : 0
        }
    }
}
