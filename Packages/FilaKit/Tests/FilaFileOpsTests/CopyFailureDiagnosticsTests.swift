import Darwin
@testable import FilaFileOps
import FilaProtocol
import Foundation
import Testing

struct CopyFailureDiagnosticsTests {
    private func job() -> FileJob {
        FileJob(request: JobRequest(kind: .copy, sources: ["/source"], destination: "/destination"), operations: FileOperations(bootstrapRoot: ""))
    }

    @Test
    func `Copy diagnostics keep the first error even when logging changes errno`() {
        var notes: [String] = []
        let tally = JobTally(job: job(), report: { _ in }, note: {
            notes.append($0)
            Darwin.errno = ENOSPC
        })
        Darwin.errno = EACCES
        tally.recordCopyFailure(source: "/source", destination: "/destination", phase: "callback what=4 stage=3")
        #expect(tally.failure?.systemError == EACCES)
        #expect(tally.failure?.path == "/source")
        #expect(Darwin.errno == EACCES)
        tally.recordCopyFailure(source: "/later", destination: "/other", code: EPERM)
        #expect(tally.failure?.systemError == EACCES)
        #expect(notes.count == 1)
        #expect(notes.first?.contains("phase=callback what=4 stage=3") == true)
        #expect(notes.first?.contains("errno=\(EACCES)") == true)
        #expect(notes.first?.contains("euid=\(geteuid())") == true)
    }

    @Test
    func `Destination-only errors keep their destination and diagnostics contain no control lines`() {
        var notes: [String] = []
        let tally = JobTally(job: job(), report: { _ in }, note: { notes.append($0) })
        tally.recordCopyFailure(source: "/source\nsecret", destination: "/destination", code: ENOSPC)
        #expect(tally.failure?.path == "/destination")
        #expect(notes.count == 1)
        #expect(notes[0].contains("source=/source�secret"))
        #expect(!notes[0].contains("\n"))
    }

    @Test
    func `A copyfile error still quits with its original errno and callback stage`() {
        var notes: [String] = []
        let tally = JobTally(job: job(), report: { _ in }, note: { notes.append($0) })
        let context = Unmanaged.passUnretained(tally).toOpaque()
        Darwin.errno = EACCES
        let answer = "/source".withCString { source in
            "/destination".withCString { destination in
                filaCopyProgress(COPYFILE_COPY_DATA, COPYFILE_ERR, nil, source, destination, context)
            }
        }
        #expect(answer == COPYFILE_QUIT)
        #expect(tally.failure?.systemError == EACCES)
        #expect(notes.count == 1)
        #expect(notes[0].contains("phase=callback what=\(COPYFILE_COPY_DATA) stage=\(COPYFILE_ERR)"))
        #expect(notes[0].contains("sourceFD=-1 destinationFD=-1"))
        #expect(Darwin.errno == EACCES)
    }

    @Test
    func `A real job reports a publication failure without changing the old file`() throws {
        let scratch = Scratch()
        scratch.directory("source")
        let source = scratch.file("source/payload", contents: "new bytes")
        let destination = scratch.directory("destination")
        var injected = false
        var notes: [String] = []
        let work = FileJob(request: JobRequest(kind: .copy, sources: [source], destination: destination), operations: FileOperations(bootstrapRoot: ""))
        let outcome = work.run(report: { _ in
            if !injected {
                injected = true
                scratch.file("destination/payload", contents: "old bytes")
            }
        }, note: { notes.append($0); Darwin.errno = ENOSPC })
        #expect(outcome.systemError == EEXIST)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "new bytes")
        #expect(try String(contentsOfFile: scratch.path("destination/payload"), encoding: .utf8) == "old bytes")
        #expect(notes.count == 1)
        #expect(notes[0].contains("phase=publish-rename"))
        #expect(notes[0].contains("errno=\(EEXIST)"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination) == ["payload"])
    }

    @Test
    func `Diagnostic paths are bounded even for long multibyte names`() {
        let path = String(repeating: "文", count: 5000)
        var notes: [String] = []
        let tally = JobTally(job: job(), report: { _ in }, note: { notes.append($0) })
        tally.recordCopyFailure(source: path, destination: path, code: EACCES)
        #expect(notes.count == 1)
        #expect(notes[0].utf8.count < 9000)
        #expect(!notes[0].contains(String(repeating: "文", count: 1025)))
        #expect(tally.failure?.path == path)
    }

    @Test
    func `Cancellation after a recorded failure does not erase the first error`() {
        let work = job()
        let tally = JobTally(job: work, report: { _ in })
        tally.recordCopyFailure(source: "/source", destination: "/target", code: EACCES)
        work.cancel()
        #expect(filaCopyProgress(COPYFILE_COPY_DATA, COPYFILE_ERR, nil, nil, nil, Unmanaged.passUnretained(tally).toOpaque()) == COPYFILE_QUIT)
        #expect(tally.failure?.systemError == EACCES)
    }

    @Test
    func `Cancelled copy callbacks do not invent a copy failure`() {
        let work = job()
        var notes: [String] = []
        let tally = JobTally(job: work, report: { _ in }, note: { notes.append($0) })
        work.cancel()
        let answer = filaCopyProgress(COPYFILE_COPY_DATA, COPYFILE_ERR, nil, nil, nil, Unmanaged.passUnretained(tally).toOpaque())
        #expect(answer == COPYFILE_QUIT)
        #expect(tally.failure == nil)
        #expect(notes.isEmpty)
    }
}
