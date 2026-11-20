import Darwin
@testable import FilaFileOps
@testable import FilaProtocol
import Foundation
import Testing

@Suite("Local copy merging", .serialized)
struct CopyMergeTests {
    let scratch = Scratch()

    private func request(overwrite: Bool = true) -> JobRequest {
        JobRequest(kind: .copy, sources: [scratch.path("tree")], destination: scratch.path("destination"), overwrite: overwrite)
    }

    private func run(_ request: JobRequest, operations: FileOperations = FileOperations(bootstrapRoot: ""), report: @escaping (JobProgress) -> Void = { _ in }) -> FilaFailure {
        FileJob(request: request, operations: operations).run(report: report)
    }

    @Test
    func `Approved copy merges nested directories and preserves both sides`() throws {
        let source = scratch.directory("tree/nested")
        let file = scratch.file("tree/nested/shared", contents: "replacement", mode: 0o751)
        setExtendedAttribute("wiki.qaq.fila.test", to: "source", at: file)
        scratch.file("tree/nested/new", contents: "new")
        scratch.directory("tree/added/deep")
        scratch.file("tree/added/deep/file", contents: "subtree")
        scratch.link("tree/pointer", to: "nested/new")
        let existing = scratch.directory("destination/tree/nested")
        scratch.file("destination/tree/nested/shared", contents: "old")
        scratch.file("destination/tree/nested/keep", contents: "destination only")
        setExtendedAttribute("wiki.qaq.fila.test", to: "destination", at: existing)
        #expect(chmod(existing, 0o750) == 0)
        #expect(lchflags(existing, UInt32(UF_NODUMP)) == 0)
        huntSetACL(existing)
        huntSetACL(file)
        #expect(chmod(file, 0o6751) == 0)
        let directoryInode = metadata(of: existing)?.st_ino
        let directoryBefore = huntSnapshot(existing)[""]
        let sourceBefore = huntSnapshot(scratch.path("tree"))

        #expect(run(request()).code == .success)
        #expect(try String(contentsOfFile: scratch.path("destination/tree/nested/shared"), encoding: .utf8) == "replacement")
        #expect(try String(contentsOfFile: scratch.path("destination/tree/nested/keep"), encoding: .utf8) == "destination only")
        #expect(try String(contentsOfFile: scratch.path("destination/tree/nested/new"), encoding: .utf8) == "new")
        #expect(huntSnapshot(existing)[""] == directoryBefore)
        #expect(metadata(of: existing)?.st_ino == directoryInode)
        #expect(huntSnapshot(scratch.path("tree")) == sourceBefore)
        #expect(huntSnapshot(file) == huntSnapshot(scratch.path("destination/tree/nested/shared")))
        #expect(huntSnapshot(scratch.path("tree/added")) == huntSnapshot(scratch.path("destination/tree/added")))
        #expect(huntSnapshot(scratch.path("tree/pointer")) == huntSnapshot(scratch.path("destination/tree/pointer")))
        #expect(huntLeftoverTemporaries(in: existing).isEmpty)
        #expect(exists(source))
    }

    @Test
    func `An unapproved nonempty directory conflict changes nothing`() {
        scratch.directory("tree")
        scratch.file("tree/new")
        scratch.directory("destination/tree")
        scratch.file("destination/tree/keep")
        let before = huntSnapshot(scratch.root)
        #expect(run(request(overwrite: false)).systemError == EEXIST)
        #expect(huntSnapshot(scratch.root) == before)
    }

    @Test(arguments: [false, true])
    func `Known nested type conflicts reject the entire batch`(_ directoryLink: Bool) {
        scratch.directory("tree/nested")
        scratch.file("tree/nested/change", contents: "new")
        scratch.directory("destination/tree/nested")
        scratch.file("destination/tree/nested/change", contents: "old")
        scratch.file("outside", contents: "untouched")
        if directoryLink {
            scratch.directory("tree/nested/conflict")
            scratch.link("destination/tree/nested/conflict", to: scratch.root)
        } else {
            scratch.file("tree/nested/conflict")
            scratch.link("destination/tree/nested/conflict", to: scratch.path("outside"))
        }
        let first = scratch.file("first", contents: "first")
        var batch = request()
        batch.sources.insert(first, at: 0)
        let before = huntSnapshot(scratch.root)
        #expect(run(batch).reason == .differentItemKinds)
        #expect(huntSnapshot(scratch.root) == before)
    }

