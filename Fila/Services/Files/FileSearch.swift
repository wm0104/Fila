import FilaLog
import FilaProtocol
import Foundation

/// One hit, with the directory it was found in — a `FileNode` deliberately
/// carries no path, so the walk has to remember where it was.
struct FileSearchResult: Hashable {
    var directory: String
    var node: FileNode

    var path: String {
        directory == "/" ? "/" + node.name : directory + "/" + node.name
    }
}

/// A recursive search, driven from the app.
///
/// The daemon is never asked to walk a tree. A walk holds a frontier that grows
/// with the filesystem, and the daemon is capped at 6 MB by jetsam — the whole
/// reason listings are paged in the first place. Here the frontier is in the
/// app, where a few hundred thousand paths cost little.
///
/// Every folder below the root is searched, however deep, and every page of
/// it: a search that quietly stopped at some depth, or passed over a folder
/// too large to list in one go, would report "no matches" for a name that is
/// there. The one ceiling is on matches, because the results are a list on
/// screen; the walk ends when it is reached and the screen says so.
enum FileSearch {
    static let resultLimit = 10000

    struct Summary {
        var unreadableDirectories = 0
        var skippedLinks = 0
        var isTruncated = false
        var wasCancelled = false
    }

    /// Breadth-first so shallow hits — the ones the user usually meant — arrive
    /// first. Streams matches as it goes and stops the moment the task is
    /// cancelled, which is what leaving the screen does, or once `limit`
    /// matches have been found.
    ///
    /// `onVisit` is handed each directory as the walk reaches it. A search of
    /// `/` touches hundreds of thousands of entries and can find nothing for a
    /// long time, and a screen that cannot say where it has got to is
    /// indistinguishable from one that has stopped.
    ///
    /// Returns how many symbolic links were not entered. The optional summary
    /// also reports unreadable directories, cancellation and the result cap;
    /// the integer return and trailing callbacks stay compatible with Shortcuts.
    @MainActor
    @discardableResult
    static func run(
        root: String,
        needle: String,
        session: FileSession,
        limit: Int = resultLimit,
        onSummary: (@MainActor (Summary) -> Void)? = nil,
        onVisit: @MainActor (String) -> Void,
        onHit: @MainActor (FileSearchResult) async -> Void,
    ) async -> Int {
        var summary = Summary()
        defer {
            summary.wasCancelled = summary.wasCancelled || Task.isCancelled
            onSummary?(summary)
        }
        let needle = needle.lowercased()
        guard !needle.isEmpty, limit > 0 else { return 0 }
        // The needle is what the user typed, not a path and not content. A
        // search that "found nothing" is nearly always a search of the wrong
        // root, and this is the pair of lines that shows it.
        FilaLog.info("search \"\(needle)\" under \(root)")
        let startedAt = Date()
        // Read from `next` rather than shifted off the front: a search of `/`
        // queues tens of thousands of folders, and removing the first of an
        // array moves every one behind it.
        var frontier = [root]
        var next = 0
        var found = 0
        // One exit line however the walk ends — the limit, cancellation or
        // running out of frontier.
        defer {
            FilaLog.info(
                "search \"\(needle)\" ended: \(found) hit(s), \(summary.skippedLinks) link(s) not entered,"
                    + " \(summary.unreadableDirectories) unreadable folder(s)"
                    + (summary.isTruncated ? ", truncated" : "")
                    + (Task.isCancelled ? ", cancelled" : "")
                    + ", \(Int(Date().timeIntervalSince(startedAt) * 1000))ms",
            )
        }
        while next < frontier.count, found < limit {
            let directory = frontier[next]
            frontier[next] = ""
            next += 1
            guard !Task.isCancelled else { return summary.skippedLinks }
            onVisit(directory)
            // A directory being listed is live, so a name can come back on
            // two pages, and a name queued twice would walk its whole subtree
            // twice. Emitting the same path twice is worse than wasteful: the
            // results list is a diffable snapshot, and two equal items in one
            // is a crash. Without links followed, a path is reached only from
            // its own parent, so the names of this one listing are enough.
            var seen: Set<String> = []
            do {
                // Page by page, never collected first: a folder too large to
                // be held as one listing is still searched, all of it. One
                // that cannot be read is passed over, the way `find` does.
                for try await page in DirectoryReader.pages(in: directory, session: session) {
                    for node in page where seen.insert(node.name).inserted {
                        guard !Task.isCancelled else { return summary.skippedLinks }
                        let hit = FileSearchResult(directory: directory, node: node)
                        // Count even unresolved links: their target may be a
                        // directory the backend cannot inspect. Never enter it.
                        if node.kind == .symbolicLink {
                            summary.skippedLinks += 1
                        }
                        if node.name.lowercased().contains(needle) {
                            await onHit(hit)
                            found += 1
                            if found >= limit {
                                summary.isTruncated = true
                                return summary.skippedLinks
                            }
                        }
                        // Symlinks are not followed: a jailbroken filesystem is
                        // full of links back into `/private`, and a walk that
                        // follows them visits the same subtree several times and
                        // can loop forever. The link's own name is still matched
                        // above; only what lies behind it is skipped, and that is
                        // counted so the screen can say so.
                        if node.kind == .directory {
                            frontier.append(hit.path)
                        }
                    }
                    onSummary?(summary)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else {
                    summary.wasCancelled = true
                    return summary.skippedLinks
                }
                summary.unreadableDirectories += 1
                onSummary?(summary)
                continue
            }
        }
        return summary.skippedLinks
    }
}

/// Only a result refresh hint; destructive paths are still validated by the backend.
struct FileSearchChanges {
    private var paths: Set<String> = []
    private(set) var revision = 0

    mutating func record(_ paths: [String]) {
        self.paths.formUnion(paths)
        revision += 1
    }

    func contains(_ path: String) -> Bool {
        var candidate = path
        while !candidate.isEmpty {
            if paths.contains(candidate) { return true }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { break }
            candidate = parent
        }
        return false
    }
}
