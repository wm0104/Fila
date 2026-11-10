import Foundation
import Testing

@Suite struct ViewerTextTests {
    private func matches(_ text: String, _ term: String, matchCase: Bool = false) -> [NSRange] {
        var ranges: [NSRange] = []
        TextSearch.enumerate(text, term: term, matchCase: matchCase) {
            ranges.append($0)
            return true
        }
        return ranges
    }

    @Test func literalCaseAndNonOverlappingMatches() {
        #expect(matches("Aa aA aa", "aa").count == 3)
        #expect(matches("Aa aA aa", "aa", matchCase: true) == [NSRange(location: 6, length: 2)])
        #expect(matches("aaaaa", "aa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        #expect(matches("a.b axb", "a.b") == [NSRange(location: 0, length: 3)])
        #expect(matches("anything", "").isEmpty)
        #expect(matches("", "anything").isEmpty)
    }

    @Test func offsetsUseUTF16AndUnicodeMatches() {
        #expect(matches("😀中文😀中文", "中文") == [NSRange(location: 2, length: 2), NSRange(location: 6, length: 2)])
        #expect(matches("😀中文😀中文", "😀") == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        #expect(matches("café cafe\u{301}", "café").count == 2)
    }

    @Test func enumerationCanStopWithoutScanningTheRest() {
        var count = 0
        TextSearch.enumerate("a a a", term: "a", matchCase: false) { _ in
            count += 1
            return false
        }
        #expect(count == 1)
    }

    @Test func findNavigationKeepsTheCurrentHighlightAndCountTogether() throws {
        let text = "巨魔 😀 巨魔 巨魔"
        let start = NSRange(location: 0, length: 0)
        let first = try #require(TextSearch.find(text, term: "巨魔", matchCase: false, selection: start, forwards: true))
        #expect(first.range == NSRange(location: 0, length: 2))
        #expect(first.index == 1 && first.count == 3)
        #expect(first.highlights.count == 3)
        let next = try #require(TextSearch.find(text, term: "巨魔", matchCase: false, selection: first.range, forwards: true))
        #expect(next.range == NSRange(location: 6, length: 2))
        #expect(next.index == 2 && next.count == 3)
        let previous = try #require(TextSearch.find(text, term: "巨魔", matchCase: false, selection: first.range, forwards: false))
        #expect(previous.range == NSRange(location: 9, length: 2))
        #expect(previous.index == 3)
        let wrapped = try #require(TextSearch.find(text, term: "巨魔", matchCase: false, selection: previous.range, forwards: true))
        #expect(wrapped.range == first.range && wrapped.index == 1)
        let refreshed = try #require(TextSearch.find(text, term: "巨魔", matchCase: false, selection: next.range, forwards: nil))
        #expect(refreshed.range == next.range && refreshed.index == 2)
    }

