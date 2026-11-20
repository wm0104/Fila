@testable import FilaApplications
import FilaBackendKit
import Foundation
import Testing

struct SileoHandoffTests {
    @Test(arguments: ["https://example.com/package.deb", "sileo://package/example", "file:///tmp/app.ipa", "file:///tmp/app.tipa", "file:///tmp/package.txt", "file:///tmp/folder"])
    @MainActor
    func onlyLocalDebDocumentsMayBeHandedOff(_ address: String) async throws {
        let url = try #require(URL(string: address))
        #expect(await ApplicationCatalog.openInSileo(packageAt: url) == .unavailable)
    }

    @Test
    func sileoCopyingIsNotAnOpenOrInstallConfirmation() {
        var outcomes: [TrollStoreHandoffOutcome] = []
        let handoff = TrollStoreDocumentHandoff(applicationName: "Sileo") { outcomes.append($0) }
        let operation = Operation()
        handoff.openResourceOperation(operation, didFinishCopyingResource: URL(fileURLWithPath: "/tmp/package.deb"))
        #expect(outcomes.isEmpty)
        handoff.finish(.unanswered)
        handoff.openResourceOperationDidComplete(operation)
        #expect(outcomes == [.unanswered])
    }

    @Test
    func sileoFailureIsPreservedAndCompletesOnce() {
        var outcomes: [TrollStoreHandoffOutcome] = []
        let handoff = TrollStoreDocumentHandoff(applicationName: "Sileo") { outcomes.append($0) }
        let operation = Operation()
        handoff.openResourceOperation(operation, didFailWithError: NSError(domain: "SileoTest", code: 7))
        handoff.openResourceOperationDidComplete(operation)
        handoff.finish(.unanswered)
        #expect(outcomes == [.failed(domain: "SileoTest", code: 7)])
    }
}
