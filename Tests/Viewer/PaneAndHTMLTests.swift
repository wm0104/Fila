#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing

@Suite struct PaneAndHTMLTests {
    @Test(arguments: [CGFloat(304), 737])
    func dividerTracksTheUsableHeight(height: CGFloat) {
        let top: CGFloat = 47, bottom = top + height
        let pair = PaneLayout(top: top, bottom: bottom, fraction: 0.5)
        #expect(pair.dividerHeight == 20)
        #expect(pair.available == height - pair.dividerHeight)
        let upper = pair.dividerTop - top, lower = bottom - pair.dividerTop - pair.dividerHeight
        #expect(abs(upper - lower) <= 1)
        let small = PaneLayout(top: top, bottom: bottom, fraction: -1)
        let large = PaneLayout(top: top, bottom: bottom, fraction: 2)
        #expect(small.dividerTop == top + (pair.available * 0.22).rounded())
        #expect(large.dividerTop == top + (pair.available * 0.78).rounded())
        #expect(small.dividerTop > top && large.dividerTop + large.dividerHeight < bottom)
    }

    @Test func noUsableHeightDuringLayout() {
        let pair = PaneLayout(top: 10, bottom: 0, fraction: 0.5)
        #expect(pair.available == 0 && pair.dividerHeight == 0 && pair.dividerTop == 10)
    }

    @Test(arguments: [DocumentPreviewPolicy.offlineHTML, .interactiveHTML, .office])
    func eachViewerGetsOnlyItsOwnResources(policy: DocumentPreviewPolicy) throws {
        struct Rule: Decodable {
            let trigger, action: [String: String]
        }
        let rules = try JSONDecoder().decode([Rule].self, from: Data(policy.contentRules(documentScheme: "fila-document").utf8))
        #expect(rules.first?.trigger["url-filter"] == ".*" && rules.first?.action["type"] == "block")
        #expect(rules.dropFirst().allSatisfy { $0.action["type"] == "ignore-previous-rules" })
        var allowed: Set<String> = ["^fila-document:", "^data:"]
        switch policy {
        case .office: allowed.formUnion(["^x-apple-ql-id:", "^about:", "^blob:"])
        case .interactiveHTML: allowed.insert("^https:")
        case .offlineHTML: break
        }
        #expect(Set(rules.dropFirst().compactMap { $0.trigger["url-filter"] }) == allowed)
        #expect(policy.allowsScripts == (policy != .offlineHTML))
        guard policy != .office else { #expect(policy.contentSecurityPolicy == nil); return }
        let csp = try #require(policy.contentSecurityPolicy).components(separatedBy: "; ")
        let interactive = policy == .interactiveHTML
        #expect(csp.contains(interactive ? "sandbox allow-scripts" : "sandbox"))
        #expect(csp.contains(interactive ? "connect-src https:" : "connect-src 'none'"))
        #expect(csp.contains(interactive ? "script-src 'unsafe-inline' https:" : "script-src 'none'"))
        #expect(csp.contains("frame-src 'none'") && csp.contains("form-action 'none'") && csp.contains("default-src 'none'"))
    }
}
