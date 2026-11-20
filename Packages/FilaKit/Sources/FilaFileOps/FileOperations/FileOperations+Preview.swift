import Darwin
import FilaProtocol
import Foundation

public extension FileOperations {
    /// Capture the spelling already returned by a listing/details call. Do not
    /// canonicalize again: an ancestor may have become a symlink since then.
    /// All later resource opens borrow this descriptor, never the original path.
    func openPreviewDirectory(_ canonicalPath: String) throws -> Int32 {
        let bytes = canonicalPath.utf8
        guard bytes.first == 47, bytes.count < Int(PATH_MAX),
              !bytes.contains(where: { $0 < 32 || $0 == 127 }) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        if canonicalPath != "/" {
            let components = bytes.dropFirst().split(separator: 47, omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && !isPreviewDotComponent($0) }) else {
                throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
            }
        }
        return try filaOpenDirectory(canonicalPath)
    }

    /// A read-only regular resource beneath the pinned directory, with metadata
    /// from the very same descriptor. The caller owns the returned descriptor;
    /// no file bytes, persistent registry, flags or execution arguments enter here.
    func openPreviewResource(root: Int32, relativePath: String) throws -> (descriptor: Int32, details: FileDetails) {
        let bytes = relativePath.utf8
        guard !bytes.isEmpty, bytes.count < Int(PATH_MAX),
              !bytes.contains(where: { $0 < 32 || $0 == 127 || $0 == 37 || $0 == 92 }) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        let components = bytes.split(separator: 47, omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && !isPreviewDotComponent($0) }) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        var directory = stat()
        guard fstat(root, &directory) == 0 else { throw FilaFailure(errno: errno) }
        guard directory.st_mode & S_IFMT == S_IFDIR else { throw FilaFailure(errno: ENOTDIR) }
        // One kernel path walk from the capability. O_NONBLOCK prevents a FIFO
        // from wedging the control queue before its type can be refused.
        let descriptor = openat(root, relativePath, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw FilaFailure(errno: errno) }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw FilaFailure(errno: errno) }
            guard metadata.st_mode & S_IFMT == S_IFREG else { throw FilaFailure(errno: EINVAL) }
            let path = try previewResourcePath(root: root, directory: directory, relativePath: relativePath, metadata: metadata)
            let details = FileDetails(
                path: path,
                node: FileNode(name: FilaPath.name(of: path), metadata: metadata, at: root, named: relativePath),
                extendedAttributes: filaPreviewAttributes(descriptor),
                hasAccessControlList: filaPreviewHasACL(descriptor),
                isDestructionProtected: FilaGuard.isDestructionProtected(path, bootstrapRoot: bootstrapRoot),
            )
            return (descriptor, details)
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// File actions need a current physical name, not an old root string. Check
    /// the kernel's name without following links and compare device + inode;
    /// if a rename/replacement made it ambiguous, fail rather than retarget UI.
    private func previewResourcePath(root: Int32, directory: stat, relativePath: String, metadata: stat) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(root, F_GETPATH, &buffer) == 0 else { throw FilaFailure(errno: errno) }
        let rootPath = String(cString: buffer)
        let namedRoot = try openPreviewDirectory(rootPath)
        defer { close(namedRoot) }
        var currentRoot = stat()
        guard fstat(namedRoot, &currentRoot) == 0 else { throw FilaFailure(errno: errno) }
        guard currentRoot.st_dev == directory.st_dev, currentRoot.st_ino == directory.st_ino else {
            throw FilaFailure(errno: ESTALE)
        }
        let path = (rootPath == "/" ? "" : rootPath) + "/" + relativePath
        let namedFile = Darwin.open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard namedFile >= 0 else { throw FilaFailure(errno: errno) }
        defer { close(namedFile) }
        var currentFile = stat()
        guard fstat(namedFile, &currentFile) == 0 else { throw FilaFailure(errno: errno) }
        guard currentFile.st_dev == metadata.st_dev, currentFile.st_ino == metadata.st_ino else {
            throw FilaFailure(errno: ESTALE)
        }
        return path
    }
}

private func isPreviewDotComponent<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
    (bytes.count == 1 && bytes.first == 46) || (bytes.count == 2 && bytes.allSatisfy { $0 == 46 })
}

/// Extended-attribute names and sizes only, matching ordinary FileDetails. The
/// values, like file bytes, never pass through the daemon.
private func filaPreviewAttributes(_ descriptor: Int32) -> [ExtendedAttribute] {
    let size = flistxattr(descriptor, nil, 0, 0)
    guard size > 0 else { return [] }
    var names = [CChar](repeating: 0, count: size)
    let written = names.withUnsafeMutableBufferPointer { flistxattr(descriptor, $0.baseAddress, size, 0) }
    guard written > 0 else { return [] }
    var attributes: [ExtendedAttribute] = []
    var start = 0
    for index in 0 ..< written where names[index] == 0 {
        if index > start {
            let name = String(cString: Array(names[start ..< index]) + [0])
            attributes.append(.init(name: name, byteCount: Int64(max(0, fgetxattr(descriptor, name, nil, 0, 0, 0)))))
        }
        start = index + 1
    }
    return attributes
}

private func filaPreviewHasACL(_ descriptor: Int32) -> Bool {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return false }
    acl_free(UnsafeMutableRawPointer(acl))
    return true
}