    @Test
    func `Same-kind symlinks are replaced without following either link`() {
        scratch.directory("tree")
        scratch.directory("destination/tree")
        scratch.file("outside", contents: "outside")
        scratch.link("tree/link", to: "missing-source-target")
        scratch.link("destination/tree/link", to: scratch.path("outside"))
        let before = huntSnapshot(scratch.path("outside"))
        #expect(run(request()).code == .success)
        #expect(huntSnapshot(scratch.path("tree/link")) == huntSnapshot(scratch.path("destination/tree/link")))
        #expect(huntSnapshot(scratch.path("outside")) == before)
    }

    @Test
    func `A nested same inode conflict is discovered before the first write`() throws {
        scratch.directory("tree")
        scratch.directory("destination/tree")
        let source = scratch.file("tree/shared", contents: "source")
        #expect(link(source, scratch.path("destination/tree/shared")) == 0)
        let first = scratch.file("first")
        var batch = request()
        batch.sources.insert(first, at: 0)
        let before = huntSnapshot(scratch.root)
        #expect(run(batch).reason == .sameItem)
        #expect(huntSnapshot(scratch.root) == before)
    }

    @Test
    func `Nested replacement does not modify an outside hard link`() throws {
        scratch.directory("tree")
        scratch.directory("destination/tree")
        scratch.file("tree/shared", contents: "new")
        let target = scratch.file("destination/tree/shared", contents: "old")
        let alias = scratch.path("outside")
        #expect(link(target, alias) == 0)
        let operations = FileOperations(bootstrapRoot: "", writableRoot: scratch.path("destination"))
        #expect(run(request(), operations: operations).code == .success)
        #expect(try String(contentsOfFile: alias, encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
        #expect(metadata(of: alias)?.st_ino != metadata(of: target)?.st_ino)
    }

    @Test
    func `Nested destruction protection is checked before any publication`() {
        scratch.directory("tree")
        scratch.directory("destination/tree")
        scratch.directory("usr")
        scratch.link("tree/guarded", to: "missing")
        scratch.link("destination/tree/guarded", to: scratch.path("usr"))
        let first = scratch.file("first")
        var batch = request()
        batch.sources.insert(first, at: 0)
        let before = huntSnapshot(scratch.root)
        #expect(run(batch, operations: FileOperations(bootstrapRoot: scratch.root)).code == .protectedPath)
        #expect(huntSnapshot(scratch.root) == before)
    }

    @Test
    func `Reverse directory overlap cannot overwrite the copy source`() {
        let source = scratch.directory("tree/tree/tree")
        scratch.file("tree/tree/foo", contents: "outer")
        scratch.file("tree/tree/tree/foo", contents: "inner")
        let before = huntSnapshot(scratch.root)
        let batch = JobRequest(kind: .copy, sources: [FilaPath.directory(of: source)], destination: scratch.root, overwrite: true)
        #expect(run(batch).reason == .overlappingSources)
        #expect(huntSnapshot(scratch.root) == before)
    }

    @Test
    func `A target cannot contain another selected source`() {
        let first = scratch.directory("input/tree")
        scratch.file("input/tree/item", contents: "first")
        let second = scratch.directory("destination/tree/nested")
        scratch.file("destination/tree/nested/item", contents: "second")
        let before = huntSnapshot(scratch.root)
        let batch = JobRequest(kind: .copy, sources: [first, second], destination: scratch.path("destination"), overwrite: true)
        #expect(run(batch).reason == .overlappingSources)
        #expect(huntSnapshot(scratch.root) == before)
    }

    @Test(arguments: [false, true])
    func `The first callback cannot exchange the chosen destination`(_ useLink: Bool) {
        scratch.directory("tree")
        scratch.file("tree/new")
        let destination = scratch.directory("destination/tree")
        scratch.file("destination/tree/keep")
        scratch.directory("outside/tree")
        scratch.file("outside/tree/keep", contents: "outside")
        let old = huntSnapshot(FilaPath.directory(of: destination))
        let outside = huntSnapshot(scratch.path("outside"))
        var exchanged = false
        let operations = FileOperations(bootstrapRoot: "", writableRoot: scratch.root)
        let outcome = run(request(), operations: operations) { _ in
            guard !exchanged else { return }
            exchanged = true
            #expect(rename(self.scratch.path("destination"), self.scratch.path("moved")) == 0)
            if useLink {
                self.scratch.link("destination", to: self.scratch.path("outside"))
            } else {
                self.scratch.directory("destination/tree")
            }
        }
        #expect(exchanged)
        #expect(outcome.code != .success)
        #expect(huntSnapshot(scratch.path("moved")) == old)
        #expect(huntSnapshot(scratch.path("outside")) == outside)
        if !useLink {
            #expect(!exists(scratch.path("destination/tree/new")))
        }
    }

