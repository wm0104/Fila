import CRemoveFile
import Darwin
@testable import FilaFileOps
import FilaProtocol
import Foundation
import Testing

@Suite("Pinned permanent deletion", .serialized)
struct DeletionQuarantineTests {
    private struct Interrupted: Error {}

    @Test(arguments: ["file", "empty directory", "tree"])
    func defaultWritableParentDoesNotPreventPermanentDeletion(_ kind: String) throws {
        let scratch = Scratch()
        let operations = FileOperations(bootstrapRoot: "")
        let parent = scratch.path("made")
        try operations.create(.directory, at: parent)
        try #require(permissions(of: parent) == 0o777)
        let source: String
        if kind == "file" {
            source = scratch.file("made/selected")
        } else {
            source = scratch.directory("made/selected")
            if kind == "tree" { scratch.file("made/selected/inside", contents: "selected") }
        }
        scratch.file("made/keep", contents: "untouched", mode: 0o640)

        let outcome = FileJob(request: JobRequest(kind: .delete, sources: [source], useTrash: false), operations: operations).run { _ in }

        #expect(outcome.code == .success, "\(outcome)")
        #expect(!exists(source))
        #expect(permissions(of: parent) == 0o777)
        #expect(permissions(of: scratch.path("made/keep")) == 0o640)
        #expect(try String(contentsOfFile: scratch.path("made/keep"), encoding: .utf8) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent) == ["keep"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["made"])
    }

