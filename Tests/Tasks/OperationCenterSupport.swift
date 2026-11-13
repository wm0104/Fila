import FilaClient
import FilaLog
import FilaProtocol
import Foundation

// Only transport, presentation and the session boundary are replaced. The
// harness compiles the real OperationCenter registration/finish/await paths.
struct UnexpectedCall: Error {}

@MainActor
final class FileSession {
    let link = JobTestTransport()
    let local = InvalidationSink()
    init() { UserDefaults.standard.removeObject(forKey: "wiki.qaq.fila.operations.inflight") }
    func perform<T>(retryOnDisconnect _: Bool = false, _ body: (any LocalFileAccess) async throws -> T) async throws -> T {
        try await body(link)
    }
}

final class InvalidationSink { func invalidate(_: [String]) {} }
enum FeedbackAlert { static func show(_: String, message _: String) {} }
enum Toast { static func show(_: String) {} }
enum FailureText {
    static func title(for _: FilaFailure) -> String { "" }
    static func summary(for _: FilaFailure) -> String { "" }
}

extension OperationCenter {
    func putBack(_: [String], identity _: UUID) async throws { throw UnexpectedCall() }
}

final class JobTestTransport: LocalFileAccess, @unchecked Sendable {
    let streams = FileEventStreams()
    var jobEvents: AsyncStream<JobUpdate> { streams.jobEvents }
    var searchResults: AsyncStream<SearchUpdate> { streams.searchResults }
    var onLinkLost: (@Sendable (UInt64) -> Void)?
    var handler: @MainActor (JobRequest) async throws -> LocalJobIdentifier = { _ in throw UnexpectedCall() }
    func startJob(_ job: JobRequest) async throws -> LocalJobIdentifier { try await handler(job) }
    func cancelJob(_: LocalJobIdentifier) async throws { throw UnexpectedCall() }
    func hello() async throws -> LocalHello { throw UnexpectedCall() }
    func list(directory _: String, cursor _: UInt64) async throws -> DirectoryPage { throw UnexpectedCall() }
    func closeDirectory(cursor _: UInt64) async throws { throw UnexpectedCall() }
    func details(of _: String) async throws -> FileDetails { throw UnexpectedCall() }
    func open(_: String, flags _: Int32, mode _: mode_t) async throws -> Int32 { throw UnexpectedCall() }
    func create(_: NodeTemplate, at _: String, mode _: mode_t?) async throws { throw UnexpectedCall() }
    func rename(_: String, to _: String, exclusive _: Bool, overrideGuard _: Bool) async throws { throw UnexpectedCall() }
    func remove(_: String, directory _: Bool, overrideGuard _: Bool) async throws { throw UnexpectedCall() }
    func setAttributes(_: AttributeChange, at _: String) async throws -> AttributeOutcome { throw UnexpectedCall() }
    func replaceItem(at _: String, withTemporary _: String) async throws { throw UnexpectedCall() }
    func mountPoints() async throws -> [MountPoint] { throw UnexpectedCall() }
    func volumeInfo(for _: String) async throws -> VolumeInfo { throw UnexpectedCall() }
    func extendedAttribute(_: String, at _: String) async throws -> Data { throw UnexpectedCall() }
    func fetchLog(since _: UInt64, level _: FilaLog.Level) async throws -> (records: [FilaLog.Record], dropped: UInt64) { throw UnexpectedCall() }
    func invalidate() {}
}
