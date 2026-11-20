import Darwin
import FilaClient
import FilaProtocol
import Foundation
import Testing

struct TrollStoreInboxTests {
    @Test(arguments: ["package.deb", "package.DEB", "空 格.DeB"])
    func sileoOffersOnlyOptedInRegularDebs(_ name: String) {
        #expect(SileoOpenPolicy.offers(path: "/tmp/" + name, kind: .regular, info: ["FilaOffersSileoOpen": true]))
        #expect(!SileoOpenPolicy.offers(path: "/tmp/" + name, kind: .directory, info: ["FilaOffersSileoOpen": true]))
        #expect(!SileoOpenPolicy.offers(path: "/tmp/" + name, kind: .symbolicLink, info: ["FilaOffersSileoOpen": true]))
        #expect(!SileoOpenPolicy.offers(path: "/tmp/" + name, kind: .regular, info: [:]))
    }

    @Test
    func sileoRequiresAnActualBooleanTrue() {
        let values: [Any] = [false, "true", "YES", 1, 0, NSNumber(value: 1)]
        for value in values {
            #expect(!SileoOpenPolicy.offers(path: "/tmp/package.deb", kind: .regular, info: ["FilaOffersSileoOpen": value]))
        }
    }

    @Test(arguments: ["app.ipa", "app.tipa", "package.deb.txt", "folder", "archive.zip"])
    func sileoDoesNotOfferOtherFormats(_ name: String) {
        #expect(!SileoOpenPolicy.offers(path: "/tmp/" + name, kind: .regular, info: ["FilaOffersSileoOpen": true]))
    }

    @Test
    func receiverContainerSymlinkIsRefused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try #require(symlink(real.path, link.path) == 0)
        await #expect(throws: FilaFailure.self) {
            try await ApplicationDocumentInbox.prepare(dataPath: link.path, access: LocalFileService())
        }
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("Documents/Inbox").path))
    }

    @Test
    func receiverInboxSymlinkIsRefusedWithoutRemovingItsTarget() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let original = outside.appendingPathComponent("keep.deb")
        try Data("original".utf8).write(to: original)
        try #require(symlink(outside.path, documents.appendingPathComponent("Inbox").path) == 0)
        await #expect(throws: FilaFailure.self) {
            try await ApplicationDocumentInbox.prepare(dataPath: root.path, access: LocalFileService())
        }
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

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
