import FilaProtocol
import Foundation
import Testing

// Host-only target: compile the real Fila/Services/Files/FileSearch.swift beside
// this file, with FilaLog and FilaProtocol. These two doubles replace only the
// app session and paged transport, not the search algorithm.
@MainActor
final class FileSession {
    var directories: [String: [[FileNode]]] = [:]
    var failsAfterPage: [String: Int] = [:]
    var reads: [String] = []
}

@MainActor
enum DirectoryReader {
    static func pages(in path: String, session: FileSession) -> Pages {
        Pages(path: path, session: session)
    }

    struct Pages: AsyncSequence {
        typealias Element = [FileNode]
        let path: String
        let session: FileSession

        func makeAsyncIterator() -> Iterator { Iterator(path: path, session: session) }

        struct Iterator: AsyncIteratorProtocol {
            let path: String
            let session: FileSession
            var page = 0

            @MainActor
            mutating func next() async throws -> [FileNode]? {
                try Task.checkCancellation()
                session.reads.append(path)
                if session.failsAfterPage[path] == page {
                    throw CocoaError(.fileReadNoPermission)
                }
                let pages = session.directories[path] ?? []
                guard page < pages.count else { return nil }
                defer { page += 1 }
                return pages[page]
            }
        }
    }
}

@Suite("App paged name search")
@MainActor
struct FileSearchTests {
    private func node(_ name: String, _ kind: FileKind = .regular) -> FileNode {
        FileNode(
            name: name, kind: kind, size: 0, allocatedSize: 0,
            modified: 0, created: 0, accessed: 0, mode: 0,
            ownerID: 0, groupID: 0, systemFlags: 0, linkCount: 1, inode: 0,
        )
    }

    @Test
    func `Every page and descendant is searched without duplicate hits`() async {
        let session = FileSession()
        session.directories = [
            "/current": [[node("child", .directory)], [node("child", .directory)]],
            "/current/child": [[node("deep", .directory)]],
            "/current/child/deep": [[node("NEEDLE.txt")], [node("NEEDLE.txt"), node("needle-2")]],
            "/elsewhere": [[node("needle-outside")]],
        ]
        var hits: [String] = []
        var summary = FileSearch.Summary()
        let skipped = await FileSearch.run(
            root: "/current", needle: "needle", session: session,
            onSummary: { summary = $0 },
        ) { _ in } onHit: { hits.append($0.path) }
        #expect(hits == ["/current/child/deep/NEEDLE.txt", "/current/child/deep/needle-2"])
        #expect(!session.reads.contains("/elsewhere"))
        #expect(skipped == 0)
        #expect(summary.unreadableDirectories == 0)
        #expect(!summary.isTruncated)
    }

    @Test
    func `Descendants beyond the daemon search depth limit are still searched`() async {
        let session = FileSession()
        var path = "/current"
        for _ in 0 ..< 256 {
            session.directories[path] = [[node("deep", .directory)]]
            path += "/deep"
        }
        session.directories[path] = [[node("needle")]]
        var hits: [String] = []
        await FileSearch.run(root: "/current", needle: "needle", session: session) { _ in } onHit: {
            hits.append($0.path)
        }
        #expect(hits == [path + "/needle"])
    }

    @Test
    func `The supplied backend root is used without probing another root`() async {
        let session = FileSession()
        session.directories["/backend"] = [[node("needle")]]
        session.directories["/"] = [[node("needle-outside")]]
        var hits: [String] = []
        // Also exercises the unchanged Shortcuts call shape, without onSummary.
        await FileSearch.run(root: "/backend", needle: "needle", session: session) { _ in } onHit: {
            hits.append($0.path)
        }
        #expect(hits == ["/backend/needle"])
        #expect(!session.reads.contains("/"))
    }

    @Test
    func `Unreadable directories and unresolved links are reported even without hits`() async {
        let session = FileSession()
        session.directories["/"] = [[node("closed", .directory), node("loop", .symbolicLink)]]
        session.failsAfterPage["/closed"] = 0
        var summary = FileSearch.Summary()
        var hits: [String] = []
        let skipped = await FileSearch.run(
            root: "/", needle: "absent", session: session,
            onSummary: { summary = $0 },
        ) { _ in } onHit: { hits.append($0.path) }
        #expect(hits.isEmpty)
        #expect(summary.unreadableDirectories == 1)
        #expect(summary.skippedLinks == 1)
        #expect(skipped == 1)
        #expect(!session.reads.contains("/loop"))
    }

    @Test
    func `A later page failure preserves hits and reports an incomplete directory`() async {
        let session = FileSession()
        session.directories["/"] = [[node("needle")]]
        session.failsAfterPage["/"] = 1
        var hits: [String] = []
        var summary = FileSearch.Summary()
        await FileSearch.run(
            root: "/", needle: "needle", session: session,
            onSummary: { summary = $0 },
        ) { _ in } onHit: { hits.append($0.path) }
        #expect(hits == ["/needle"])
        #expect(summary.unreadableDirectories == 1)
    }

    @Test
    func `The ten thousand result cap truncates without opening the queued subtree`() async {
        let session = FileSession()
        session.directories["/"] = [[node("child", .directory)] + (0 ..< 10001).map { node("hit-\($0)") }]
        var count = 0
        var summary = FileSearch.Summary()
        await FileSearch.run(
            root: "/", needle: "hit-", session: session,
            onSummary: { summary = $0 },
        ) { _ in } onHit: { _ in count += 1 }
        #expect(count == 10000)
        #expect(summary.isTruncated)
        #expect(!session.reads.contains("/child"))
    }

    @Test
    func `Cancellation stops between entries and is not a read failure`() async {
        let session = FileSession()
        session.directories["/"] = [(0 ..< 100).map { node("hit-\($0)") }]
        let task = Task { @MainActor in
            var count = 0
            var summary = FileSearch.Summary()
            await FileSearch.run(
                root: "/", needle: "hit-", session: session,
                onSummary: { summary = $0 },
            ) { _ in } onHit: { _ in
                count += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return (count, summary)
        }
        let (count, summary) = await task.value
        #expect(count == 1)
        #expect(summary.wasCancelled)
        #expect(summary.unreadableDirectories == 0)
    }

    @Test
    func `Empty queries do not open a directory`() async {
        let session = FileSession()
        var reported = false
        await FileSearch.run(
            root: "/", needle: "", session: session,
            onSummary: { _ in reported = true },
        ) { _ in } onHit: { _ in Issue.record("An empty query produced a hit") }
        #expect(session.reads.isEmpty)
        #expect(reported)
    }
}
