import Darwin
import FilaClient
import FilaProtocol
import Foundation
import Testing

/// The public async interface, not a direct call into the filesystem layer.
/// These tests do not exercise XPC or WebKit; those still need a built DEB.
@Suite("Preview capability through LocalFileAccess")
struct PreviewAccessTests {
    let scratch = LocalScratch()

    @Test
    func `Internal pages have their own details without changing the directory capability`() async throws {
        scratch.directory("root/pages")
        scratch.file("root/index.html", contents: "first")
        scratch.file("root/pages/second.htm", contents: "second")
        let link: any LocalFileAccess = LocalFileService()
        let root = try await link.openPreviewDirectory(scratch.path("root"))
        defer { close(root) }
        let first = try await link.openPreviewResource(root: root, relativePath: "index.html")
        defer { close(first.descriptor) }
        let second = try await link.openPreviewResource(root: root, relativePath: "pages/second.htm")
        defer { close(second.descriptor) }
        #expect(first.details.path == scratch.path("root/index.html"))
        #expect(second.details.path == scratch.path("root/pages/second.htm"))
        #expect(second.details.node.name == "second.htm")
        #expect(second.details.node.inode != first.details.node.inode)
        var status = stat()
        #expect(fstat(second.descriptor, &status) == 0)
        #expect(second.details.node.inode == UInt64(status.st_ino))
        #expect(second.details.node.size == Int64(status.st_size))
        #expect(fcntl(root, F_GETFD) >= 0)
    }

    @Test
    func `Public directory capture refuses a replaced ancestor`() async throws {
        scratch.directory("visible/root")
        scratch.file("visible/root/index.html", contents: "inside")
        scratch.directory("outside/root")
        scratch.file("outside/root/index.html", contents: "outside")
        let link: any LocalFileAccess = LocalFileService()
        let listed = try await link.details(of: scratch.path("visible/root/index.html"))
        #expect(rename(scratch.path("visible"), scratch.path("moved")) == 0)
        #expect(symlink(scratch.path("outside"), scratch.path("visible")) == 0)
        let failure = await #expect(throws: FilaFailure.self) {
            let fd = try await link.openPreviewDirectory((listed.path as NSString).deletingLastPathComponent)
            close(fd)
        }
        #expect(failure?.systemError == ELOOP)
    }

    @Test
    func `Cancellation still hands an opened descriptor back to its caller to close`() async throws {
        scratch.directory("root")
        scratch.file("root/index.html", contents: "owned")
        let link: any LocalFileAccess = LocalFileService()
        let root = try await link.openPreviewDirectory(scratch.path("root"))
        defer { close(root) }
        let opening = Task {
            try await link.openPreviewResource(root: root, relativePath: "index.html")
        }
        opening.cancel()
        // LocalFileService's checked continuation completes once even if its
        // caller was cancelled. The app must discard/close that owned result.
        let resource = try await opening.value
        #expect(fcntl(resource.descriptor, F_GETFD) >= 0)
        #expect(close(resource.descriptor) == 0)
        #expect(fcntl(root, F_GETFD) >= 0)
    }

    @Test
    func `Resource lifetime does not borrow the directory after completion`() async throws {
        scratch.directory("root")
        scratch.file("root/index.html", contents: "owned")
        let link: any LocalFileAccess = LocalFileService()
        let resource = try await openAndReleaseDirectory(link)
        defer { close(resource.descriptor) }
        var bytes = [UInt8](repeating: 0, count: 5)
        #expect(pread(resource.descriptor, &bytes, bytes.count, 0) == 5)
        #expect(String(decoding: bytes, as: UTF8.self) == "owned")
    }

    private func openAndReleaseDirectory(_ link: any LocalFileAccess) async throws -> (descriptor: Int32, details: FileDetails) {
        let root = try await link.openPreviewDirectory(scratch.path("root"))
        defer { close(root) }
        return try await link.openPreviewResource(root: root, relativePath: "index.html")
    }

    @Test
    func `Errors retain errno and do not close the borrowed directory`() async throws {
        let link: any LocalFileAccess = LocalFileService()
        let root = try await link.openPreviewDirectory(scratch.root)
        defer { close(root) }
        let missing = await #expect(throws: FilaFailure.self) {
            let result = try await link.openPreviewResource(root: root, relativePath: "missing.html")
            close(result.descriptor)
        }
        #expect(missing?.systemError == ENOENT)
        let escaped = await #expect(throws: FilaFailure.self) {
            let result = try await link.openPreviewResource(root: root, relativePath: "../outside.html")
            close(result.descriptor)
        }
        #expect(escaped?.systemError == EINVAL)
        #expect(fcntl(root, F_GETFD) >= 0)
    }
}
