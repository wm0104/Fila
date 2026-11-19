#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing

@Suite struct PaneAndHTMLTests {
    @Test(arguments: [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)])
    func dividerTracksTheUsableArea(size: CGSize) {
        let area = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 44)
        let pair = PaneLayout(region: area, host: size, fraction: 0.5)
        let first = pair.headings[0].union(pair.lists[0]), second = pair.headings[1].union(pair.lists[1])
        #expect(first.union(pair.divider).union(second) == area)
        #expect(!first.intersects(second))
        if size.width > size.height {
            #expect(pair.horizontal && first.maxX == pair.divider.minX && second.minX == pair.divider.maxX)
            #expect(abs(first.width - second.width) <= 1)
        } else {
            #expect(!pair.horizontal && first.maxY == pair.divider.minY && second.minY == pair.divider.maxY)
            #expect(abs(first.height - second.height) <= 1)
        }
        let small = PaneLayout(region: area, host: size, fraction: -1)
        let large = PaneLayout(region: area, host: size, fraction: 2)
        #expect(small.divider == PaneLayout(region: area, host: size, fraction: 0.22).divider)
        #expect(large.divider == PaneLayout(region: area, host: size, fraction: 0.78).divider)
        #expect(pair.horizontal ? small.divider.minX < large.divider.minX : small.divider.minY < large.divider.minY)
        #expect(!small.lists[0].isEmpty && !large.lists[1].isEmpty)
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
