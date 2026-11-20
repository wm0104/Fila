import CoreFoundation
import FilaProtocol
import Foundation

/// Packaging opts in to one extra document action, never to a backend identity.
enum SileoOpenPolicy {
    static func offers(path: String, kind: FileKind, info: [String: Any]) -> Bool {
        guard let flag = info["FilaOffersSileoOpen"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else { return false }
        return kind == .regular && (path as NSString).pathExtension.lowercased() == "deb"
    }
}
