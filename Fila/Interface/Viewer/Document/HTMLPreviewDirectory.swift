import Darwin
import FilaClient
import FilaProtocol
import Foundation

/// The original directory is a session capability, never an authorization path.
/// Keeping it alive through an open prevents a cancelled caller from closing and
/// reusing its descriptor number before the backend has duplicated it.
final class HTMLPreviewDirectory {
    let descriptor: Int32
    private let link: any LocalFileAccess

    init(path: String, link: any LocalFileAccess) async throws {
        self.link = link
        let opened = try await link.openPreviewDirectory(path)
        var info = stat()
        guard fstat(opened, &info) == 0 else {
            let code = errno
            Darwin.close(opened)
            throw ViewerFailure.readFailed(code)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(opened)
            throw ViewerFailure.readFailed(ENOTDIR)
        }
        descriptor = opened
    }

    deinit { Darwin.close(descriptor) }

    func open(_ relativePath: String) async throws -> HTMLPreviewDocument {
        let resource = try await link.openPreviewResource(root: descriptor, relativePath: relativePath)
        withExtendedLifetime(self) {}
        let file = try DescriptorFile(descriptor: resource.descriptor)
        return HTMLPreviewDocument(relativePath: relativePath, file: file, details: resource.details)
    }
}

/// Bytes and menu metadata have one identity. In particular, sniffing the first
/// document must not open one inode and let WebKit reopen a replacement by name.
struct HTMLPreviewDocument {
    let relativePath: String
    let file: DescriptorFile
    let details: FileDetails
}

struct HTMLPreviewSource {
    let directory: HTMLPreviewDirectory
    let document: HTMLPreviewDocument

    static func capture(path: String, link: any LocalFileAccess) async throws -> HTMLPreviewSource {
        let directory = try await HTMLPreviewDirectory(path: (path as NSString).deletingLastPathComponent, link: link)
        let document = try await directory.open((path as NSString).lastPathComponent)
        return HTMLPreviewSource(directory: directory, document: document)
    }
}