    @Test
    func `A preflighted merge root cannot be exchanged for another real directory`() {
        scratch.directory("tree/nested")
        scratch.file("tree/nested/new")
        scratch.directory("destination/tree/nested")
        scratch.file("destination/tree/nested/keep")
        let old = huntSnapshot(scratch.path("destination/tree"))
        var exchanged = false
        let outcome = run(request()) { _ in
            guard !exchanged else { return }
            exchanged = true
            #expect(rename(self.scratch.path("destination/tree"), self.scratch.path("moved")) == 0)
            self.scratch.directory("destination/tree/nested")
        }
        #expect(exchanged)
        #expect(outcome.code != .success)
        #expect(huntSnapshot(scratch.path("moved")) == old)
        #expect(!exists(scratch.path("destination/tree/nested/new")))
    }

    @Test
    func `A preflighted nested real directory cannot be reapproved by the first callback`() throws {
        scratch.directory("tree/nested")
        scratch.file("tree/nested/new", contents: "source")
        scratch.directory("destination/tree/nested/kept")
        scratch.file("destination/tree/nested/kept/data", contents: "old subtree")
        let nested = scratch.path("destination/tree/nested")
        setExtendedAttribute("wiki.qaq.fila.test", to: "old directory", at: nested)
        let old = huntSnapshot(nested)
        let source = huntSnapshot(scratch.path("tree"))
        var exchanged = false
        let outcome = run(request()) { _ in
            guard !exchanged else { return }
            exchanged = true
            #expect(rename(nested, self.scratch.path("moved")) == 0)
            self.scratch.directory("destination/tree/nested")
        }
        #expect(exchanged)
        #expect(outcome.systemError == EAGAIN)
        #expect(huntSnapshot(scratch.path("moved")) == old)
        #expect(huntSnapshot(scratch.path("tree")) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested).isEmpty)
        #expect(huntLeftoverTemporaries(in: scratch.path("destination/tree")).isEmpty)
        #expect(huntLeftoverTemporaries(in: scratch.path("moved")).isEmpty)
    }

    @Test
    func `Directory identity budget exhaustion refuses the batch before any writes`() {
        scratch.directory("tree")
        scratch.directory("destination/tree")
        for index in 0 ..< 520 {
            scratch.directory("tree/branch-\(index)")
            scratch.directory("destination/tree/branch-\(index)")
        }
        let first = scratch.file("first", contents: "must not publish")
        var batch = request()
        batch.sources.insert(first, at: 0)
        let before = huntSnapshot(scratch.root)
        #expect(run(batch).systemError == ENOMEM)
        #expect(!exists(scratch.path("destination/first")))
        #expect(huntSnapshot(scratch.root) == before)
        #expect(huntLeftoverTemporaries(in: scratch.path("destination/tree")).isEmpty)
    }

    @Test
    func `A nested destination ancestor replaced with a link is never followed`() {
        scratch.directory("tree/nested")
        scratch.file("tree/nested/new")
        scratch.directory("destination/tree/nested")
        scratch.file("destination/tree/nested/keep")
        scratch.directory("outside")
        scratch.file("outside/keep")
        let outside = huntSnapshot(scratch.path("outside"))
        var exchanged = false
        let outcome = run(request()) { _ in
            guard !exchanged else { return }
            exchanged = true
            #expect(rename(self.scratch.path("destination/tree/nested"), self.scratch.path("moved")) == 0)
            self.scratch.link("destination/tree/nested", to: self.scratch.path("outside"))
        }
        #expect(exchanged)
        #expect(outcome.code != .success)
        #expect(huntSnapshot(scratch.path("outside")) == outside)
        #expect(!exists(scratch.path("moved/new")))
        #expect(huntLeftoverTemporaries(in: scratch.path("moved")).isEmpty)
    }

