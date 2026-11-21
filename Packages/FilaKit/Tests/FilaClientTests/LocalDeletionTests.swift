import Darwin
import FilaBackendKit
@testable import FilaClient
import FilaProtocol
import Foundation
import Testing

@Suite("In-process deletion without trash")
@MainActor
struct LocalDeletionTests {
    @Test(arguments: [LocalReach.user, .container])
    func `Neither in-process reach offers trash even when its preset was enabled`(_ reach: LocalReach) throws {
        let scratch = LocalScratch()
        let backend = LocalFileBackend(
            access: LocalFileService(), rootPath: scratch.root,
            displayName: "Scratch", artworkName: "folder", storage: MemoryStorage(),
            environment: .init(trashVolume: scratch.root), defaultFavorites: [],
        )
        try backend.setPreset(.trash, enabled: true)
        backend.handshakeLanded(LocalHello(protocolVersion: FilaProtocol.version, backend: .local(reach: reach)))
        #expect(!backend.offersPreset(.trash))
        #expect(!backend.sidebar().places.contains { $0.kind == .trash })
        #expect(backend.trashDirectory(backend: .local(reach: reach)) == nil)
        #expect(backend.trashDirectory(backend: .local(reach: reach), volumeMountPoint: "/another-volume") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root).isEmpty)
    }

    @Test
    func `An old trash request is refused without turning it into a permanent delete`() async throws {
        let scratch = LocalScratch()
        let source = scratch.file("payload", contents: "keep bytes")
        let service = LocalFileService()
        let failure = await #expect(throws: FilaFailure.self) {
            _ = try await service.startJob(JobRequest(kind: .delete, sources: [source], useTrash: true))
        }
        #expect(failure?.systemError == ENOTSUP)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "keep bytes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["payload"])
    }

    @Test
    func `Existing private trash contents remain accessible and are never migrated or purged`() async throws {
        let scratch = LocalScratch()
        let oldTrash = scratch.directory("Application Support/wiki.qaq.fila/Trash/.fila-trash")
        let source = scratch.file("Application Support/wiki.qaq.fila/Trash/.fila-trash/payload", contents: "recover by hand")
        let service = LocalFileService()
        let hello = try await service.hello()
        #expect(!hello.isPrivileged)
        #expect(try await service.list(directory: oldTrash).entries.map(\.name) == ["payload"])
        let failure = await #expect(throws: FilaFailure.self) {
            _ = try await service.startJob(JobRequest(kind: .restore, sources: [source]))
        }
        #expect(failure?.systemError == ENOTSUP)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "recover by hand")
    }

    @Test(arguments: ["file", "tree", "link"])
    func `Explicit permanent deletion still runs and leaves other data alone`(_ kind: String) async throws {
        let scratch = LocalScratch()
        let parent = scratch.directory("parent")
        let keep = scratch.file("keep", contents: "untouched")
        let source: String
        if kind == "tree" {
            source = scratch.directory("parent/selected")
            scratch.file("parent/selected/inside")
        } else if kind == "link" {
            source = scratch.path("parent/selected")
            try #require(symlink(keep, source) == 0)
        } else {
            source = scratch.file("parent/selected")
        }
        try #require(chmod(parent, 0o777) == 0)
        let service = LocalFileService()
        let outcome = try await run(JobRequest(kind: .delete, sources: [source], useTrash: false), on: service)
        #expect(outcome.code == .success)
        #expect(!exists(source))
        #expect(try String(contentsOfFile: keep, encoding: .utf8) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent).isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: scratch.root)) == ["parent", "keep"])
    }

    @Test
    func `Daemon trash paths retain rootful and relocated layouts`() {
        #expect(LocalFileBackend.trashDirectory(backend: .daemon(installRoot: "/bootstrap"), volume: "/volume") == "/bootstrap/.fila-trash")
        #expect(LocalFileBackend.trashDirectory(backend: .daemon(installRoot: ""), volume: "/volume") == "/volume/.fila-trash")
    }

    private func run(_ request: JobRequest, on service: LocalFileService) async throws -> FilaFailure {
        let identifier = try await service.startJob(request)
        for await update in service.jobEvents where update.identifier == identifier {
            if case let .completed(outcome, _) = update.event { return outcome }
        }
        throw FilaFailure(errno: EIO)
    }
}
