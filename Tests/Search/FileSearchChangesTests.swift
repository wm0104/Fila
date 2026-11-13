import FilaProtocol
import Foundation
import Testing

@Suite("Search results changed by file operations")
struct FileSearchChangesTests {
    @Test func fullPathsDoNotConfuseEqualNames() {
        var changes = FileSearchChanges()
        changes.record(["/one/same.txt"])
        #expect(changes.contains("/one/same.txt"))
        #expect(!changes.contains("/two/same.txt"))
    }

    @Test func directoriesIncludeDescendantsButNotPrefixSiblings() {
        var changes = FileSearchChanges()
        changes.record(["/one/folder"])
        #expect(changes.contains("/one/folder"))
        #expect(changes.contains("/one/folder/deep/item"))
        #expect(!changes.contains("/one/folder-other/item"))
        #expect(!changes.contains("/one"))
    }

    @Test func componentBoundariesIncludeCombiningMarks() {
        var changes = FileSearchChanges()
        changes.record(["/one/folder"])
        #expect(changes.contains("/one/folder/\u{301}child/item"))
        #expect(!changes.contains("/one/folder\u{301}/item"))
    }

    @Test func everyOperationBoundaryInvalidatesAnEarlierRead() {
        var changes = FileSearchChanges()
        let before = changes.revision
        changes.record(["/one"])
        let started = changes.revision
        changes.record(["/one"])
        #expect(before != started)
        #expect(started != changes.revision)
        #expect(changes.contains("/one/new-page/item"))
    }
}
