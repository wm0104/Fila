import FilaBackendUI
import FilaProtocol
import SnapKit
import Then
import UIKit

/// Name-only recursive search within the current directory or the active backend's root.
final class SearchViewController: TabContentViewController {
    enum Scope {
        case folder
        case entireSystem
    }

    private let root: String
    private let session = FileSession.shared
    private let initialQuery: String?
    private var scope: Scope
    private var searchID = UUID()
    private var renderedQuery: String?
    private var renderedScope: Scope?
    private var hits: [FileSearchResult] = []
    private var walk: Task<Void, Never>?
    /// A subtree walk a newer search in this tab stopped; run again when this
    /// page appears.
    private var interruptedQuery: String?
    private var query = ""
    private var isSearching = false
    private var summary = FileSearch.Summary()

    private var searchRoot: String {
        scope == .folder ? root : session.local.rootPath
    }
    private var currentDirectory = ""
    private var lastProgressDraw = Date.distantPast
    private var lastHitsDraw = Date.distantPast

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, FileSearchResult>!
    /// Stands in for the search field's magnifier while a walk is still
    /// running behind rows that are already on screen.
    private let spinner = UIActivityIndicatorView(style: .medium).then {
        $0.isAccessibilityElement = false
    }

    private var magnifier: UIView?