    @Test func highlightStorageIsBoundedWithoutTruncatingNavigationOrCounts() throws {
        let result = try #require(TextSearch.find("a a a a a", term: "a", matchCase: false,
                                                selection: NSRange(location: 6, length: 1), forwards: true, highlightLimit: 2))
        #expect(result.count == 5 && result.index == 5)
        #expect(result.range == NSRange(location: 8, length: 1))
        #expect(result.highlights == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), result.range])
        let currentOnly = try #require(TextSearch.find("a a", term: "a", matchCase: false,
                                                     selection: NSRange(location: 0, length: 1), forwards: true, highlightLimit: 0))
        #expect(currentOnly.highlights == [NSRange(location: 2, length: 1)])
    }

    @Test func refreshedFindResultsDoNotKeepOldOffsetsOrCaseMatches() throws {
        let selection = NSRange(location: 0, length: 0)
        #expect(TextSearch.find("cat", term: "", matchCase: false, selection: selection, forwards: nil) == nil)
        #expect(TextSearch.find("cat", term: "dog", matchCase: false, selection: selection, forwards: nil) == nil)
        let original = try #require(TextSearch.find("Aa aa", term: "aa", matchCase: false, selection: selection, forwards: nil))
        #expect(original.count == 2)
        let caseChanged = try #require(TextSearch.find("Aa aa", term: "aa", matchCase: true, selection: selection, forwards: nil))
        #expect(caseChanged.count == 1 && caseChanged.range.location == 3)
        let edited = try #require(TextSearch.find("😀 Aa aa", term: "aa", matchCase: true, selection: selection, forwards: nil))
        #expect(edited.range == NSRange(location: 6, length: 2))
        #expect(TextSearch.find("😀 Aa dog", term: "aa", matchCase: true, selection: selection, forwards: nil) == nil)
    }

    @Test func cancelledHighlightRefreshDoesNotPublishAPartialResult() async {
        let refresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return TextSearch.find("a a a", term: "a", matchCase: false,
                                   selection: NSRange(location: 0, length: 0), forwards: nil)
        }
        let result = await refresh.value
        #expect(result == nil)
    }

    @Test func restoredUndoSelectionRemainsTheCurrentMatch() throws {
        let result = try #require(TextSearch.find("cat cat", term: "cat", matchCase: false,
                                                selection: NSRange(location: 4, length: 3), forwards: nil))
        #expect(result.range == NSRange(location: 4, length: 3))
        #expect(result.index == 2 && result.count == 2)
    }

    @Test func replacementUsesOriginalRangesOnlyAndCanDelete() throws {
        let text = "cat cat"
        let ranges = try #require(TextSearch.replacementRanges(text, term: "cat", matchCase: false))
        let expanded = NSMutableString(string: text)
        for range in ranges.reversed() { expanded.replaceCharacters(in: range, with: "catcat") }
        #expect(expanded as String == "catcat catcat")
        let deleted = NSMutableString(string: text)
        for range in ranges.reversed() { deleted.replaceCharacters(in: range, with: "") }
        #expect(deleted as String == " ")
    }

    @Test func replacementBudgetRefusesAnIncompleteBatch() {
        #expect(TextSearch.replacementRanges("a a", term: "a", matchCase: false, limit: 2)?.count == 2)
        #expect(TextSearch.replacementRanges("a a a", term: "a", matchCase: false, limit: 2) == nil)
        #expect(TextSearch.replacementRanges("a", term: "", matchCase: false)?.isEmpty == true)
    }

    @Test func replacementSizeIsCheckedBeforeAllocatingTheResult() throws {
        let ranges = try #require(TextSearch.replacementRanges("😀 😀", term: "😀", matchCase: false))
        #expect(TextSearch.fitsReplacement("😀 😀", ranges: ranges, replacement: "x", byteLimit: 3))
        #expect(!TextSearch.fitsReplacement("😀 😀", ranges: ranges, replacement: "xx", byteLimit: 3))
        #expect(TextSearch.fitsReplacement("😀 😀", ranges: ranges, replacement: "", byteLimit: 1))
    }

    @Test func linearReplacementUsesTheSameOriginalUTF16Ranges() throws {
        let ranges = try #require(TextSearch.replacementRanges("😀 cat cat", term: "cat", matchCase: false))
        #expect(TextSearch.replacing("😀 cat cat", ranges: ranges, with: "catcat", byteLimit: 100) == "😀 catcat catcat")
        #expect(TextSearch.replacing("😀 cat cat", ranges: ranges, with: "", byteLimit: 6) == "😀  ")
        #expect(TextSearch.replacing("😀 cat cat", ranges: ranges, with: "large", byteLimit: 5) == nil)
    }

    @Test func budgetsUseTheOriginalEncodingBOMAndRestoredLineEndings() throws {
        let latin1 = TextEncoding(encoding: .isoLatin1)
        #expect(latin1.byteCount("éé") == 2)
        #expect(latin1.byteCount("中文") == nil)
        let utf16 = TextEncoding(encoding: .utf16LittleEndian, byteOrderMark: Data([0xFF, 0xFE]))
        #expect(utf16.byteCount("aaaa") == 10)
        let utf32 = TextEncoding(encoding: .utf32LittleEndian, byteOrderMark: Data([0xFF, 0xFE, 0, 0]))
        #expect(utf32.byteCount("😀a") == 12)
        #expect(TextEncoding.restoringCRLF("a\nb\r\nc") == "a\r\nb\r\nc")
        #expect(TextEncoding.restoringCRLF("\n") == "\r\n")
        for value in ["", "abc", "é\r\n", "😀"] {
            #expect(utf16.byteCount(value) == utf16.encode(value)?.count)
            #expect(utf32.byteCount(value) == utf32.encode(value)?.count)
        }
    }
}