    @Test(arguments: [false, true])
    func `Late failure or cancellation retains complete published siblings and the old current file`(_ cancel: Bool) throws {
        scratch.directory("tree")
        scratch.directory("destination/tree")
        let names = ["a", "b", "c"]
        for name in names {
            scratch.file("tree/\(name)", contents: "new-\(name)")
            scratch.file("destination/tree/\(name)", contents: "old-\(name)")
        }
        let sourceBefore = huntSnapshot(scratch.path("tree"))
        let job = FileJob(request: request(), operations: FileOperations(bootstrapRoot: ""))
        var stoppedAt: String?
        let outcome = job.run { progress in
            guard stoppedAt == nil else { return }
            let published = names.contains {
                (try? String(contentsOfFile: self.scratch.path("destination/tree/\($0)"), encoding: .utf8)) == "new-\($0)"
            }
            if published, let current = names.first(where: { progress.currentPath == self.scratch.path("tree/\($0)") }),
               (try? String(contentsOfFile: self.scratch.path("destination/tree/\(current)"), encoding: .utf8)) == "old-\(current)" {
                stoppedAt = current
                if cancel {
                    job.cancel()
                } else {
                    // Force a late source read failure without changing the old
                    // destination. Restore this test's rename after the job.
                    #expect(rename(self.scratch.path("tree/\(current)"), self.scratch.path("held")) == 0)
                }
            }
            // Each next progress event must escape JobTally's 100ms throttle;
            // never infer publication from copyfile's staged itemsDone count.
            Thread.sleep(forTimeInterval: 0.12)
        }
        let current = try #require(stoppedAt)
        if !cancel {
            #expect(rename(scratch.path("held"), scratch.path("tree/\(current)")) == 0)
        }
        #expect(cancel ? outcome.code == .cancelled : outcome.code != .success)
        #expect(try String(contentsOfFile: scratch.path("destination/tree/\(current)"), encoding: .utf8) == "old-\(current)")
        #expect(names.contains { (try? String(contentsOfFile: scratch.path("destination/tree/\($0)"), encoding: .utf8)) == "new-\($0)" })
        for name in names {
            let contents = try String(contentsOfFile: scratch.path("destination/tree/\(name)"), encoding: .utf8)
            #expect(contents == "new-\(name)" || contents == "old-\(name)")
        }
        #expect(huntSnapshot(scratch.path("tree")) == sourceBefore)
        #expect(huntLeftoverTemporaries(in: scratch.path("destination/tree")).isEmpty)
    }

    @Test
    func `A destination kind changed during staging prevents publication and cleans the subtree`() {
        scratch.directory("tree/added")
        scratch.file("tree/added/one", contents: "one")
        scratch.file("tree/added/two", contents: "two")
        let parent = scratch.directory("destination/tree")
        scratch.directory("outside")
        scratch.file("outside/keep")
        let outside = huntSnapshot(scratch.path("outside"))
        let source = huntSnapshot(scratch.path("tree"))
        var changed = false
        let outcome = run(request()) { _ in
            guard !changed else { return }
            if !huntLeftoverTemporaries(in: parent).isEmpty {
                changed = true
                self.scratch.link("destination/tree/added", to: self.scratch.path("outside"))
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        #expect(changed)
        #expect(outcome.reason == .differentItemKinds)
        #expect(huntSnapshot(scratch.path("outside")) == outside)
        #expect(huntSnapshot(scratch.path("tree")) == source)
        #expect(metadata(of: scratch.path("destination/tree/added")).map { $0.st_mode & S_IFMT } == S_IFLNK)
        #expect(huntLeftoverTemporaries(in: parent).isEmpty)
    }

    @Test
    func `Moving and linking a missing subtree parent during staging leaves outside untouched`() {
        scratch.directory("tree/added")
        scratch.file("tree/added/one", contents: "one")
        scratch.file("tree/added/two", contents: "two")
        let parent = scratch.directory("destination/tree")
        scratch.file("destination/tree/keep")
        scratch.directory("outside")
        scratch.file("outside/keep", contents: "outside")
        let before = huntSnapshot(parent)
        let outside = huntSnapshot(scratch.path("outside"))
        let source = huntSnapshot(scratch.path("tree"))
        var exchanged = false
        let operations = FileOperations(bootstrapRoot: "", writableRoot: scratch.root)
        let outcome = run(request(), operations: operations) { _ in
            guard !exchanged else { return }
            if !huntLeftoverTemporaries(in: parent).isEmpty {
                exchanged = true
                #expect(rename(parent, self.scratch.path("moved")) == 0)
                self.scratch.link("destination/tree", to: self.scratch.path("outside"))
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        #expect(exchanged)
        #expect(outcome.code != .success)
        #expect(huntSnapshot(scratch.path("outside")) == outside)
        #expect(huntSnapshot(scratch.path("tree")) == source)
        #expect(huntSnapshot(scratch.path("moved")) == before)
        #expect(huntLeftoverTemporaries(in: scratch.path("moved")).isEmpty)
    }

    @Test
    func `Cancelling the first merge report preserves the whole old destination`() {
        scratch.directory("tree")
        scratch.file("tree/shared", contents: "new")
        scratch.directory("destination/tree")
        scratch.file("destination/tree/shared", contents: "old")
        scratch.file("destination/tree/keep")
        let before = huntSnapshot(scratch.root)
        let job = FileJob(request: request(), operations: FileOperations(bootstrapRoot: ""))
        #expect(job.run { _ in job.cancel() }.code == .cancelled)
        #expect(huntSnapshot(scratch.root) == before)
    }
}
