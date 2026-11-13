import Foundation

/// Prepares a complete replacement that the editor can apply and the file can save.
enum TextReplacement {
    enum Target {
        case current(highlightedRange: NSRange?, selection: NSRange)
        case all
    }

    struct Prepared {
        let text: String
        let ranges: [NSRange]
    }

    enum Failure: Error, Equatable {
        case tooManyMatches
        case tooLarge
        case unsupportedEncoding
    }

    static func prepare(
        _ text: String,
        term: String,
        with replacement: String,
        matchCase: Bool,
        target: Target,
        encoding: TextEncoding,
        usesCRLF: Bool,
        byteLimit: Int,
        lineByteLimit: Int,
    ) -> Result<Prepared?, Failure> {
        let ranges: [NSRange]
        switch target {
        case .all:
            guard let batch = TextSearch.replacementRanges(text, term: term, matchCase: matchCase) else {
                return .failure(.tooManyMatches)
            }
            ranges = batch
        case let .current(highlightedRange, selection):
            guard let current = TextSearch.replacementRange(text, term: term, matchCase: matchCase,
                                                            highlightedRange: highlightedRange, selection: selection) else {
                return .success(nil)
            }
            ranges = [current]
        }
        guard !ranges.isEmpty else { return .success(nil) }
        // The editor's UTF-8 allocation and the original on-disk encoding have separate budgets.
        guard let projected = TextSearch.replacing(text, ranges: ranges, with: replacement, byteLimit: byteLimit * 4,
                                                   lineByteLimit: lineByteLimit) else {
            return .failure(.tooLarge)
        }
        let saved = usesCRLF ? TextEncoding.restoringCRLF(projected) : projected
        guard let count = encoding.byteCount(saved) else { return .failure(.unsupportedEncoding) }
        guard count <= byteLimit else { return .failure(.tooLarge) }
        return .success(Prepared(text: projected, ranges: ranges))
    }
}
