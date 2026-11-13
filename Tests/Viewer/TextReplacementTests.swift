import Foundation
import Testing

struct TextReplacementTests {
    private let utf8 = TextEncoding(encoding: .utf8)

    @Test
    func currentHighlightWinsOverTheReplacementFieldsSelection() throws {
        let prepared = try #require(try TextReplacement.prepare(
            "1 1", term: "1", with: "2", matchCase: false,
            target: .current(highlightedRange: NSRange(location: 0, length: 1), selection: NSRange(location: 2, length: 1)),
            encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 100,
        ).get())
        #expect(prepared.text == "2 1")
        #expect(prepared.ranges == [NSRange(location: 0, length: 1)])
    }

    @Test
    func staleOrCaseMismatchedCurrentRangesAreNotApplied() throws {
        let stale = TextReplacement.prepare(
            "😀cafe\u{301} café", term: "café", with: "x", matchCase: false,
            target: .current(highlightedRange: NSRange(location: 2, length: 4), selection: NSRange(location: 8, length: 4)),
            encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 100,
        )
        #expect(try stale.get() == nil)
        let caseChanged = TextReplacement.prepare(
            "Aa aa", term: "aa", with: "x", matchCase: true,
            target: .current(highlightedRange: NSRange(location: 0, length: 2), selection: NSRange(location: 3, length: 2)),
            encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 100,
        )
        #expect(try caseChanged.get() == nil)
    }

    @Test
    func currentSelectionKeepsOriginalUTF16MatchLengths() throws {
        let prepared = try #require(try TextReplacement.prepare(
            "😀cafe\u{301} café", term: "café", with: "X", matchCase: false,
            target: .current(highlightedRange: nil, selection: NSRange(location: 2, length: 5)),
            encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 100,
        ).get())
        #expect(prepared.text == "😀X café")
        #expect(prepared.ranges == [NSRange(location: 2, length: 5)])
    }

    @Test
    func allReplacementsUseOriginalUTF16RangesAndCanDelete() throws {
        let prepared = try #require(try TextReplacement.prepare(
            "😀 cat cat", term: "cat", with: "catcat", matchCase: false, target: .all,
            encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 100,
        ).get())
        #expect(prepared.text == "😀 catcat catcat")
        #expect(prepared.ranges == [NSRange(location: 3, length: 3), NSRange(location: 7, length: 3)])
        let deleted = try #require(try TextReplacement.prepare(
            "😀 cat cat", term: "cat", with: "", matchCase: false, target: .all,
            encoding: utf8, usesCRLF: false, byteLimit: 6, lineByteLimit: 100,
        ).get())
        #expect(deleted.text == "😀  ")
    }

    @Test
    func allReplacementRefusesAnIncompleteBatch() {
        #expect(throws: TextReplacement.Failure.tooManyMatches) {
            try TextReplacement.prepare(
                String(repeating: "a", count: 100_001), term: "a", with: "b", matchCase: true, target: .all,
                encoding: utf8, usesCRLF: false, byteLimit: 200_000, lineByteLimit: 200_000,
            ).get()
        }
    }

    @Test
    func noMatchesDoNotProduceAReplacement() throws {
        let result = TextReplacement.prepare(
            "abc", term: "missing", with: "x", matchCase: true, target: .all,
            encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 100,
        )
        #expect(try result.get() == nil)
    }

    @Test
    func utf8AllocationBudgetAndOriginalEncodingAreBothRequired() throws {
        let latin1 = TextEncoding(encoding: .isoLatin1)
        let fits = try #require(try TextReplacement.prepare(
            "éé", term: "é", with: "éé", matchCase: true, target: .all,
            encoding: latin1, usesCRLF: false, byteLimit: 4, lineByteLimit: 100,
        ).get())
        #expect(fits.text == "éééé")
        #expect(throws: TextReplacement.Failure.unsupportedEncoding) {
            try TextReplacement.prepare(
                "a", term: "a", with: "😀", matchCase: true, target: .all,
                encoding: latin1, usesCRLF: false, byteLimit: 10, lineByteLimit: 100,
            ).get()
        }
        #expect(throws: TextReplacement.Failure.tooLarge) {
            try TextReplacement.prepare(
                "aa", term: "a", with: "😀", matchCase: true, target: .all,
                encoding: utf8, usesCRLF: false, byteLimit: 1, lineByteLimit: 100,
            ).get()
        }
    }

    @Test(arguments: [
        TextEncoding(encoding: .utf8, byteOrderMark: Data([0xEF, 0xBB, 0xBF])),
        TextEncoding(encoding: .utf16LittleEndian, byteOrderMark: Data([0xFF, 0xFE])),
        TextEncoding(encoding: .utf32LittleEndian, byteOrderMark: Data([0xFF, 0xFE, 0, 0])),
    ])
    func savedByteBudgetIncludesTheOriginalEncodingAndBOM(_ encoding: TextEncoding) throws {
        let byteCount = try #require(encoding.encode("ab")).count
        let fits = try #require(try TextReplacement.prepare(
            "a", term: "a", with: "ab", matchCase: true, target: .all,
            encoding: encoding, usesCRLF: false, byteLimit: byteCount, lineByteLimit: 100,
        ).get())
        #expect(fits.text == "ab")
        #expect(throws: TextReplacement.Failure.tooLarge) {
            try TextReplacement.prepare(
                "a", term: "a", with: "ab", matchCase: true, target: .all,
                encoding: encoding, usesCRLF: false, byteLimit: byteCount - 1, lineByteLimit: 100,
            ).get()
        }
    }

    @Test
    func restoredCRLFCountsOnDiskButDoesNotChangeTheEditorString() throws {
        let fits = try #require(try TextReplacement.prepare(
            "a\nb", term: "a", with: "aa", matchCase: true, target: .all,
            encoding: utf8, usesCRLF: true, byteLimit: 5, lineByteLimit: 100,
        ).get())
        #expect(fits.text == "aa\nb")
        #expect(throws: TextReplacement.Failure.tooLarge) {
            try TextReplacement.prepare(
                "a\nb", term: "a", with: "aa", matchCase: true, target: .all,
                encoding: utf8, usesCRLF: true, byteLimit: 4, lineByteLimit: 100,
            ).get()
        }
    }

    @Test
    func originalEncodingBOMAndCRLFAreOneCombinedDiskBudget() throws {
        let encoding = TextEncoding(encoding: .utf16LittleEndian, byteOrderMark: Data([0xFF, 0xFE]))
        let byteCount = try #require(encoding.encode("aa\r\nb")).count
        #expect(byteCount == 12)
        let fits = try #require(try TextReplacement.prepare(
            "a\nb", term: "a", with: "aa", matchCase: true, target: .all,
            encoding: encoding, usesCRLF: true, byteLimit: byteCount, lineByteLimit: 100,
        ).get())
        #expect(fits.text == "aa\nb")
        #expect(throws: TextReplacement.Failure.tooLarge) {
            try TextReplacement.prepare(
                "a\nb", term: "a", with: "aa", matchCase: true, target: .all,
                encoding: encoding, usesCRLF: true, byteLimit: byteCount - 1, lineByteLimit: 100,
            ).get()
        }
    }

    @Test
    func joiningLinesStillHonorsTheEngineLineBudget() throws {
        #expect(throws: TextReplacement.Failure.tooLarge) {
            try TextReplacement.prepare(
                "aa\naa", term: "\n", with: "", matchCase: true, target: .all,
                encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 3,
            ).get()
        }
        let fits = try #require(try TextReplacement.prepare(
            "aa\naa", term: "\n", with: "", matchCase: true, target: .all,
            encoding: utf8, usesCRLF: false, byteLimit: 100, lineByteLimit: 4,
        ).get())
        #expect(fits.text == "aaaa")
    }
}
