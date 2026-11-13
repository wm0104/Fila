@testable import FilaApplications
import FilaBackendKit
import Foundation
import Testing

struct TrollStoreHandoffTests {
    @Test(arguments: ["https://example.com/app.ipa", "file:///tmp/file.txt", "file:///tmp/folder"])
    @MainActor
    func onlyLocalAppPackagesMayBeHandedOff(_ address: String) async throws {
        let url = try #require(URL(string: address))
        #expect(await ApplicationCatalog.openInTrollStore(packageAt: url) == .unavailable)
    }

    @Test
    func copyingDoesNotConfirmOpeningTheApplication() {
        var outcomes: [TrollStoreHandoffOutcome] = []
        let handoff = TrollStoreDocumentHandoff { outcomes.append($0) }
        handoff.openResourceOperation(Operation(), didFinishCopyingResource: URL(fileURLWithPath: "/tmp/copy.tipa"))
        #expect(outcomes.isEmpty)
        handoff.finish(.unanswered)
        #expect(outcomes == [.unanswered])
    }

    @Test
    func refusalKeepsTheOriginalErrorAndIgnoresLateSuccess() {
        var outcomes: [TrollStoreHandoffOutcome] = []
        let handoff = TrollStoreDocumentHandoff { outcomes.append($0) }
        let operation = Operation()
        handoff.openResourceOperation(operation, didFailWithError: NSError(domain: "LSApplicationWorkspaceErrorDomain", code: 115))
        handoff.openResourceOperationDidComplete(operation)
        handoff.finish(.unanswered)
        #expect(outcomes == [.failed(domain: "LSApplicationWorkspaceErrorDomain", code: 115)])
    }

    @Test
    func successfulHandoffCompletesOnlyOnce() {
        var outcomes: [TrollStoreHandoffOutcome] = []
        let handoff = TrollStoreDocumentHandoff { outcomes.append($0) }
        let operation = Operation()
        handoff.openResourceOperationDidComplete(operation)
        handoff.openResourceOperationDidComplete(operation)
        handoff.openResourceOperation(operation, didFailWithError: NSError(domain: "late", code: 1))
        #expect(outcomes == [.opened])
    }

    @Test
    func timeoutCannotBeOverwrittenByALateReply() {
        var outcomes: [TrollStoreHandoffOutcome] = []
        let handoff = TrollStoreDocumentHandoff { outcomes.append($0) }
        let operation = Operation()
        handoff.finish(.unanswered)
        handoff.openResourceOperationDidComplete(operation)
        handoff.openResourceOperation(operation, didFailWithError: NSError(domain: "late", code: 2))
        #expect(outcomes == [.unanswered])
    }

    @Test
    func nativeDelegateSelectorsAreAvailable() {
        let handoff = TrollStoreDocumentHandoff { _ in }
        #expect(handoff.responds(to: NSSelectorFromString("openResourceOperation:didFinishCopyingResource:")))
        #expect(handoff.responds(to: NSSelectorFromString("openResourceOperation:didFailWithError:")))
        #expect(handoff.responds(to: NSSelectorFromString("openResourceOperationDidComplete:")))
    }

    @Test
    func concurrentTerminalRepliesCompleteOnlyOnce() {
        var outcomes: [TrollStoreHandoffOutcome] = []
        let handoff = TrollStoreDocumentHandoff { outcomes.append($0) }
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index.isMultiple(of: 2) { handoff.openResourceOperationDidComplete(Operation()) }
            else { handoff.finish(.unanswered) }
        }
        #expect(outcomes.count == 1)
    }

    @Test
    @MainActor
    func nativeDocumentOperationDoesNotStartOnTheMainThread() async {
        let startedOnMain: Bool = await withCheckedContinuation { continuation in
            let handoff = TrollStoreDocumentHandoff { _ in }
            let operation = BlockOperation {
                handoff.finish(.opened)
                continuation.resume(returning: Thread.isMainThread)
            }
            handoff.start(operation)
        }
        #expect(!startedOnMain)
    }
}
