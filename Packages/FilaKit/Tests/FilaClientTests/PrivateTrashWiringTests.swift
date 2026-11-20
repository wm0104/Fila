import Darwin
import FilaBackendKit
@testable import FilaClient
import FilaProtocol
import Foundation
import Testing

@Suite("Private local trash wiring")
@MainActor
struct PrivateTrashWiringTests {
    @Test(.enabled(if: LocalFileService.processReach == .user))
    func `Service sidebar and undo lookup use the same private trash without unhiding presets`() async throws {
        let scratch = LocalScratch()
        let base = scratch.path("support/private")
        let service = LocalFileService(privateTrashBase: base)
        let backend = LocalFileBackend(
            access: service, rootPath: scratch.root, displayName: "Scratch", artworkName: "folder",
            storage: MemoryStorage(),
            environment: .init(trashVolume: scratch.root, privateTrashBase: base), defaultFavorites: [],
        )
        let hello = try await service.hello()
        backend.handshakeLanded(hello)
        let directory = backend.trashDirectory(backend: hello.backend)
        #expect(directory == FilaTrash.directory(under: base))
        #expect(backend.trashDirectory(backend: hello.backend, volumeMountPoint: "/another-volume") == directory)
        #expect(backend.sidebar().places.first { $0.kind == .trash }?.path?.description == "support/private/.fila-trash")
        #expect(!FileManager.default.fileExists(atPath: base), "Handshake and sidebar do not create the trash")
        try backend.setPreset(.trash, enabled: false)
        backend.handshakeLanded(hello)
        #expect(backend.offersPreset(.trash))
        #expect(!backend.sidebar().places.contains { $0.kind == .trash })

        let source = scratch.file("payload", contents: "original")
        let identity = UUID()
        let trashed = directory + "/payload"
        let outcome = try await run(JobRequest(kind: .delete, sources: [source], useTrash: true, trashID: identity), on: service)
        #expect(outcome.code == .success)
        #expect(try await service.extendedAttribute(FilaTrash.originAttribute, at: trashed) == Data(source.utf8))
        #expect(try await service.extendedAttribute(FilaTrash.jobAttribute, at: trashed) == Data(identity.uuidString.utf8))
        #expect(try await run(JobRequest(kind: .restore, sources: [trashed], trashID: identity), on: service).code == .success)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "original")
        #expect(try await run(JobRequest(kind: .delete, sources: [source], useTrash: true), on: service).code == .success)
        #expect(try await run(JobRequest(kind: .delete, sources: [trashed]), on: service).code == .success)
        #expect(try await service.list(directory: directory).entries.isEmpty)
    }

    @Test
    func `Daemon paths and container places ignore the user trash configuration`() {
        let scratch = LocalScratch()
        let backend = LocalFileBackend(
            access: LocalFileService(privateTrashBase: nil), rootPath: scratch.root,
            displayName: "Scratch", artworkName: "folder", storage: MemoryStorage(),
            environment: .init(trashVolume: scratch.root, privateTrashBase: scratch.path("private")), defaultFavorites: [],
        )
        #expect(backend.trashDirectory(backend: .daemon(installRoot: "/bootstrap")) == "/bootstrap/.fila-trash")
        #expect(backend.trashDirectory(backend: .daemon(installRoot: ""), volumeMountPoint: "/volume") == "/volume/.fila-trash")
        #expect(backend.availablePlaces(backend: .local(reach: .container))[.trash] == nil)
        #expect(LocalFileBackend.Environment().privateTrashBase == LocalFileService.privateTrashBase)
        if LocalFileService.processReach == .container { #expect(LocalFileService.privateTrashBase == nil) }
    }

    private func run(_ request: JobRequest, on service: LocalFileService) async throws -> FilaFailure {
        let identifier = try await service.startJob(request)
        for await update in service.jobEvents where update.identifier == identifier {
            if case let .completed(outcome, _) = update.event { return outcome }
        }
        throw FilaFailure(errno: EIO)
    }
}
