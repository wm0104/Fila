import CRemoveFile
import Darwin
import FilaProtocol
import Foundation

/// A copy, a move, a delete or a search — the first three running on
/// `copyfile(3)`, `removefile(3)`, `renameat(2)` and `clonefile(2)`.
///
/// Nothing that *changes* the filesystem is a hand-written tree walk, and that
/// is not laziness: libSystem preserves extended attributes, ACLs, resource
/// forks, BSD flags and sparseness, its memory is flat regardless of how big the
/// tree is, and its state callbacks are where progress and cancellation come
/// from. Every walk written by hand loses some of that silently, and the loss
/// shows up as the user's data quietly changing.
///
/// A search is the one walk written by hand, because there is no libSystem call
/// that streams name matches and nothing about a search can lose data. It earns
/// its place in the daemon by being flat in memory the same way the others are
/// — see `TreeSearch`.
public final class FileJob: @unchecked Sendable {
    private let request: JobRequest
    private let operations: FileOperations
    private let cancellation = NSLock()
    private var cancelled = false
    /// The archive helper running this job, while one is. Guarded by
    /// `cancellation`, and cleared before the pid is reaped so a late kill
    /// cannot land on whatever process inherits the number.
    private var helper: pid_t = 0

    /// Members an extraction's helper left out, from its last line; zero for
    /// every other job. Read it once `run` has returned, on the thread that ran it.
    public internal(set) var skippedItems: Int64 = 0

    public init(request: JobRequest, operations: FileOperations) {
        self.request = request
        self.operations = operations
    }

