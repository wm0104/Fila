import Foundation

/// The Office converter needs its own scripts and internal URLs. HTML starts
/// offline. Its opt-in applies to one viewer, never to an origin or a path.
enum DocumentPreviewPolicy: String {
    case office, offlineHTML, interactiveHTML

    var allowsScripts: Bool { self != .offlineHTML }

    /// A response header, not a <meta> appended to someone else's markup.
    /// The HTML page has an opaque origin and no frames, forms or workers.
    var contentSecurityPolicy: String? {
        guard self != .office else { return nil }
        let remote = self == .interactiveHTML ? " https:" : ""
        let script = allowsScripts ? "'unsafe-inline' https:" : "'none'"
        return [
            "sandbox" + (allowsScripts ? " allow-scripts" : ""), "default-src 'none'",
            "base-uri 'none'", "form-action 'none'", "frame-src 'none'", "worker-src 'none'",
            "script-src \(script)", "connect-src " + (allowsScripts ? "https:" : "'none'"),
            "img-src data:\(remote)", "media-src data:\(remote)", "font-src data:\(remote)",
            "style-src 'unsafe-inline'\(remote)",
        ].joined(separator: "; ")
    }

    /// WebKit's navigation delegate does not see subresources. Start blocked,
    /// then admit just the schemes needed by this kind of page.
    func contentRules(documentScheme: String) -> String {
        var schemes = [documentScheme, "data"]
        switch self {
        case .office: schemes += ["x-apple-ql-id", "about", "blob"]
        case .interactiveHTML: schemes.append("https")
        case .offlineHTML: break
        }
        let block = #"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#
        let allow = schemes.map { #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"ignore-previous-rules"}}"# }
        return "[" + ([block] + allow).joined(separator: ",") + "]"
    }
}
