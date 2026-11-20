import Darwin
import FilaClient
import FilaProtocol
import Foundation

/// The receiver's Inbox is delivery storage, not Fila's temporary workspace.
enum TrollStoreInbox {
    static func prepare(dataPath: String, access: any LocalFileAccess) async throws -> String {
        let container = try await access.details(of: dataPath)
        guard container.node.kind == .directory, container.node.ownerID == getuid() else {
            throw FilaFailure(code: .notPermitted, systemError: EPERM, path: dataPath)
        }
        let documentsPath = URL(fileURLWithPath: container.path).appendingPathComponent("Documents", isDirectory: true).path
        let documents = try await access.details(of: documentsPath)
        guard documents.node.kind == .directory, documents.node.ownerID == getuid(), documents.path == documentsPath else {
            throw FilaFailure(code: .notPermitted, systemError: EPERM, path: documentsPath)
        }
        let inbox = URL(fileURLWithPath: documents.path).appendingPathComponent("Inbox", isDirectory: true).path
        var created = false
        do {
            try await access.create(.directory, at: inbox, mode: 0o700)
            created = true
        } catch let failure as FilaFailure where failure.systemError == EEXIST {}
        if created {
            do {
                _ = try await access.setAttributes(AttributeChange(ownerID: getuid(), groupID: getgid()), at: inbox)
            } catch {
                try? await access.remove(inbox, directory: true, overrideGuard: false)
                throw error
            }
        }
        let details = try await access.details(of: inbox)
        guard details.node.kind == .directory, details.node.ownerID == getuid(), details.path == inbox else {
            throw FilaFailure(code: .notPermitted, systemError: EPERM, path: inbox)
        }
        return details.path
    }
}