    init(root: String, query: String? = nil, scope: Scope = .folder) {
        self.root = root
        initialQuery = query
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Search")
        trailingNavigationItems = [Self.actionsItem(menu: nil)]
        updateScopeMenu()
        // The folder being searched, then this screen; a crumb on the
        // folder or an ancestor goes back to its browser.
        decorationSource = LocalPathDecoration(
            directory: root,
            screen: PathBarView.Crumb(title: title ?? "", icon: UIImage(systemName: "magnifyingglass")),
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not supported")
    }

    deinit { walk?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        definesPresentationContext = true

        let search = UISearchController(searchResultsController: nil)
        search.delegate = self
        search.searchBar.delegate = self
        search.searchBar.placeholder = String(localized: "Search file names")
        // A name is matched as typed: `it's` must not become `it’s`.
        search.searchBar.searchTextField.do {
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.smartQuotesType = .no
            $0.smartDashesType = .no
            $0.smartInsertDeleteType = .no
        }
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        installSearch(search)
        magnifier = search.searchBar.searchTextField.leftView

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout()).then {
            $0.delegate = self
            $0.alwaysBounceVertical = true
            $0.keyboardDismissMode = .onDrag
        }
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
        }
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.style = .soft
            collectionView.bottomEdgeEffect.style = .soft
        }

        // Both scopes include descendants, so every hit needs its location.
        let cell = UICollectionView.CellRegistration<IconRowCell, FileSearchResult> { [weak self] cell, _, hit in
            cell.configure(
                name: hit.node.name,
                detail: FilePresentation.visibleName(hit.directory),
                image: FilePresentation.image(for: hit.node),
                highlight: self?.query,
            )
            cell.showThumbnail(for: hit.path, node: hit.node, session: .shared)
            cell.accessories = hit.node.isNavigable ? [.disclosureIndicator()] : []
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, hit in
            collection.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: hit)
        }
        // The walk stops at `FileSearch.resultLimit`, and never enters a link;
        // a page that looked complete would be a lie the user cannot detect.
        // The footer exists only while there is something to confess (see
        // `layout(footer:)`).
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter,
        ) { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.plainFooter()
            content.text = self?.footerText
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        search.searchBar.text = initialQuery
        start(initialQuery ?? "")
    }

    /// An empty search page has one thing to do; put the caret in the field.
    /// Only the first time: coming Back to results keeps the keyboard down.
    private var hasActivatedSearch = false
    private var hasOfferedKeyboard = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resumeWalk()
        guard !hasActivatedSearch else { return }
        hasActivatedSearch = true
        if (initialQuery ?? "").isEmpty {
            // Focus is taken in `didPresentSearchController` once the bar is
            // presented; activation is what presents it.
            navigationItem.searchController?.isActive = true
            navigationItem.searchController?.searchBar.becomeFirstResponder()
        }
    }

    /// From did-appear, not will-appear: an interactive swipe back that is
    /// cancelled sends both pages `viewWillAppear`, and each would restart
    /// its walk and stop the other's over a gesture that went nowhere.
    private func resumeWalk() {
        if let query = interruptedQuery {
            start(query)
        } else if walk != nil {
            interruptOtherWalks()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Deactivate only when navigation leaves this page, not when the
        // search controller itself is being presented. Keep its query and
        // results attached so Back does not rebuild the search interface.
        if isMovingFromParent
            || navigationController?.topViewController !== self
            || isBeingDismissed
            || navigationController?.isBeingDismissed == true
        {
            navigationItem.searchController?.isActive = false
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.viewControllers.contains(where: { $0 === self }) != true {
            stopSearch()
        }
    }

    private func updateScopeMenu() {
        let options: [(Scope, String)] = [
            (.folder, String(localized: "Current Directory")),
            (.entireSystem, String(localized: "Entire System")),
        ]
        let actions = options.map { option, title in
            UIAction(
                title: title,
                image: UIImage(systemName: option == .folder ? "folder" : "square.stack.3d.up"),
                state: scope == option ? .on : .off,
            ) { [weak self] _ in
                self?.selectScope(option)
            }
        }
        navigationItem.rightBarButtonItem?.menu = UIMenu(children: [
            FilaMenu.selection(title: String(localized: "Search In"), actions: actions),
            settingsMenuElement,
        ])
    }

    private func selectScope(_ scope: Scope) {
        guard self.scope != scope else { return }
        self.scope = scope
        updateScopeMenu()
        // A subtree walk is deliberate; switching the scope must not start one.
        start("")
    }

    private func start(_ needle: String) {
        walk?.cancel()
        walk = nil
        let searchID = UUID()
        self.searchID = searchID
        interruptedQuery = nil
        hits = []
        query = needle
        summary = FileSearch.Summary()
        let searchRoot = self.searchRoot
        currentDirectory = searchRoot
        isSearching = !needle.isEmpty
        apply()
        guard isSearching else { return }
        interruptOtherWalks()
        walk = Task { [weak self] in
            guard let self, !Task.isCancelled, self.searchID == searchID else { return }
            await FileSearch.run(
                root: searchRoot,
                needle: needle,
                session: session,
                onSummary: { summary in
                    guard self.searchID == searchID else { return }
                    self.summary = summary
                },
            ) { directory in
                guard !Task.isCancelled, self.searchID == searchID else { return }
                self.currentDirectory = directory
                guard Date().timeIntervalSince(self.lastProgressDraw) > 0.2 else { return }
                self.lastProgressDraw = Date()
                self.updateStatus()
            } onHit: { hit in
                guard !Task.isCancelled, self.searchID == searchID else { return }
                self.hits.append(hit)
                // By time, not by count: an apply costs by the rows already
                // listed, and thousands of hits a few at a time would spend
                // the main thread diffing the same list over and over.
                guard self.hits.count == 1 || Date().timeIntervalSince(self.lastHitsDraw) > 0.25 else { return }
                self.lastHitsDraw = Date()
                self.apply()
            }
            guard !Task.isCancelled, self.searchID == searchID else { return }
            walk = nil
            isSearching = false
            apply()
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, FileSearchResult>()
        snapshot.appendSections([0])
        snapshot.appendItems(hits)
        // Identity describes the file, not the highlighted query. Retained
        // rows must be configured again even when the result set is unchanged.
        if renderedQuery != query || renderedScope != scope {
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(hits.filter { existing.contains($0) })
        }
        renderedQuery = query
        renderedScope = scope
        dataSource.apply(snapshot, animatingDifferences: false)
        let showsFooter = footerText != nil
        if showsFooter != hasFooterLayout {
            hasFooterLayout = showsFooter
            collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        } else if showsFooter {
            // Same layout, possibly a new confession: redraw the footer text.
            collectionView.collectionViewLayout.invalidateLayout()
        }
        updateStatus()
    }

    /// Shared by the existing footer and empty state, including zero-hit failures.
    private var scopeNotes: String? {
        var lines: [String] = []
        if scope == .entireSystem {
            lines.append(
                String(localized: "Searches only locations accessible to the current backend, starting at “\(searchRoot)”. No additional privileges are requested."),
            )
        }
        if summary.isTruncated {
            lines.append(
                String(localized: "Showing the first \(FileSearch.resultLimit) matches. Try a more specific name."),
            )
        }
        if summary.unreadableDirectories > 0 {
            lines.append(
                String(localized: "Could not fully read \(summary.unreadableDirectories) directories. Results may be incomplete."),
            )
        }
        if summary.skippedLinks > 0 {
            lines.append(
                String(localized: "Skipped \(summary.skippedLinks) symbolic links; their targets were not searched."),
            )
        }
        if summary.wasCancelled {
            lines.append(String(localized: "Search was cancelled. Results may be incomplete."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private var footerText: String? {
        hits.isEmpty ? nil : scopeNotes
    }

    private var hasFooterLayout = false

    /// Built like the browser's list: `footerMode` on a plain list pins its
    /// footer to the visible bounds, and this one has to end the list, not
    /// hover over the last rows.
    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        let footer = hasFooterLayout
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if footer {
                section.boundarySupplementaryItems = [FileBrowserViewController.footerItem()]
            }
            return section
        }
    }

    private func updateStatus() {
        // The empty states are read while the keyboard is up; centre them in
        // the band above it instead of behind it.
        collectionView.showStatus(status, followsKeyboard: true)
        // Empty results already show their own loading indicator. Once hits
        // arrive, the only remaining question is whether more may come, and
        // the search field's magnifier is the one slot that can say so
        // without adding a row.
        let field = navigationItem.searchController?.searchBar.searchTextField
        if isSearching, !hits.isEmpty {
            spinner.startAnimating()
            field?.leftView = spinner
        } else {
            spinner.stopAnimating()
            field?.leftView = magnifier
        }
    }

    private func stopSearch() {
        if isSearching { summary.wasCancelled = true }
        walk?.cancel()
        walk = nil
        searchID = UUID()
        isSearching = false
        apply()
    }

    /// One subtree walk per tab: the newest search's. A search pushed over
    /// another — by hand, or by a `fila://search` link, which anything on
    /// the device can send — stops the walks under it, which start again
    /// when their page comes back. Without this, every link stacked another
    /// whole-filesystem walk.
    private func interruptOtherWalks() {
        for case let other as SearchViewController in navigationController?.viewControllers ?? [] where other !== self {
            other.interruptWalk()
        }
    }

    private func interruptWalk() {
        guard walk != nil else { return }
        stopSearch()
        interruptedQuery = query
    }

    private var status: StatusView.Content? {
        guard hits.isEmpty else { return nil }
        if isSearching {
            let detail = [currentDirectory, scopeNotes].compactMap { $0 }.joined(separator: "\n")
            return .loading(String(localized: "Searching…"), detail: detail)
        }
        guard !query.isEmpty else {
            let prompt = String(localized: "Enter a name, then tap Search to include all subfolders.")
            let detail = [prompt, scopeNotes].compactMap { $0 }.joined(separator: "\n")
            return .message(
                symbol: "magnifyingglass",
                title: scope == .folder
                    ? String(localized: "Search Current Directory")
                    : String(localized: "Search Entire System"),
                detail: detail,
            )
        }
        let message = String(localized: "No matching names were found in the searched locations.")
        let detail = [message, scopeNotes].compactMap { $0 }.joined(separator: "\n")
        return .message(symbol: "magnifyingglass", title: String(localized: "No Matches"), detail: detail)
    }
}

extension SearchViewController: UISearchControllerDelegate {
    /// The keyboard does not follow activation on its own, and at callback
    /// time the presentation transition is still running — a direct
    /// `becomeFirstResponder()` is refused. One runloop turn later the field
    /// accepts the focus. A user-activated bar is already focused, making
    /// this a harmless no-op there.
    func didPresentSearchController(_ searchController: UISearchController) {
        guard !hasOfferedKeyboard else { return }
        hasOfferedKeyboard = true
        DispatchQueue.main.async {
            searchController.searchBar.becomeFirstResponder()
        }
    }
}

extension SearchViewController: UISearchBarDelegate {
    func searchBar(_: UISearchBar, textDidChange _: String) {
        // Both scopes recurse; typing cancels stale work, Search submits a walk.
        start("")
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        start(searchBar.text ?? "")
    }

    func searchBarCancelButtonClicked(_: UISearchBar) {
        stopSearch()
    }
}

extension SearchViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let hit = dataSource.itemIdentifier(for: indexPath) else { return }
        open(hit)
    }

    private func open(_ hit: FileSearchResult) {
        if hit.node.isNavigable {
            navigationController?.pushViewController(FileBrowserViewController(directory: hit.path), animated: true)
        } else {
            Task { await openFile(at: hit.path, session: session) }
        }
    }

    /// The shared file menu also lets a search result reveal its location.
    func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let hit = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var additional: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Reveal in Folder"),
                    image: UIImage(systemName: "folder"),
                ) { [weak self] _ in
                    self?.shell?.follow(.reveal(hit.path))
                },
            ]
            if hit.node.isNavigable {
                additional.append(UIAction(
                    title: String(localized: "Open in New Tab"),
                    image: UIImage(systemName: "plus.square.on.square"),
                ) { [weak self] _ in
                    self?.shell?.openInNewTab(hit.path)
                })
            }
            let actions = FileActions(presenter: self, directory: hit.directory) { [weak self] in
                guard let self else { return }
                hits.removeAll { $0 == hit }
                apply()
            }
            return UIMenu(
                title: hit.node.name,
                children: actions.menuElements(
                    for: hit.path,
                    node: hit.node,
                    additional: additional,
                    preview: { [weak self] in self?.open(hit) },
                ),
            )
        }
    }
}
