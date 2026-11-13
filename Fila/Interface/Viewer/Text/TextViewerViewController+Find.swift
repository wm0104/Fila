import RunestoneEditor
import UIKit

extension TextViewerViewController {
    // MARK: - Find

    func toggleFind() {
        findBar.isHidden.toggle()
        if findBar.isHidden {
            findBar.endEditing(true)
            clearFindResult()
        } else {
            findBar.becomeFirstResponderOnField()
        }
    }

    func find(_ term: String, forwards: Bool) {
        findRefreshTask?.cancel()
        guard !term.isEmpty else { return clearFindResult() }
        activeFindTerm = term
        let result = TextSearch.find(textView.text, term: term, matchCase: matchesCase,
                                     selection: textView.selectedRange, forwards: forwards)
        showFindResult(result)
        guard let result else { return }
        textView.selectedRange = result.range
        textView.scrollRangeToVisible(result.range)
    }

    func clearFindResult() {
        findRefreshTask?.cancel()
        activeFindTerm = nil
        findResult = nil
        textView.highlightedRanges = []
        findBar.showResult(nil)
    }

    func refreshFindHighlights(inBackground: Bool = false) {
        findRefreshTask?.cancel()
        guard !findBar.isHidden, let term = activeFindTerm, term == findBar.term else {
            return clearFindResult()
        }
        let text = textView.text
        let matchCase = matchesCase
        // Old offsets must disappear immediately, even while a large edit is searched.
        findResult = nil
        textView.highlightedRanges = []
        findBar.showResult(nil)
        if !inBackground {
            showFindResult(TextSearch.find(text, term: term, matchCase: matchCase,
                                           selection: textView.selectedRange, forwards: nil))
            return
        }
        findRefreshTask = Task { @MainActor [weak self] in
            // Runestone restores the Undo selection after its text-change callback returns.
            guard !Task.isCancelled, let selection = self?.textView.selectedRange else { return }
            let search = Task.detached(priority: .userInitiated) {
                TextSearch.find(text, term: term, matchCase: matchCase, selection: selection, forwards: nil)
            }
            let result = await withTaskCancellationHandler {
                await search.value
            } onCancel: {
                search.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.showFindResult(result)
        }
    }

    private func showFindResult(_ result: TextSearch.Result?) {
        findResult = result
        drawFindHighlights()
        if let result {
            findBar.showResult(String(format: String(localized: "%lld of %lld"), Int64(result.index), Int64(result.count)))
        } else {
            findBar.showResult(String(localized: "No results"))
        }
    }

    func drawFindHighlights() {
        guard let result = findResult else { textView.highlightedRanges = []; return }
        let normal = UIColor.systemYellow.resolvedColor(with: traitCollection).withAlphaComponent(0.25)
        let current = UIColor.systemOrange.resolvedColor(with: traitCollection).withAlphaComponent(0.55)
        textView.highlightedRanges = result.highlights.map {
            HighlightedRange(range: $0, color: $0 == result.range ? current : normal, cornerRadius: 5)
        }
    }

    func replace(_ term: String, with replacement: String, all: Bool) {
        guard canReplaceText, !term.isEmpty else { return }
        findRefreshTask?.cancel()
        let highlightedRange = activeFindTerm == term ? findResult?.range : nil
        activeFindTerm = term
        let selection = textView.selectedRange
        let ranges: [NSRange]
        if all {
            guard let batch = TextSearch.replacementRanges(textView.text, term: term, matchCase: matchesCase) else {
                presentMessage(
                    String(localized: "Unable to Replace"),
                    message: String(localized: "Too many matches to replace at once. Use a more specific search."),
                )
                return
            }
            ranges = batch
        } else {
            guard let current = TextSearch.replacementRange(textView.text, term: term, matchCase: matchesCase,
                                                            highlightedRange: highlightedRange, selection: selection) else {
                find(term, forwards: true)
                return
            }
            ranges = [current]
        }
        guard !ranges.isEmpty else {
            showFindResult(nil)
            return
        }
        guard let projected = validatedReplacement(ranges, with: replacement) else { return }
        if (projected as NSString) != (textView.text as NSString) {
            if !all { textView.selectedRange = ranges[0] }
            // setState records one native Undo without the batch setter's recursive undo-group closure.
            apply(text: projected, addUndoAction: true)
        }
        if all {
            refreshFindHighlights()
            findBar.showResult(String(localized: "\(ranges.count) replacements"))
        } else {
            textView.selectedRange = NSRange(location: ranges[0].location + replacement.utf16.count, length: 0)
            find(term, forwards: true)
        }
        refreshBarItems()
    }
}
