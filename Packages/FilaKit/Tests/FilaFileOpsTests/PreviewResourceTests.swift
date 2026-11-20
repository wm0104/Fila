import Darwin
@testable import FilaFileOps
import FilaProtocol
import Foundation
import Testing

@Suite("Read-only preview directory capability")
struct PreviewResourceTests {
    let scratch = Scratch()
    let operations = FileOperations(bootstrapRoot: "")

    @Test
    func `Nested regular files open read-only and the root survives a rename`() throws {
        scratch.directory("root/assets")
        scratch.file("root/assets/中文.css", contents: "body{}")
        let root = try operations.openPreviewDirectory(scratch.path("root"))
        defer { close(root) }
        #expect(rename(scratch.path("root"), scratch.path("moved")) == 0)
        // A new link at the old spelling must not change the pinned root.
        scratch.directory("outside/assets")
        scratch.file("outside/assets/中文.css", contents: "outside")
        scratch.link("root", to: scratch.path("outside"))
        let resource = try operations.openPreviewResource(root: root, relativePath: "assets/中文.css")
        defer { close(resource.descriptor) }
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = read(resource.descriptor, &bytes, bytes.count)
        #expect(count == 6)
        #expect(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self) == "body{}")
        #expect(fcntl(resource.descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
        #expect(fcntl(resource.descriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(resource.details.path == scratch.path("moved/assets/中文.css"))
        #expect(resource.details.node.name == "中文.css")
        var metadata = stat()
        #expect(fstat(resource.descriptor, &metadata) == 0)
        #expect(resource.details.node.inode == UInt64(metadata.st_ino))
        #expect(resource.details.node.size == Int64(metadata.st_size))
    }

    @Test
    func `A listed ancestor replaced by a link is not recanonicalized at capture`() throws {
        scratch.directory("visible/root")
        scratch.file("visible/root/index.html", contents: "original")
        scratch.directory("outside/root")
        scratch.file("outside/root/index.html", contents: "outside")
        let listed = try operations.details(of: scratch.path("visible/root/index.html"))
        #expect(rename(scratch.path("visible"), scratch.path("moved")) == 0)
        scratch.link("visible", to: scratch.path("outside"))
        let failure = #expect(throws: FilaFailure.self) {
            let root = try operations.openPreviewDirectory((listed.path as NSString).deletingLastPathComponent)
            close(root)
        }
        #expect(failure?.systemError == ELOOP)
    }

    @Test(arguments: ["", "relative", "/a/../b", "/a/./b", "/a//b", "/a/", "/a\0b", "/a\nb"])
    func `Directory capture refuses noncanonical or truncated spellings`(_ path: String) {
        let failure = #expect(throws: FilaFailure.self) {
            let root = try operations.openPreviewDirectory(path)
            close(root)
        }
        #expect(failure?.systemError == EINVAL)
    }

    @Test(arguments: ["", "/etc/passwd", "../outside", "a/../outside", "./file", "a//b", "a/", "a\0b", "a\\b", "%2e%2e/outside", "%252e%252e/outside"])
    func `Unsafe relative spellings are refused`(_ name: String) throws {
        let root = try operations.openPreviewDirectory(scratch.root)
        defer { close(root) }
        let failure = #expect(throws: FilaFailure.self) {
            let resource = try operations.openPreviewResource(root: root, relativePath: name)
            close(resource.descriptor)
        }
        #expect(failure?.systemError == EINVAL)
    }

    @Test
    func `Final and intermediate symlinks, directories and FIFOs are refused`() throws {
        scratch.directory("root/subdirectory")
        scratch.directory("outside")
        scratch.file("outside/secret")
        scratch.link("root/link", to: scratch.path("outside/secret"))
        scratch.link("root/dir", to: scratch.path("outside"))
        #expect(mkfifo(scratch.path("root/pipe"), 0o600) == 0)
        let root = try operations.openPreviewDirectory(scratch.path("root"))
        defer { close(root) }
        for name in ["link", "dir/secret", "pipe", "subdirectory"] {
            #expect(throws: (any Error).self) {
                let resource = try operations.openPreviewResource(root: root, relativePath: name)
                close(resource.descriptor)
            }
        }
        #expect(throws: (any Error).self) {
            let resource = try operations.openPreviewResource(root: root, relativePath: ".")
            close(resource.descriptor)
        }
    }

    @Test
    func `Invalid and non-directory capabilities fail closed`() throws {
        scratch.file("file")
        let file = try operations.open(scratch.path("file"), flags: O_RDONLY, mode: 0)
        defer { close(file) }
        for (root, code) in [(Int32(-1), EBADF), (file, ENOTDIR)] {
            let failure = #expect(throws: FilaFailure.self) {
                let resource = try operations.openPreviewResource(root: root, relativePath: "file")
                close(resource.descriptor)
            }
            #expect(failure?.systemError == code)
        }
    }

    @Test
    func `Resource errors preserve the borrowed root and expose their errno`() throws {
        scratch.directory("root")
        scratch.file("root/valid.html")
        let root = try operations.openPreviewDirectory(scratch.path("root"))
        defer { close(root) }
        for _ in 0 ..< 32 {
            let failure = #expect(throws: FilaFailure.self) {
                let resource = try operations.openPreviewResource(root: root, relativePath: "missing.html")
                close(resource.descriptor)
            }
            #expect(failure?.systemError == ENOENT)
        }
        #expect(fcntl(root, F_GETFD) >= 0)
        let valid = try operations.openPreviewResource(root: root, relativePath: "valid.html")
        close(valid.descriptor)
        #expect(fcntl(root, F_GETFD) >= 0)
    }

    @Test
    func `An opened document and its duplicate keep their inode after name replacement`() throws {
        scratch.directory("root")
        scratch.file("root/index.html", contents: "original")
        let root = try operations.openPreviewDirectory(scratch.path("root"))
        defer { close(root) }
        let document = try operations.openPreviewResource(root: root, relativePath: "index.html")
        defer { close(document.descriptor) }
        #expect(rename(scratch.path("root/index.html"), scratch.path("root/old.html")) == 0)
        scratch.file("root/index.html", contents: "replacement")
        let duplicate = dup(document.descriptor)
        #expect(duplicate >= 0)
        defer { if duplicate >= 0 { close(duplicate) } }
        var opened = stat()
        #expect(fstat(duplicate, &opened) == 0)
        #expect(document.details.node.inode == UInt64(opened.st_ino))
        #expect(document.details.node.inode != metadata(of: scratch.path("root/index.html")).map { UInt64($0.st_ino) })
        var bytes = [UInt8](repeating: 0, count: 8)
        #expect(pread(duplicate, &bytes, bytes.count, 0) == 8)
        #expect(String(decoding: bytes, as: UTF8.self) == "original")
    }
}
