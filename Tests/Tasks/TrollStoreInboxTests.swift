import Darwin
import FilaClient
import FilaProtocol
import Foundation
import Testing

struct TrollStoreInboxTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test
    func documentsSymlinkIsRefusedBeforeCreatingAnythingInItsTarget() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("receiver"), outside = root.appendingPathComponent("other-app")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try #require(symlink(outside.path, container.appendingPathComponent("Documents").path) == 0)
        await #expect(throws: FilaFailure.self) {
            try await TrollStoreInbox.prepare(dataPath: container.path, access: LocalFileService())
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("Inbox").path))
    }

    @Test
    func createsAnInboxForTheReceiverWithoutChangingExistingPermissions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let access = LocalFileService()
        let inbox = try await TrollStoreInbox.prepare(dataPath: root.path, access: access)
        let first = try await access.details(of: inbox)
        #expect(first.node.ownerID == getuid())
        #expect(first.node.mode & 0o777 == 0o700)
        try #require(chmod(inbox, 0o750) == 0)
        #expect(try await TrollStoreInbox.prepare(dataPath: root.path, access: access) == inbox)
        #expect(try await access.details(of: inbox).node.mode & 0o777 == 0o750)
    }
}
