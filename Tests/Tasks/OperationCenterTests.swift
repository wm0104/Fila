import FilaClient
import FilaProtocol
import Foundation
import Testing

@MainActor
private final class JobGate {
    private var signaled = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !signaled { await withCheckedContinuation { pending.append($0) } }
    }
    func signal() {
        signaled = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor
@Suite("Connection-scoped operation registration", .serialized, .timeLimit(.minutes(1)))
struct OperationCenterTests {
    private let request = JobRequest(kind: .copy, sources: ["/source"], destination: "/destination")

    @Test
    func lossBeforeTheStartReplyCannotLeaveARunningRow() async throws {
        let session = FileSession(), entered = JobGate(), reply = JobGate()
        let center = OperationCenter(session: session)
        let identifier = LocalJobIdentifier(value: 1, generation: 1)
        var sends = 0
        session.link.handler = { _ in sends += 1; entered.signal(); await reply.wait(); return identifier }
        let wait = Task { try await center.awaitJob(request, kind: .copy, subtitle: "", feedback: .silent) }
        await entered.wait()
        center.abandonDaemonJobs(generation: 1)
        reply.signal()
        #expect(try await wait.value.systemError == ECONNRESET)
        #expect(!center.hasActiveWork)
        #expect(sends == 1, "writes must not be resent")
    }

    @Test(arguments: [UInt64(0), 2])
    func delayedOldLossAndEventsDoNotEndANewOrLocalJob(generation: UInt64) async throws {
        let session = FileSession(), center = OperationCenter(session: session)
        let current = LocalJobIdentifier(value: 1, generation: generation)
        let old = LocalJobIdentifier(value: 1, generation: 1)
        session.link.handler = { _ in current }
        var finished = 0
        _ = try await center.startJob(request, kind: .copy, title: "", subtitle: "", feedback: .silent) { _ in finished += 1 }
        center.abandonDaemonJobs(generation: 1)
        center.apply(.init(identifier: old, event: .completed(FilaFailure(code: .success), skipped: 0)))
        #expect(center.operation(forJob: current)?.isRunning == true)
        #expect(finished == 0)
        center.apply(.init(identifier: current, event: .completed(FilaFailure(code: .success), skipped: 0)))
        #expect(finished == 1)
        #expect(!center.hasActiveWork)
    }

    @Test
    func delayedOldLossKeepsTheNewConnectionsEarlyCompletion() async throws {
        let session = FileSession(), entered = JobGate(), reply = JobGate()
        let center = OperationCenter(session: session)
        let current = LocalJobIdentifier(value: 1, generation: 2)
        session.link.handler = { _ in entered.signal(); await reply.wait(); return current }
        let wait = Task { try await center.awaitJob(request, kind: .copy, subtitle: "", feedback: .silent) }
        await entered.wait()
        center.apply(.init(identifier: current, event: .completed(FilaFailure(code: .success), skipped: 3)))
        center.abandonDaemonJobs(generation: 1)
        reply.signal()
        #expect(try await wait.value.code == .success)
        #expect(center.operations.first?.skippedItems == 3)
        #expect(!center.hasActiveWork)
    }

    @Test
    func duplicateLossAndLateCompletionFinishExactlyOnce() async throws {
        let session = FileSession(), center = OperationCenter(session: session)
        let identifier = LocalJobIdentifier(value: 1, generation: 3)
        session.link.handler = { _ in identifier }
        var finished = 0
        _ = try await center.startJob(request, kind: .copy, title: "", subtitle: "", feedback: .silent) { _ in finished += 1 }
        session.link.onLinkLost?(3)
        let deadline = Date().addingTimeInterval(3)
        while center.hasActiveWork, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(!center.hasActiveWork)
        center.abandonDaemonJobs(generation: 3)
        center.apply(.init(identifier: identifier, event: .completed(FilaFailure(code: .success), skipped: 0)))
        #expect(finished == 1)
        #expect(center.operations.first?.failure?.systemError == ECONNRESET)
    }
}
