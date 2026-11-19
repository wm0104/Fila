import Foundation
import Testing

@MainActor
struct DebianPackageBuildOperationTests {
    private enum Failure: Error, Equatable { case save, build }
    private let identity = FileIdentity(inode: 1, size: 10, modified: 1)

    @Test
    func keepingAConflictingControlArchiveDoesNotBuild() async {
        let current = FileIdentity(inode: 2, size: 20, modified: 2)
        var asked = false
        let outcome = await DebianPackageBuildOperation.run(control: "confirmed", expecting: identity) { text, loaded in
            #expect(text == "confirmed" && loaded == identity)
            let result = try await AtomicSaveOperation.run(path: "/control.tar", expecting: loaded) {
                .init(path: $0, identity: current)
            } confirm: {
                asked = true
                return false
            } publish: { _ in
                Issue.record("Keeping the existing archive must not publish metadata")
                return nil
            }
            if case .saved = result { return true }
            return false
        } build: { _ in
            Issue.record("A kept control archive must not be packed")
            return true
        }
        #expect(asked)
        guard case .kept = outcome else { Issue.record("Expected a kept operation"); return }
    }

    @Test
    func saveFailureDoesNotBuildOrClaimInformationWasSaved() async {
        let outcome = await DebianPackageBuildOperation.run(control: "confirmed", expecting: identity) { _, _ in
            throw Failure.save
        } build: { _ in
            Issue.record("A failed save must not be packed")
            return true
        }
        guard case let .failed(error, informationSaved) = outcome else { Issue.record("Expected a failure"); return }
        #expect(error as? Failure == .save)
        #expect(!informationSaved)
    }

    @Test
    func buildFailureStillReportsTheSuccessfulSave() async {
        var saved = false
        let outcome = await DebianPackageBuildOperation.run(control: "confirmed", expecting: identity) { _, _ in
            saved = true
            return true
        } build: { text in
            #expect(saved && text == "confirmed")
            throw Failure.build
        }
        guard case let .failed(error, informationSaved) = outcome else { Issue.record("Expected a failure"); return }
        #expect(error as? Failure == .build)
        #expect(informationSaved)
    }

    @Test
    func buildUsesConfirmedTextEvenIfAnotherWindowSavesAgain() async {
        var events: [String] = []
        var archive = "original"
        let outcome = await DebianPackageBuildOperation.run(control: "confirmed", expecting: identity) { text, loaded in
            #expect(loaded == identity)
            archive = text
            events.append("saved")
            return true
        } build: { text in
            #expect(archive == "confirmed")
            archive = "another window"
            #expect(text == "confirmed")
            events.append("packed")
            return true
        }
        #expect(events == ["saved", "packed"])
        #expect(archive == "another window")
        guard case .packed = outcome else { Issue.record("Expected a packed operation"); return }
    }

    @Test
    func losingThePresenterAfterSavingDoesNotClaimAPackageWasBuilt() async {
        let outcome = await DebianPackageBuildOperation.run(control: "confirmed", expecting: identity) { _, _ in
            true
        } build: { _ in
            false
        }
        guard case .saved = outcome else { Issue.record("Only metadata was saved"); return }
    }
}
