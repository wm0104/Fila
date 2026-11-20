import Darwin
import FilaProtocol
import Foundation

/// Detaches the selected name before a path-based system tree removal.
/// A private wrapper alone is not enough: every ancestor must keep its name.
enum DeletionQuarantine {
    static func remove(
        _ source: String,
        operations: FileOperations,
        isCancelled: () -> Bool,
        body: (String) throws -> Void,
    ) throws {
        let parent = try filaOpenDirectory(FilaPath.directory(of: source))
        defer { close(parent) }
        var volume = statfs(), metadata = stat()
        try filaCheck(source) { fstatfs(parent, &volume) }
        try filaCheck(source) { fstat(parent, &metadata) }
        let mount = try FilaPath.resolve(filaText(volume.f_mntonname))
        let boundary = try operations.writableRoot.map { try FilaPath.resolve($0) }
        var ancestor = FilaPath.directory(of: source)
        if let boundary {
            guard ancestor == boundary || FilaGuard.isAncestor(boundary, of: ancestor) else {
                throw FilaFailure(errno: EROFS, path: source)
            }
        }
        var candidates = [try operations.trashBase(volumeMountPoint: mount)]
        if boundary == nil { candidates.append(mount) }
        // A writable parent cannot hold the wrapper, but a trusted ancestor can.
        while true {
            candidates.append(ancestor)
            if ancestor == (boundary ?? "/") { break }
            ancestor = FilaPath.directory(of: ancestor)
        }

        var anchor = -Int32(1)
        var base = ""
        for candidate in candidates {
            let path = try FilaPath.resolve(candidate)
            guard source != path, !FilaGuard.isAncestor(source, of: path),
                  let descriptor = try? controlledDirectory(path) else { continue }
            var info = stat(), fs = statfs()
            if fstat(descriptor, &info) == 0, info.st_dev == metadata.st_dev,
               fstatfs(descriptor, &fs) == 0, fs.f_flags & UInt32(MNT_IGNORE_OWNERSHIP | MNT_RDONLY) == 0,
               faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0 {
                anchor = descriptor
                base = path
                break
            }
            close(descriptor)
        }
        guard anchor >= 0 else { throw FilaFailure(errno: EACCES, path: source) }
        defer { close(anchor) }
        let name = ".fila-delete-" + UUID().uuidString
        let wrapper = try operations.resolveForWrite(FilaPath.join(base, name))
        try filaCheck(wrapper) { mkdirat(anchor, name, 0o700) }
        let directory = openat(anchor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            let code = errno
            _ = unlinkat(anchor, name, AT_REMOVEDIR)
            throw FilaFailure(errno: code, path: wrapper)
        }
        defer { close(directory) }
        let payload = FilaPath.join(wrapper, "payload")
        var detached = false
        do {
            var info = stat()
            try filaCheck(wrapper) { fstat(directory, &info) }
            guard info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700,
                  hasNoACL(directory) else { throw FilaFailure(errno: EACCES, path: wrapper) }
            // Recovery metadata belongs to our wrapper, never to a shared inode.
            try source.withCString { bytes in
                try filaCheck(wrapper) {
                    fsetxattr(directory, "wiki.qaq.fila.delete-origin", bytes, strlen(bytes), 0, 0)
                }
            }
            if isCancelled() { throw FilaFailure(code: .cancelled, path: source) }
            try filaCheck(source) {
                renameatx_np(parent, FilaPath.name(of: source), directory, "payload", UInt32(RENAME_EXCL))
            }
            detached = true
            if isCancelled() { throw FilaFailure(code: .cancelled, path: source) }
            try body(payload)
        } catch {
            let failure = error
            if detached {
                var remaining = stat()
                if fstatat(directory, "payload", &remaining, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard renameatx_np(directory, "payload", parent, FilaPath.name(of: source), UInt32(RENAME_EXCL)) == 0 else {
                        // Do not retry deletion, overwrite the new occupant, or
                        // recursively clean the only remaining copy of the data.
                        throw FilaFailure(errno: errno, path: payload)
                    }
                } else if errno != ENOENT {
                    throw FilaFailure(errno: errno, path: payload)
                }
            }
            try filaCheck(wrapper) { unlinkat(anchor, name, AT_REMOVEDIR) }
            throw failure
        }
        try filaCheck(wrapper) { unlinkat(anchor, name, AT_REMOVEDIR) }
    }

    /// Root and this backend's uid are trusted. A sticky writable ancestor
    /// protects a trusted child's name (not an arbitrary other user's child).
    private static func controlledDirectory(_ path: String) throws -> Int32 {
        var current = try filaOpenDirectory("/")
        do {
            let components = path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
            for component in [""] + components {
                if !component.isEmpty {
                    var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    let code = errno
                    if next < 0, code == EACCES {
                        next = openat(current, component, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard next >= 0 else { throw FilaFailure(errno: code, path: path) }
                    close(current)
                    current = next
                }
                var info = stat()
                try filaCheck(path) { fstat(current, &info) }
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0 || info.st_uid == geteuid(),
                      info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0,
                      hasNoACL(current) else { throw FilaFailure(errno: EACCES, path: path) }
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private static func hasNoACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOTSUP || errno == ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        return result == -1 && errno == EINVAL
    }
}