    /// Asks the job to stop at its next callback. Safe from any thread; the job
    /// itself runs on one. A helper is hung up and, if it ignores that, killed.
    public func cancel() {
        // The signal goes out under the lock `detachHelper` takes before the
        // pid is reaped, so it reaches the helper or its zombie and never a
        // process that inherited the number.
        cancellation.lock()
        cancelled = true
        let pid = helper
        if pid > 0 {
            kill(pid, SIGTERM)
        }
        cancellation.unlock()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.killHelper(pid)
        }
    }

    func attachHelper(_ pid: pid_t) {
        cancellation.lock()
        helper = pid
        let stop = cancelled
        cancellation.unlock()
        // Cancelled between the spawn and this call: nobody else will say so.
        if stop {
            cancel()
        }
    }

    func detachHelper() {
        cancellation.lock()
        helper = 0
        cancellation.unlock()
    }

    private func killHelper(_ pid: pid_t) {
        cancellation.lock()
        if helper == pid {
            kill(pid, SIGKILL)
        }
        cancellation.unlock()
    }

    public var isCancelled: Bool {
        cancellation.lock()
        defer { cancellation.unlock() }
        return cancelled
    }

    /// Runs to completion on the calling thread and reports how it ended.
    /// `report` is called from the libSystem callbacks, on that same thread.
    ///
    /// `matches` is called by a `.search` job and nobody else, once per batch,
    /// on that same thread. It is separate from `report` because the two mean
    /// different things — how far along, versus what was found — and a search
    /// that finds nothing still reports progress and still completes.
    ///
    /// `note` is a line for the log from an archive job — a member skipped,
    /// a helper that died — that no outcome code carries.
    public func run(
        report: @escaping (JobProgress) -> Void,
        matches: @escaping (SearchBatch) -> Void = { _ in },
        note: @escaping (String) -> Void = { _ in },
    ) -> FilaFailure {
        let tally = JobTally(job: self, report: report)
        do {
            if request.kind.isArchive {
                return try archive(report: report, note: note)
            }
            try perform(tally: tally, matches: matches)
            tally.flush()
            return FilaFailure(code: .success)
        } catch let failure as FilaFailure {
            // Cancellation points report cancellation themselves. A real
            // failure cleaning a temporary must remain visible even then.
            return failure
        } catch {
            return FilaFailure(code: .operationFailed)
        }
    }

    // MARK: - The work

    /// A compress or an extract runs in `fila-archive` — see
    /// `ArchiveHelperRun` — and only where a helper was configured. The
    /// in-process backend never reaches this: it runs the same job itself.
    private func archive(
        report: @escaping (JobProgress) -> Void,
        note: @escaping (String) -> Void,
    ) throws -> FilaFailure {
        guard let helper = operations.archiveHelper else {
            throw FilaFailure(code: .invalidRequest, systemError: ENOSYS)
        }
        guard request.archive != nil, request.destination != nil, !request.sources.isEmpty else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        // Settled here as well as in the helper, so a request that names
        // nothing fails with the errno rather than with a helper exit.
        for source in request.sources {
            _ = try FilaPath.canonical(source)
        }
        return try ArchiveHelperRun.run(
            helper: helper,
            task: ArchiveHelperTask(request: request, bootstrapRoot: operations.bootstrapRoot),
            job: self,
            report: report,
            note: note,
        )
    }

    private func perform(tally: JobTally, matches: @escaping (SearchBatch) -> Void) throws {
        // Settle every path — both ends of every item — before touching any of
        // them. A job that copies over two files and then refuses the third has
        // already done the damage the guard exists to prevent, and the refusal
        // costs nothing if it comes first.
        let sources = try request.sources.map { source -> String in
            switch request.kind {
            case .move, .delete, .restore:
                // Moving, deleting and restoring all remove the source name.
                try operations.resolveForDestruction(source, overrideGuard: request.overrideGuard)
            case .copy, .search:
                // A copy destroys nothing at the source and a search touches
                // nothing at all. Refusing to copy `/usr` somewhere, or to
                // search it, would make the app useless for the thing it is
                // for — so the guard applies to what an operation would
                // *replace* and never to what it reads.
                try FilaPath.canonical(source)
            case .compress, .extract:
                preconditionFailure("archive jobs run in the helper — see run(report:matches:note:)")
            }
        }

        // Nothing below applies to a search: it has no destination to settle
        // and nothing at either end to overwrite.
        if request.kind == .search {
            return try search(sources, tally: tally, deliver: matches)
        }

        // One selected tree must not consume another selected source. Reject
        // duplicates and overlapping roots before any item can be changed.
        let sourceSet = Set(sources)
        guard sourceSet.count == sources.count else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, reason: .overlappingSources)
        }
        for source in sources {
            var parent = FilaPath.directory(of: source)
            while parent != source {
                guard !sourceSet.contains(parent) else {
                    throw FilaFailure(
                        code: .invalidRequest,
                        systemError: EINVAL,
                        path: source,
                        reason: .overlappingSources,
                    )
                }
                if parent == "/" {
                    break
                }
                parent = FilaPath.directory(of: parent)
            }
        }

        var targets: [String] = []
        if request.kind == .restore {
            targets = try sources.map { try restoreTarget(for: $0) }
            guard Set(targets).count == targets.count else {
                throw FilaFailure(code: .invalidRequest, systemError: EINVAL, reason: .conflictingNames)
            }
        } else if request.kind != .delete {
            let directory = try destinationDirectory()
            targets = try sources.map { try target(in: directory, for: $0) }
            guard Set(targets).count == targets.count else {
                throw FilaFailure(
                    code: .invalidRequest,
                    systemError: EINVAL,
                    path: directory,
                    reason: .conflictingNames,
                )
            }
        }

        // A merge must not write into any selected source, including when
        // the destination is an ancestor of it or belongs to another root.
        func validateCopyOverlap() throws {
            for target in targets {
                guard !sources.contains(where: {
                    $0 == target || FilaGuard.isAncestor(target, of: $0) || FilaGuard.isAncestor($0, of: target)
                }) else {
                    throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: target, reason: .overlappingSources)
                }
            }
        }
        if request.kind == .copy { try validateCopyOverlap() }

        var copyDirectory: Int32 = -1
        defer { if copyDirectory >= 0 { close(copyDirectory) } }
        // filad has a 6 MB jetsam limit. Keep compact identities, cap both
        // dictionary entries and retained UTF-8 keys, and refuse before writes
        // rather than silently dropping an approved directory's identity.
        var directorySnapshots: [String: (device: dev_t, inode: ino_t)] = [:]
        var snapshotPathBytes = 0
        func validateCopyDirectory() throws {
            try validateCopyOverlap()
            if let target = targets.first {
                try verifyDirectory(FilaPath.directory(of: target), descriptor: copyDirectory)
            }
        }
        func validateSnapshot(_ path: String, _ current: stat?) throws {
            guard let previous = directorySnapshots[path] else { return }
            guard let current, current.st_mode & S_IFMT == S_IFDIR,
                  current.st_dev == previous.device, current.st_ino == previous.inode else {
                throw FilaFailure(errno: EAGAIN, path: path)
            }
        }
        if request.kind == .copy, request.overwrite, let target = targets.first {
            // Pin before the first report, not after a callback may have
            // exchanged the chosen directory for a different real directory.
            copyDirectory = try filaOpenDirectory(FilaPath.directory(of: target))
            for (source, target) in zip(sources, targets) {
                try copyMerging(source, to: target, tally: nil, validateParents: validateCopyDirectory) { path, metadata in
                    guard let metadata, metadata.st_mode & S_IFMT == S_IFDIR else { return }
                    if directorySnapshots[path] != nil {
                        try validateSnapshot(path, metadata)
                        return
                    }
                    // Only visited directories are retained: intersections and
                    // new subtree roots, never the contents of a new subtree.
                    let bytes = path.utf8.count
                    guard directorySnapshots.count < 1024, bytes <= 128 * 1024 - snapshotPathBytes else {
                        throw FilaFailure(errno: ENOMEM, path: path)
                    }
                    directorySnapshots[path] = (metadata.st_dev, metadata.st_ino)
                    snapshotPathBytes += bytes
                }
            }
        }

        for (index, source) in sources.enumerated() {
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: source)
            }
            tally.beginItem(source)
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: source)
            }
            switch request.kind {
            case .copy:
                if request.overwrite {
                    try copyMerging(
                        source, to: targets[index], tally: tally,
                        validateParents: validateCopyDirectory, inspect: validateSnapshot,
                    )
                } else {
                    try copy(source, to: targets[index], overwrite: false, tally: tally)
                }
            case .move: try move(source, to: targets[index], overwrite: request.overwrite, tally: tally)
            case .restore:
                try move(source, to: targets[index], overwrite: false, tally: tally)
                clearTrashRecord(at: targets[index])
            case .delete: try delete(source, tally: tally)
            case .search, .compress, .extract: break // Returned above.
            }
        }
    }

    /// Walks every root, streaming matches out as batches.
    ///
    /// The final batch goes out however this ends — finished, failed or
    /// cancelled — because it is what carries the limits the walk ran into, and
    /// a client that never received them would show a truncated list as a
    /// complete one.
    private func search(_ roots: [String], tally: JobTally, deliver: @escaping (SearchBatch) -> Void) throws {
        guard let query = request.query, !query.text.isEmpty else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        let search = TreeSearch(query: query, job: self, tally: tally, deliver: deliver)
        defer { search.flush() }
        for root in roots {
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: root)
            }
            try search.run(root: root)
        }
    }

    private func destinationDirectory() throws -> String {
        guard let destination = request.destination else {
            throw FilaFailure(code: .invalidRequest)
        }
        // A destination is an existing directory, so its final symlink must
        // resolve too. Source item paths deliberately keep their final link.
        let directory = try operations.resolveForWrite(FilaPath.resolve(FilaPath.canonical(destination)))
        var metadata = stat()
        try filaCheck(directory) { lstat(directory, &metadata) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw FilaFailure(code: .operationFailed, systemError: ENOTDIR, path: directory)
        }
        return directory
    }

    /// Where `source` lands, having settled what happens to anything already
    /// there.
    private func target(in directory: String, for source: String) throws -> String {
        // A destination inside its own source copies the tree into itself and
        // keeps going until the path runs out — filling the volume on the way.
        // `renameat` catches it with EINVAL; copyfile does not.
        guard source != directory, !FilaGuard.isAncestor(source, of: directory) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: directory, reason: .insideSource)
        }

        let expected = FilaPath.join(directory, FilaPath.name(of: source))
        let target = try operations.resolveForWrite(expected)
        // Merge children already have canonical parents. Never approve a new
        // spelling reached through an ancestor swapped since the last check.
        guard request.kind != .copy || target == expected else {
            throw FilaFailure(errno: ELOOP, path: expected)
        }
        var sourceMetadata = stat()
        try filaCheck(source) { lstat(source, &sourceMetadata) }
        var targetMetadata = stat()
        guard lstat(target, &targetMetadata) == 0 else {
            guard Darwin.errno == ENOENT else { throw FilaFailure(errno: Darwin.errno, path: target) }
            return target
        }
        guard sourceMetadata.st_dev != targetMetadata.st_dev || sourceMetadata.st_ino != targetMetadata.st_ino else {
            throw FilaFailure(
                code: .invalidRequest,
                systemError: EINVAL,
                path: target,
                reason: source == target ? .sameLocation : .sameItem,
            )
        }
        // An approved replacement must report the destruction guard first,
        // even when the source and destination also have incompatible types.
        if request.overwrite {
            _ = try operations.resolveForDestruction(target, overrideGuard: request.overrideGuard)
        }
        // Like cp, reject a file/folder collision before asking to replace it.
        // Use lstat: replacing a symlink must still replace the link itself.
        let sameKinds = request.kind == .copy
            ? sourceMetadata.st_mode & S_IFMT == targetMetadata.st_mode & S_IFMT
            : (sourceMetadata.st_mode & S_IFMT == S_IFDIR) == (targetMetadata.st_mode & S_IFMT == S_IFDIR)
        guard sameKinds else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: target, reason: .differentItemKinds)
        }
        guard request.overwrite else {
            throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: target)
        }
        if request.kind != .copy, targetMetadata.st_mode & S_IFMT == S_IFDIR {
            guard let entries = opendir(target) else { throw FilaFailure(errno: Darwin.errno, path: target) }
            defer { closedir(entries) }
            Darwin.errno = 0
            while let entry = readdir(entries) {
                let name = filaText(entry.pointee.d_name)
                guard name == "." || name == ".." else {
                    throw FilaFailure(code: .operationFailed, systemError: ENOTEMPTY, path: target)
                }
            }
            guard Darwin.errno == 0 else { throw FilaFailure(errno: Darwin.errno, path: target) }
        }
        return target
    }

    /// Only existing directory intersections are enumerated here. Each new
    /// subtree or leaf still goes through the metadata-preserving bulk copy.
    /// A nil tally inspects all discoverable conflicts before the batch writes.
    private func copyMerging(
        _ source: String,
        to destination: String,
        tally: JobTally?,
        validateParents: () throws -> Void = {},
        inspect: (String, stat?) throws -> Void = { _, _ in },
    ) throws {
        if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
        try validateParents()
        let sourceParent = FilaPath.directory(of: source)
        let destinationParent = FilaPath.directory(of: destination)
        let from = try filaOpenDirectory(sourceParent)
        defer { close(from) }
        let into = try filaOpenDirectory(destinationParent)
        defer { close(into) }

        func validate() throws {
            try validateParents()
            try verifyDirectory(sourceParent, descriptor: from)
            try verifyDirectory(destinationParent, descriptor: into)
            guard try target(in: destinationParent, for: source) == destination else {
                throw FilaFailure(errno: ELOOP, path: destination)
            }
            try verifyDirectory(sourceParent, descriptor: from)
            try verifyDirectory(destinationParent, descriptor: into)
        }
        try validate()
        var original = stat(), existing = stat()
        try filaCheck(source) { fstatat(from, FilaPath.name(of: source), &original, AT_SYMLINK_NOFOLLOW) }
        let occupied = fstatat(into, FilaPath.name(of: destination), &existing, AT_SYMLINK_NOFOLLOW) == 0
        if !occupied, Darwin.errno != ENOENT { throw FilaFailure(errno: Darwin.errno, path: destination) }
        try inspect(source, original)
        try inspect(destination, occupied ? existing : nil)
        guard occupied, original.st_mode & S_IFMT == S_IFDIR, existing.st_mode & S_IFMT == S_IFDIR else {
            guard let tally else { return }
            tally.beginItem(source)
            if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
            try validate()
            func validateItem() throws {
                try validate()
                var current = stat()
                try filaCheck(source) { fstatat(from, FilaPath.name(of: source), &current, AT_SYMLINK_NOFOLLOW) }
                guard current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                      current.st_mode & S_IFMT == original.st_mode & S_IFMT else {
                    throw FilaFailure(errno: EAGAIN, path: source)
                }
                if original.st_mode & S_IFMT == S_IFDIR {
                    var appeared = stat()
                    if fstatat(into, FilaPath.name(of: destination), &appeared, AT_SYMLINK_NOFOLLOW) == 0 {
                        // A directory appearing after the merge decision must
                        // not be replaced wholesale, even when it is empty.
                        throw FilaFailure(errno: EAGAIN, path: destination)
                    }
                    guard Darwin.errno == ENOENT else { throw FilaFailure(errno: Darwin.errno, path: destination) }
                }
            }
            try copy(
                source, to: destination, overwrite: true, tally: tally,
                destinationDescriptor: into, validatePublication: validateItem,
            )
            return
        }

        let sourceDirectory = try filaOpenDirectory(source)
        // fdopendir takes ownership only on success.
        guard let entries = fdopendir(sourceDirectory) else {
            let code = Darwin.errno
            close(sourceDirectory)
            throw FilaFailure(errno: code, path: source)
        }
        defer { closedir(entries) }
        let destinationDirectory = try filaOpenDirectory(destination)
        defer { close(destinationDirectory) }
        var openedSource = stat(), openedDestination = stat()
        try filaCheck(source) { fstat(sourceDirectory, &openedSource) }
        try filaCheck(destination) { fstat(destinationDirectory, &openedDestination) }
        guard openedSource.st_dev == original.st_dev, openedSource.st_ino == original.st_ino,
              openedDestination.st_dev == existing.st_dev, openedDestination.st_ino == existing.st_ino else {
            throw FilaFailure(errno: EAGAIN, path: destination)
        }
        func validateDirectories() throws {
            try validate()
            try verifyDirectory(source, descriptor: sourceDirectory)
            try verifyDirectory(destination, descriptor: destinationDirectory)
        }
        while true {
            if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
            Darwin.errno = 0
            guard let entry = readdir(entries) else {
                guard Darwin.errno == 0 else { throw FilaFailure(errno: Darwin.errno, path: source) }
                break
            }
            let name = filaText(entry.pointee.d_name)
            if name == "." || name == ".." { continue }
            try validateDirectories()
            try copyMerging(
                FilaPath.join(source, name),
                to: FilaPath.join(destination, name),
                tally: tally,
                validateParents: validateDirectories,
                inspect: inspect,
            )
        }
    }

    /// Reopening refuses links in any ancestor; identity also catches a real
    /// directory exchanged for another after a progress callback.
    private func verifyDirectory(_ path: String, descriptor: Int32) throws {
        let current = try filaOpenDirectory(path)
        defer { close(current) }
        var pinned = stat(), now = stat()
        try filaCheck(path) { fstat(descriptor, &pinned) }
        try filaCheck(path) { fstat(current, &now) }
        guard pinned.st_dev == now.st_dev, pinned.st_ino == now.st_ino else {
            throw FilaFailure(errno: EAGAIN, path: path)
        }
    }

    private func copy(
        _ source: String,
        to target: String,
        overwrite: Bool,
        tally: JobTally,
        destinationDescriptor: Int32? = nil,
        validatePublication: () throws -> Void = {},
        prepare: (String) throws -> Void = { _ in },
    ) throws {
        // Publish only a complete copy. Cancellation or a failed read leaves
        // the previous destination intact, including when overwrite was approved.
        try validatePublication()
        let (directory, targetName) = filaSplit(target)
        let temporaryName = ".fila-copy-\(UUID().uuidString)"
        let expectedTemporary = FilaPath.join(directory, temporaryName)
        let temporary = try operations.resolveForWrite(expectedTemporary)
        guard destinationDescriptor == nil || temporary == expectedTemporary else {
            throw FilaFailure(errno: ELOOP, path: target)
        }
        // The destination folder, opened again now and held: an ancestor
        // swapped for a link since the guard decided fails here with ELOOP,
        // and every step below that names the temporary or the target is
        // relative to this descriptor, so the approved replacement lands on
        // the item the guard saw and on nothing else.
        let into = try destinationDescriptor ?? filaOpenDirectory(directory)
        defer { if destinationDescriptor == nil { close(into) } }
        func discard() throws {
            guard destinationDescriptor != nil else {
                return try operations.discardTemporary(temporary)
            }
            // A merge parent can have moved during a copyfile callback. Find
            // our temporary through the held descriptor, not a replacement link.
            var info = stat()
            guard fstatat(into, temporaryName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                guard Darwin.errno == ENOENT else { throw FilaFailure(errno: Darwin.errno, path: target) }
                return
            }
            if info.st_mode & S_IFMT != S_IFDIR {
                if info.st_nlink == 1, info.st_flags != 0 {
                    try filaSetFlags(0, of: temporaryName, in: into, path: target)
                }
                try filaCheck(target) { unlinkat(into, temporaryName, 0) }
                return
            }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            try filaCheck(target) { fcntl(into, F_GETPATH, &buffer) }
            let current = String(cString: buffer)
            try verifyDirectory(current, descriptor: into)
            try operations.discardTemporary(FilaPath.join(current, temporaryName))
        }
        do {
            try validatePublication()
            // A file or a link is cloned whole: instant on APFS, no space. A
            // plain clone drops the source's ACLs, so CLONE_ACL asks for them;
            // a kernel older than that flag refuses it with EINVAL, and gets
            // the clone it always made. A folder is not: cloned whole, the
            // kernel keeps CLONE_ACL for its root alone, and every ACL inside
            // would be lost (and, measured as an ordinary user, every setuid
            // bit). So a folder goes to copyfile, which clones file by file
            // where it can — still no space, now a moment per item. The
            // source is read by path: reading is not what the guard decides,
            // and its folder may allow search but not listing.
            func cloneWhole() -> Bool {
                if clonefileat(AT_FDCWD, source, into, temporaryName, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0 {
                    return true
                }
                return Darwin.errno == EINVAL
                    && clonefileat(AT_FDCWD, source, into, temporaryName, UInt32(CLONE_NOFOLLOW)) == 0
            }
            var sourceMetadata = stat()
            let sourceKnown = lstat(source, &sourceMetadata) == 0
            let isFolder = sourceKnown && sourceMetadata.st_mode & S_IFMT == S_IFDIR
            var cloned = !isFolder && cloneWhole()
            if cloned, sourceKnown {
                // clonefile(2) clears setuid and setgid on a file too.
                try filaRestoreSetID(of: temporaryName, in: into, path: temporary, source: sourceMetadata)
            }
            if !cloned {
                // copyfile(3) has no descriptor form for a tree, so this walks
                // the temporary's path. If that path no longer reaches the
                // held folder, the copy lands somewhere else, the lookup below
                // finds nothing under the temporary's name, and nothing is
                // published.
                do {
                    try copyTree(source, to: temporary, tally: tally)
                } catch let failure as FilaFailure where isFolder && failure.systemError == ENOTSUP {
                    // A named pipe, a socket or a device inside: copyfile can
                    // neither clone nor copy one, and a whole-folder clone
                    // can. That folder gives up its inner ACLs and setuid bits
                    // so that those nodes are copied at all. Across volumes
                    // the clone fails too, and such a folder cannot be copied.
                    if isCancelled {
                        throw FilaFailure(code: .cancelled, path: source)
                    }
                    try discard()
                    cloned = cloneWhole()
                    guard cloned else { throw failure }
                    tally.forgetFailure()
                }
            }
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: source)
            }
            // Like AtomicReplace, defer flags that would prohibit the publication
            // rename until the new item has reached its final name.
            var metadata = stat()
            try filaCheck(temporary) { fstatat(into, temporaryName, &metadata, AT_SYMLINK_NOFOLLOW) }
            let immovable = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
            if metadata.st_flags & immovable != 0 {
                try operations.requireUnshared(metadata, path: temporary)
                try filaSetFlags(metadata.st_flags & ~immovable, of: temporaryName, in: into, path: temporary)
            }
            try prepare(temporary)
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: source)
            }
            try validatePublication()
            try filaCheck(target) {
                renameatx_np(into, temporaryName, into, targetName, overwrite ? 0 : UInt32(RENAME_EXCL))
            }
            if metadata.st_flags & immovable != 0 {
                try filaSetFlags(metadata.st_flags, of: targetName, in: into, path: target)
            }
            if cloned {
                tally.finishedItem()
            }
        } catch var failure as FilaFailure {
            try discard()
            // The temporary is this job's own hidden name; the user chose the
            // target, and a failure about the destination names that.
            if let path = failure.path {
                failure.path = filaReplacingPrefix(temporary, with: target, in: path)
            }
            throw failure
        } catch {
            try discard()
            throw error
        }
    }

    private func move(_ source: String, to target: String, overwrite: Bool, tally: JobTally) throws {
        // Both ends relative to their parents, opened again now: an ancestor
        // swapped for a link since the guard decided cannot redirect it.
        let failure = try filaRename(source, to: target, flags: overwrite ? 0 : UInt32(RENAME_EXCL))
        if failure == 0 {
            tally.finishedItem()
            return
        }
        guard failure == EXDEV else { throw FilaFailure(errno: failure, path: target) }
        // Across volumes publish the complete copy before removing the source.
        try copy(source, to: target, overwrite: overwrite, tally: tally)
        if isCancelled {
            throw FilaFailure(code: .cancelled, path: source)
        }
        try removeTree(source, tally: tally)
    }

    private func delete(_ source: String, tally: JobTally) throws {
        guard request.useTrash else { return try removeTree(source, tally: tally) }
        try moveIntoTrash(source, at: trashDirectory(for: source), tally: tally)
    }

    // MARK: - libSystem

    private func copyTree(_ source: String, to target: String, tally: JobTally) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(filaCopyProgress, to: UnsafeRawPointer.self),
        )
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(tally).toOpaque())
        // Same volume: every file will be a clone, so only bytes copyfile
        // actually writes, where a clone falls back, meet the space reserve.
        var from = stat()
        var onto = stat()
        tally.clonesInPlace = lstat(source, &from) == 0 && stat(FilaPath.directory(of: target), &onto) == 0
            && from.st_dev == onto.st_dev
        defer { tally.clonesInPlace = false }

        // COPYFILE_ALL is what carries xattrs, ACLs, resource forks and BSD
        // flags across. COPYFILE_NOFOLLOW is the rule the whole project keeps:
        // copying a link copies the link, and a link at the destination is
        // replaced rather than written through. COPYFILE_RECURSIVE is set even
        // for a single file, so the per-item callbacks that drive progress fire
        // in both cases. COPYFILE_DATA_SPARSE keeps holes as holes — without it
        // a 20 GB disk image holding 200 MB is written out in full — and falls
        // back to a plain copy where either side cannot hold one.
        // COPYFILE_CLONE clones each file where both ends share a volume and
        // copies it where they do not; the progress callback gives a clone
        // back the setuid and setgid bits cloning leaves off.
        let flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_DATA_SPARSE
            | COPYFILE_CLONE
        let result = copyfile(source, target, state, copyfile_flags_t(flags))
        // What the callback saw comes first: it stopped the walk deliberately,
        // and the errno a quit leaves behind says nothing useful — from a
        // recursion stage it is 0, which would read as a failure with no reason.
        if let failure = tally.failure {
            throw failure
        }
        guard result == 0 else {
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: source)
            }
            let code = Darwin.errno
            throw FilaFailure(errno: code, path: filaFailsWriting(code) ? target : source)
        }
    }

    private func removeTree(_ source: String, tally: JobTally) throws {
        let state = removefile_state_alloc()
        defer { removefile_state_free(state) }
        removefile_state_set(
            state,
            UInt32(REMOVEFILE_STATE_CONFIRM_CALLBACK),
            unsafeBitCast(filaRemoveProgress, to: UnsafeRawPointer.self),
        )
        removefile_state_set(
            state,
            UInt32(REMOVEFILE_STATE_CONFIRM_CONTEXT),
            Unmanaged.passUnretained(tally).toOpaque(),
        )
        try DeletionQuarantine.remove(source, operations: operations, isCancelled: { self.isCancelled }) { staged in
            tally.removalPath = (staged, source)
            defer { tally.removalPath = nil }
            let result = removefile(staged, state, removefile_flags_t(REMOVEFILE_RECURSIVE))
            let code = Darwin.errno
            if result != 0 {
                if code == ECANCELED, isCancelled { throw FilaFailure(code: .cancelled, path: source) }
                throw FilaFailure(errno: code, path: source)
            }
            if isCancelled { throw FilaFailure(code: .cancelled, path: source) }
        }
    }

    // MARK: - Trash

    /// A relocated backend keeps its trash under its bootstrap, even when
    /// that bootstrap is on Preboot and the source is on a data volume.
    private func trashDirectory(for path: String) throws -> String {
        // The *directory* the item is in, not the item: `statfs` follows
        // symlinks, and a dangling one — a normal thing to want to delete —
        // would fail here with ENOENT, while a live one would name the volume
        // it points at and lose the rename to EXDEV.
        var volume = statfs()
        let container = FilaPath.directory(of: path)
        guard statfs(container, &volume) == 0 else { throw FilaFailure(errno: Darwin.errno, path: container) }
        let base = try operations.trashBase(volumeMountPoint: filaText(volume.f_mntonname))
        let trash = try operations.resolveForWrite(FilaTrash.directory(under: base))
        if mkdir(trash, 0o700) != 0 {
            guard Darwin.errno == EEXIST else { throw FilaFailure(errno: Darwin.errno, path: trash) }
        }
        // A pre-existing link is not a trash directory. Never follow it while
        // publishing the renamed item.
        var metadata = stat()
        try filaCheck(trash) { lstat(trash, &metadata) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw FilaFailure(errno: ENOTDIR, path: trash)
        }
        return trash
    }

    /// Exclusive publication keeps both items when two deletions share a name.
    /// Cross-volume copies carry their recovery record before the source is removed.
    private func moveIntoTrash(_ source: String, at directory: String, tally: JobTally) throws {
        guard source != directory, !FilaGuard.isAncestor(source, of: directory) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: source)
        }
        let name = FilaPath.name(of: source)
        // The rename goes between the two parents, opened again now: an
        // ancestor swapped for a link since the guard decided cannot send a
        // protected node into the trash in the source's place.
        let from = try filaOpenDirectory(FilaPath.directory(of: source))
        defer { close(from) }
        let into = try filaOpenDirectory(directory)
        defer { close(into) }
        for suffix in 0 ..< 1000 {
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: source)
            }
            let trashName = FilaTrash.itemName(name, suffix: suffix)
            let candidate = try operations.resolveForWrite(FilaPath.join(directory, trashName))
            if renameatx_np(from, name, into, trashName, UInt32(RENAME_EXCL)) == 0 {
                // A same-volume rename already preserved the item. Files with
                // shared inodes or unsupported xattrs remain recoverable by hand.
                try? recordOrigin(source, on: candidate, keepingExisting: FilaPath.directory(of: source) == directory)
                tally.finishedItem()
                return
            }
            let failure = Darwin.errno
            if failure == EEXIST {
                continue
            }
            guard failure == EXDEV else { throw FilaFailure(errno: failure, path: candidate) }
            // EXDEV may precede the kernel's collision check. Avoid recopying
            // a large tree for every occupied suffix; publication still uses EXCL.
            var existing = stat()
            if fstatat(into, trashName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                continue
            }
            guard Darwin.errno == ENOENT else { throw FilaFailure(errno: Darwin.errno, path: candidate) }
            do {
                try copy(source, to: candidate, overwrite: false, tally: tally) { temporary in
                    try self.recordOrigin(source, on: temporary, keepingExisting: false)
                }
            } catch let error as FilaFailure where error.systemError == EEXIST {
                continue
            }
            // If cancellation or removal fails, retain the complete, recorded
            // trash copy. Never roll it back after source removal has begun.
            if isCancelled {
                throw FilaFailure(code: .cancelled, path: source)
            }
            try removeTree(source, tally: tally)
            return
        }
        throw FilaFailure(code: .operationFailed, systemError: EEXIST, path: FilaPath.join(directory, name))
    }

    private func recordOrigin(_ source: String, on trashed: String, keepingExisting: Bool) throws {
        var metadata = stat()
        try filaCheck(trashed) { lstat(trashed, &metadata) }
        guard metadata.st_mode & S_IFMT == S_IFDIR || metadata.st_nlink == 1 else {
            throw FilaFailure(errno: EMLINK, path: trashed)
        }
        if keepingExisting {
            return
        }
        try operations.setAttributes(
            AttributeChange(extendedAttribute: (FilaTrash.originAttribute, Data(source.utf8))),
            at: trashed,
        )
        if let identity = request.trashID {
            try operations.setAttributes(
                AttributeChange(extendedAttribute: (FilaTrash.jobAttribute, Data(identity.uuidString.utf8))),
                at: trashed,
            )
        } else {
            _ = try? operations.setAttributes(
                AttributeChange(extendedAttribute: (FilaTrash.jobAttribute, nil)),
                at: trashed,
            )
        }
    }

    /// Origins are untrusted path metadata. Resolve them and apply the same
    /// write boundary as a move; never overwrite a newly occupied original name.
    private func restoreTarget(for source: String) throws -> String {
        var volume = statfs()
        let parent = FilaPath.directory(of: source)
        try filaCheck(parent) { statfs(parent, &volume) }
        let base = try operations.trashBase(volumeMountPoint: filaText(volume.f_mntonname))
        let directory = try operations.resolveForWrite(FilaTrash.directory(under: base))
        guard parent == directory else { throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: source) }
        if let identity = request.trashID {
            let recorded = try operations.extendedAttribute(FilaTrash.jobAttribute, at: source)
            guard recorded == Data(identity.uuidString.utf8) else { throw FilaFailure(code: .notFound, path: source) }
        }
        let data = try operations.extendedAttribute(FilaTrash.originAttribute, at: source)
        guard let origin = String(data: data, encoding: .utf8), origin.utf8.first == UInt8(ascii: "/") else {
            throw FilaFailure(errno: ENOATTR, path: source)
        }
        let target = try operations.resolveForWrite(origin)
        guard target != directory, !FilaGuard.isAncestor(directory, of: target),
              !FilaGuard.isAncestor(source, of: target)
        else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL, path: target)
        }
        var metadata = stat()
        if lstat(target, &metadata) == 0 {
            throw FilaFailure(errno: EEXIST, path: target)
        }
        guard Darwin.errno == ENOENT else { throw FilaFailure(errno: Darwin.errno, path: target) }
        return target
    }

    private func clearTrashRecord(at path: String) {
        for name in [FilaTrash.originAttribute, FilaTrash.jobAttribute] {
            _ = try? operations.setAttributes(AttributeChange(extendedAttribute: (name, nil)), at: path)
        }
    }
}

/// `path` with `prefix` — itself, or a directory above it — spelled as
/// `replacement` instead; any other path unchanged. Compared over UTF-8, as
/// the kernel splits paths.
func filaReplacingPrefix(_ prefix: String, with replacement: String, in path: String) -> String {
    if path == prefix {
        return replacement
    }
    let head = Array((prefix + "/").utf8)
    let bytes = Array(path.utf8)
    guard bytes.starts(with: head) else { return path }
    return replacement + "/" + String(decoding: bytes[head.count...], as: UTF8.self)
}

/// Whether two paths sit on one device — which is to say whether a move is a
/// `renameat(2)` or a copy followed by a delete.
func filaSameVolume(_ first: String, _ second: String) -> Bool {
    var one = stat()
    var other = stat()
    guard lstat(first, &one) == 0, lstat(second, &other) == 0 else { return false }
    return one.st_dev == other.st_dev
}
