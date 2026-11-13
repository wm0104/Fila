import Foundation

/// Validates user-entered download addresses before Foundation can repair them.
public enum DownloadURL {
    public static func parse(_ text: String) -> URL? {
        // URL(string:) can percent-encode controls and accept a second scheme
        // as the host. Neither is a safe interpretation of pasted input.
        guard !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let address = text.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty,
              !address.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              address.range(of: #"^https?://https?://"#, options: [.regularExpression, .caseInsensitive]) == nil,
              let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.port.map({ (0 ... 65535).contains($0) }) ?? true,
              let url = components.url else { return nil }
        return url
    }
}