    @Test
    func deletionCanUseATrustedAncestorAboveSeveralWritableParents() throws {
        let scratch = Scratch()
        let operations = FileOperations(bootstrapRoot: "")
        let parents = ["dest", "dest/tree", "dest/tree/sub"]
        for relative in parents {
            try operations.create(.directory, at: scratch.path(relative))
            try #require(permissions(of: scratch.path(relative)) == 0o777)
        }
        let source = scratch.directory("dest/tree/sub/selected")
        scratch.file("dest/tree/sub/selected/inside")
        scratch.file("keep", contents: "untouched")

        let outcome = FileJob(request: JobRequest(kind: .delete, sources: [source], useTrash: false), operations: operations).run { _ in }

        #expect(outcome.code == .success, "\(outcome)")
        #expect(!exists(source))
        for relative in parents { #expect(permissions(of: scratch.path(relative)) == 0o777) }
        #expect(permissions(of: scratch.root) == 0o755)
        #expect(try String(contentsOfFile: scratch.path("keep"), encoding: .utf8) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path("dest/tree/sub")).isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: scratch.root)) == ["dest", "keep"])
    }

    @Test
    func ancestorReplacementCannotRedirectTheSystemRemoval() throws {
        let scratch = Scratch()
        let parent = scratch.directory("parent")
        let source = scratch.directory("parent/selected")
        scratch.file("parent/selected/remove", contents: "selected")
        let other = scratch.directory("other")
        scratch.file("other/selected", contents: "untouched")
        let operations = FileOperations(bootstrapRoot: "", writableRoot: scratch.root)
        try DeletionQuarantine.remove(source, operations: operations, isCancelled: { false }) { staged in
            #expect(!exists(source))
            try #require(rename(parent, scratch.path("moved-parent")) == 0)
            try #require(symlink(other, parent) == 0)
            try #require(removefile(staged, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0)
        }
        #expect(try String(contentsOfFile: scratch.path("other/selected"), encoding: .utf8) == "untouched")
        #expect(!exists(scratch.path("moved-parent/selected")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root).filter { $0.hasPrefix(".fila-delete-") }.isEmpty)
    }

    @Test
    func failedRemovalRestoresOnlyTheRemainingContents() throws {
        let scratch = Scratch()
        let source = scratch.directory("selected")
        scratch.file("selected/one")
        scratch.file("selected/two", contents: "remaining")
        do {
            try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: scratch.root), isCancelled: { false }) { staged in
                try #require(unlink(staged + "/one") == 0)
                throw Interrupted()
            }
            Issue.record("removal should fail")
        } catch is Interrupted {}
        #expect(!exists(scratch.path("selected/one")))
        #expect(try String(contentsOfFile: scratch.path("selected/two"), encoding: .utf8) == "remaining")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["selected"])
    }

    @Test
    func occupiedOriginKeepsTheRemainderAtTheReportedPrivatePath() throws {
        let scratch = Scratch()
        let source = scratch.file("selected", contents: "original")
        var retained = ""
        do {
            try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: scratch.root), isCancelled: { false }) { staged in
                retained = staged
                scratch.file("selected", contents: "new occupant")
                throw Interrupted()
            }
            Issue.record("restore must not overwrite")
        } catch let failure as FilaFailure {
            #expect(failure.systemError == EEXIST)
            #expect(failure.path == retained)
        }
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "new occupant")
        #expect(try String(contentsOfFile: retained, encoding: .utf8) == "original")
        #expect(permissions(of: FilaPath.directory(of: retained)) == 0o700)
        #expect(extendedAttribute("wiki.qaq.fila.delete-origin", at: FilaPath.directory(of: retained)) == source)
    }

    @Test
    func cancellationBeforeDetachDoesNotMoveTheSource() throws {
        let scratch = Scratch()
        let source = scratch.file("selected")
        do {
            try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: scratch.root), isCancelled: { true }) { _ in
                Issue.record("cancelled delete started")
            }
            Issue.record("delete should cancel")
        } catch let failure as FilaFailure { #expect(failure.code == .cancelled) }
        #expect(exists(source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["selected"])
    }

    @Test
    func cancellationAfterDetachRestoresTheSourceWithoutStartingRemoval() throws {
        let scratch = Scratch()
        let source = scratch.file("selected", contents: "kept")
        var cancellationChecks = 0
        do {
            try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: scratch.root), isCancelled: {
                cancellationChecks += 1
                return cancellationChecks == 2
            }) { _ in
                Issue.record("cancelled delete started")
            }
            Issue.record("delete should cancel")
        } catch let failure as FilaFailure { #expect(failure.code == .cancelled) }
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "kept")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["selected"])
    }

    @Test
    func deletingLinksDoesNotChangeTheirOtherNamesOrTargets() throws {
        let scratch = Scratch()
        let source = scratch.directory("selected")
        let shared = scratch.file("outside", contents: "untouched", mode: 0o640)
        try #require(link(shared, scratch.path("selected/hard-link")) == 0)
        try #require(symlink(shared, scratch.path("selected/symbolic-link")) == 0)
        try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: scratch.root), isCancelled: { false }) { staged in
            try #require(removefile(staged, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0)
        }
        #expect(!exists(source))
        #expect(try String(contentsOfFile: shared, encoding: .utf8) == "untouched")
        #expect(permissions(of: shared) == 0o640)
        #expect(metadata(of: shared)?.st_nlink == 1)
    }

    @Test
    func anACLOnTheAnchorIsRefusedBeforeMovingTheSource() throws {
        let scratch = Scratch()
        let source = scratch.file("selected", contents: "kept")
        var acl = acl_init(1)
        defer {
            if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        }
        var entry: acl_entry_t?
        try #require(acl_create_entry(&acl, &entry) == 0)
        let access = try #require(entry)
        var identity = try #require(UUID(uuidString: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000")?.uuid)
        try #require(acl_set_tag_type(access, ACL_EXTENDED_ALLOW) == 0)
        try #require(acl_set_qualifier(access, &identity) == 0)
        try #require(acl_set_permset_mask_np(access, UInt64(ACL_READ_DATA.rawValue)) == 0)
        try #require(acl_set_file(scratch.root, ACL_TYPE_EXTENDED, acl) == 0)
        do {
            try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: scratch.root), isCancelled: { false }) { _ in
                Issue.record("an ACL-bearing anchor was used")
            }
            Issue.record("delete should refuse the anchor")
        } catch let failure as FilaFailure { #expect(failure.systemError == EACCES) }
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "kept")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["selected"])
    }

    @Test
    func combiningMarksCannotHideAnUntrustedAncestor() throws {
        let scratch = Scratch()
        let writable = scratch.directory("writable")
        let root = scratch.directory("writable/\u{301}root")
        let source = scratch.file("writable/\u{301}root/selected")
        try #require(chmod(writable, 0o777) == 0)
        defer { chmod(writable, 0o755) }
        do {
            try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: root), isCancelled: { false }) { _ in
                Issue.record("untrusted ancestor was skipped")
            }
            Issue.record("delete should refuse the path")
        } catch let failure as FilaFailure { #expect(failure.systemError == EACCES) }
        #expect(exists(source))
    }

    @Test
    func aSearchOnlyParentStillAllowsDeletingAKnownFile() throws {
        let scratch = Scratch()
        let parent = scratch.directory("search-only")
        let source = scratch.file("search-only/selected")
        try #require(chmod(parent, 0o300) == 0)
        defer { chmod(parent, 0o755) }
        try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: parent), isCancelled: { false }) { staged in
            try #require(removefile(staged, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0)
        }
        #expect(!exists(source))
    }

    @Test
    func untrustedWritableRootFailsBeforeMovingAnything() throws {
        let scratch = Scratch()
        let root = scratch.directory("restricted")
        let source = scratch.file("restricted/selected")
        try #require(chmod(root, 0o777) == 0)
        defer { chmod(root, 0o755) }
        do {
            try DeletionQuarantine.remove(source, operations: .init(bootstrapRoot: "", writableRoot: root), isCancelled: { false }) { _ in
                Issue.record("untrusted anchor was used")
            }
            Issue.record("delete should refuse the anchor")
        } catch let failure as FilaFailure { #expect(failure.systemError == EACCES) }
        #expect(exists(source))
        #expect(permissions(of: scratch.root) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["restricted"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["selected"])
    }
}
