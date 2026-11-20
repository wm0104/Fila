import Darwin
import FilaProtocol
import XPC

/// A preview path must survive Swift-to-C conversion without changing its name.
/// Validate before send builds a dictionary or duplicates a root capability;
/// FileOperations still checks the remaining directory/resource path grammar.
struct PreviewRequestPath {
    private let value: String

    init(_ value: String) throws {
        guard !value.utf8.contains(0) else {
            throw FilaFailure(code: .invalidRequest, systemError: EINVAL)
        }
        self.value = value
    }

    func encode(into request: xpc_object_t) {
        xpc_dictionary_set_string(request, FilaWireKey.path, value)
    }
}
