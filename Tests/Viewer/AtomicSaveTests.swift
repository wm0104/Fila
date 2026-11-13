import Foundation
import Testing

@MainActor
private final class SaveEvent {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@Suite("Editor save transactions", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AtomicSaveTests {
    private func identity(_ inode: UInt64) -> FileIdentity {
        FileIdentity(inode: inode, size: 10, modified: Double(inode))
    }

    @Test(arguments: [false, true])
    func concurrentEditorsRecheckAfterTheirTurn(replace: Bool) async throws {
        let original = identity(1), first = identity(2), second = identity(3)
        var disk = original
        let started = SaveEvent(), release = SaveEvent(), queued = SaveEvent()
        var secondPublished = false
        var questions = 0
        let a = Task {
            try await AtomicSaveOperation.run(path: "alias-a", expecting: original) { _ in
                .init(path: "/same", identity: disk)
            } confirm: { Issue.record("first save must not conflict"); return false } publish: { _ in
                started.signal()
                await release.wait()
                disk = first
                return first
            }
        }
        await started.wait()
        let b = Task {
            try await AtomicSaveOperation.run(path: "alias-b", expecting: original) { _ in
                queued.signal()
                return .init(path: "/same", identity: disk)
            } confirm: { questions += 1; return replace } publish: { _ in
                secondPublished = true
                disk = second
                return second
            }
        }
        await queued.wait()
        #expect(!secondPublished)
        release.signal()
        #expect(try await a.value == .saved(first))
        #expect(try await b.value == (replace ? .saved(second) : .kept))
        #expect(questions == 1)
        #expect(disk == (replace ? second : first))
    }

    @Test
    func differentTargetsDoNotBlockAndFailuresReleaseTheirTurn() async throws {
        enum Failure: Error { case write }
        let entered = SaveEvent(), release = SaveEvent()
        let original = identity(1)
        let a = Task {
            try await AtomicSaveOperation.run(path: "/a", expecting: nil) { .init(path: $0, identity: original) }
                confirm: { false } publish: { _ in
                    entered.signal()
                    await release.wait()
                    throw Failure.write
                }
        }
        await entered.wait()
        let b = try await AtomicSaveOperation.run(path: "/b", expecting: nil) { .init(path: $0, identity: original) }
            confirm: { false } publish: { _ in nil }
        #expect(b == .saved(nil))
        release.signal()
        do { _ = try await a.value; Issue.record("write should fail") } catch Failure.write {}
        let retry = try await AtomicSaveOperation.run(path: "/a", expecting: original) { .init(path: $0, identity: original) }
            confirm: { false } publish: { _ in original }
        #expect(retry == .saved(original))
    }

    @Test
    func cancelledWaiterDoesNotPublishOrStrandTheNextSave() async throws {
        let original = identity(1)
        let entered = SaveEvent(), release = SaveEvent(), queued = SaveEvent()
        let a = Task {
            try await AtomicSaveOperation.run(path: "/cancel", expecting: nil) { .init(path: $0, identity: original) }
                confirm: { false } publish: { _ in entered.signal(); await release.wait(); return original }
        }
        await entered.wait()
        let b = Task {
            try await AtomicSaveOperation.run(path: "/cancel", expecting: nil) { path in
                queued.signal()
                return .init(path: path, identity: original)
            } confirm: { Issue.record("cancelled save asked"); return false } publish: { _ in
                Issue.record("cancelled save published"); return nil
            }
        }
        await queued.wait()
        b.cancel()
        release.signal()
        _ = try await a.value
        do { _ = try await b.value; Issue.record("cancelled save succeeded") } catch is CancellationError {}
        let next = try await AtomicSaveOperation.run(path: "/cancel", expecting: nil) { .init(path: $0, identity: original) }
            confirm: { false } publish: { _ in original }
        #expect(next == .saved(original))
    }

    @Test
    func retargetedLinkIsResolvedAgainAfterWaiting() async throws {
        let original = identity(1)
        var alias = "/old"
        let entered = SaveEvent(), release = SaveEvent(), queued = SaveEvent()
        let a = Task {
            try await AtomicSaveOperation.run(path: "/old", expecting: nil) { .init(path: $0, identity: original) }
                confirm: { false } publish: { _ in entered.signal(); await release.wait(); return original }
        }
        await entered.wait()
        let b = Task {
            try await AtomicSaveOperation.run(path: "link", expecting: original) { _ in
                let target = alias
                queued.signal()
                return .init(path: target, identity: original)
            } confirm: { false } publish: { path in
                #expect(path == "/new")
                return original
            }
        }
        await queued.wait()
        alias = "/new"
        release.signal()
        _ = try await a.value
        #expect(try await b.value == .saved(original))
    }
}
