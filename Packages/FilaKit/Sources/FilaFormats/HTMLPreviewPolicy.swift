import Foundation

/// Independent from the Office converter. Permissions are values owned by one
/// live preview, never preferences, a global cache or a daemon capability.
public struct HTMLPreviewPermissions: Sendable, Equatable {
    public var javaScript = false
    public var https = false

    public init() {}

    /// A block-all list with only the explicitly supported transports restored.
    /// Installed before the first WK request, including with JavaScript disabled.
    public var contentRuleList: String {
        let schemes = [HTMLPreviewPolicy.scheme, "data", "blob"] + (https ? ["https"] : [])
        let block = #"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#
        let allow = schemes.map { #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"ignore-previous-rules"}}"# }
        return "[" + ([block] + allow).joined(separator: ",") + "]"
    }

    public var contentSecurityPolicy: String {
        let network = https ? " https:" : ""
        let script = javaScript ? "'self' 'unsafe-inline'" + network : "'none'"
        return "default-src 'none'; img-src 'self' data:" + network
            + "; style-src 'self' 'unsafe-inline'" + network
            + "; font-src 'self' data:" + network
            + "; media-src 'self' data:" + network
            + "; script-src " + script
            + "; connect-src 'self'" + network
            + "; frame-src 'self'; object-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'self'"
    }
}

/// A URL names a resource relative to the *original* directory, not an absolute
/// filesystem path. Every renderer gets a random host; no URL grants a new root.
public struct HTMLPreviewPolicy: Sendable {
    public static let scheme = "fila-html"
    public let host: String

    public init(host: String = UUID().uuidString.lowercased()) {
        self.host = host
    }

    public enum Failure: Error { case invalidResource }

    public func url(relativePath: String) throws -> URL {
        try Self.validate(relativePath)
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = host
        parts.path = "/" + relativePath
        guard let url = parts.url else { throw Failure.invalidResource }
        return url
    }

    public func relativePath(for url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme, parts.host == host,
              parts.user == nil, parts.password == nil, parts.port == nil else { throw Failure.invalidResource }
        let encoded = parts.percentEncodedPath
        // Split *before* decoding, exactly once. A decoded slash/backslash or a
        // remaining percent cannot be reinterpreted by a second URL/file layer.
        let components = encoded.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components.first?.isEmpty == true else { throw Failure.invalidResource }
        let names = try components.dropFirst().map { component -> String in
            guard let decoded = String(component).removingPercentEncoding,
                  !decoded.utf8.contains(47) else { throw Failure.invalidResource }
            try Self.validate(decoded)
            return decoded
        }
        let path = names.joined(separator: "/")
        try Self.validate(path)
        return path
    }

    private static func validate(_ path: String) throws {
        let bytes = path.utf8
        guard !bytes.isEmpty, bytes.count < 1024,
              !bytes.contains(where: { $0 < 32 || $0 == 127 || $0 == 37 || $0 == 92 }) else { throw Failure.invalidResource }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalidResource }
    }

    public func isHTML(_ url: URL) -> Bool {
        guard let path = try? relativePath(for: url) else { return false }
        return ["html", "htm"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Only explicit HTTPS browser links, never a custom-app scheme or a known
    /// executable/package download. The WK view itself never downloads anything.
    public static func externalURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let path = url.path.removingPercentEncoding else { return nil }
        let blocked = ["deb", "ipa", "tipa", "dylib", "so", "exe", "sh", "bash", "zsh", "command", "app", "pkg", "mobileconfig"]
        guard !blocked.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return url
    }

    public static func mimeType(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js", "mjs": "text/javascript"
        case "json": "application/json"
        case "txt": "text/plain"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "avif": "image/avif"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: nil
        }
    }
}
