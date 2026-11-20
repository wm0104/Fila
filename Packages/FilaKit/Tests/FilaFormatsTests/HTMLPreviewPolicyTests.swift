import FilaFormats
import Foundation
import Testing

@Suite("HTML preview policy")
struct HTMLPreviewPolicyTests {
    private let policy = HTMLPreviewPolicy(host: "session-a")

    @Test
    func `Local names, queries, anchors and Chinese paths stay under the session`() throws {
        let url = try policy.url(relativePath: "子目录/page.htm")
        #expect(try policy.relativePath(for: url) == "子目录/page.htm")
        #expect(try policy.relativePath(for: #require(URL(string: url.absoluteString + "?v=2#标题"))) == "子目录/page.htm")
        #expect(throws: HTMLPreviewPolicy.Failure.self) { try policy.url(relativePath: "../secret") }
        #expect(throws: HTMLPreviewPolicy.Failure.self) { try policy.url(relativePath: "a\0b") }
        #expect(throws: HTMLPreviewPolicy.Failure.self) { try policy.url(relativePath: String(repeating: "a", count: 1024)) }
        #expect(policy.isHTML(url))
        #expect(!policy.isHTML(try policy.url(relativePath: "style.css")))
    }

    @Test(arguments: ["fila-html://session-b/a.html", "file:///etc/passwd", "fila-html://session-a/../secret", "fila-html://session-a/%2e%2e/secret", "fila-html://session-a/%252e%252e/secret", "fila-html://session-a/a%2fb.css", "fila-html://session-a/a%5cb.css", "fila-html://session-a/a%00b", "fila-html://user@session-a/a.html", "fila-html://session-a:80/a.html"])
    func `Foreign roots and ambiguous URL spellings are rejected`(_ spelling: String) throws {
        let url = try #require(URL(string: spelling))
        #expect(throws: (any Error).self) { try policy.relativePath(for: url) }
    }

    @Test
    func `Permissions start off and a new session does not inherit them`() {
        var enabled = HTMLPreviewPermissions()
        #expect(!enabled.javaScript && !enabled.https)
        enabled.javaScript = true
        enabled.https = true
        let next = HTMLPreviewPermissions()
        #expect(!next.javaScript && !next.https)
        #expect(!next.contentSecurityPolicy.contains("https:"))
        #expect(next.contentSecurityPolicy.contains("script-src 'none'"))
        #expect(enabled.contentSecurityPolicy.contains("connect-src 'self' https:"))
        #expect(enabled.contentSecurityPolicy.contains("object-src 'none'"))
        #expect(!enabled.contentSecurityPolicy.contains("http:"))
    }

    @Test
    func `Network rule JSON blocks everything before HTTPS is explicitly allowed`() throws {
        let offline = try #require(JSONSerialization.jsonObject(with: Data(HTMLPreviewPermissions().contentRuleList.utf8)) as? [[String: Any]])
        #expect((offline.first?["action"] as? [String: String])?["type"] == "block")
        let filters = offline.compactMap { ($0["trigger"] as? [String: String])?["url-filter"] }
        #expect(filters == [".*", "^fila-html:", "^data:", "^blob:"])
        var online = HTMLPreviewPermissions()
        online.https = true
        let rules = try #require(JSONSerialization.jsonObject(with: Data(online.contentRuleList.utf8)) as? [[String: Any]])
        #expect(rules.compactMap { ($0["trigger"] as? [String: String])?["url-filter"] } == filters + ["^https:"])
    }

    @Test(arguments: ["https://example.org/page", "https://example.org/中文", "https://example.org/page?x=1#section"])
    func `Confirmed in-app Safari handoff accepts HTTPS only`(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(HTMLPreviewPolicy.externalURL(url) == url)
    }

    @Test(arguments: ["http://example.org", "https://user:password@example.org", "javascript:alert(1)", "mailto:a@example.org", "fila://open", "file:///private/tmp/page.html", "data:text/html,hi", "https://example.org/tool.deb", "https://example.org/tool.sh", "https://example.org/tool.IPA?download=1", "https://example.org/profile.mobileconfig#install"])
    func `App schemes, credentials and executable downloads are not browser links`(_ value: String) throws {
        #expect(HTMLPreviewPolicy.externalURL(try #require(URL(string: value))) == nil)
    }
}
