#if canImport(XPC)
    import Darwin
    import FilaClient
    @testable import FilaPrivileged
    import FilaProtocol
    import Testing
    import XPC

    /// Exercise the production request-field writer and the real privileged
    /// LocalFileAccess implementation, not the local filesystem substitute.
    /// These are host-harness tests; no daemon is registered on the Mac.
    @Suite("Preview request C-string boundary")
    struct PreviewRequestPathTests {
        @Test(arguments: ["/", "/private/中文", "index.html", "pages/e\u{301}.htm"])
        func `A validated path reaches an actual XPC dictionary unchanged`(_ path: String) throws {
            let request = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(request, FilaWireKey.operation, FilaOperation.openPreviewResource.rawValue)
            try PreviewRequestPath(path).encode(into: request)
            let encoded = try #require(xpc_dictionary_get_string(request, FilaWireKey.path))
            #expect(Array(String(cString: encoded).utf8) == Array(path.utf8))
            #expect(xpc_dictionary_get_uint64(request, FilaWireKey.operation) == FilaOperation.openPreviewResource.rawValue)
        }

        @Test(arguments: [
            "/private\u{0}/../outside", "/\u{0}", "index.html\u{0}/../outside",
            "pages/second.htm\u{0}", "\u{0}index.html",
        ])
        func `NUL refuses the request field before its C setter can replace a value`(_ path: String) throws {
            let request = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(request, FilaWireKey.path, "untouched.html")
            let failure = #expect(throws: FilaFailure.self) {
                try PreviewRequestPath(path).encode(into: request)
            }
            #expect(failure?.code == .invalidRequest)
            #expect(failure?.systemError == EINVAL)
            let encoded = try #require(xpc_dictionary_get_string(request, FilaWireKey.path))
            #expect(String(cString: encoded) == "untouched.html")
        }

        @Test(arguments: ["/private\u{0}/../outside", "/\u{0}", "\u{0}/private"])
        func `Directory capture rejects NUL before constructing or sending a privileged request`(_ path: String) async throws {
            let service = DaemonFileService(streams: FileEventStreams())
            defer { service.invalidate() }
            let link: any LocalFileAccess = service
            let failure = await #expect(throws: FilaFailure.self) {
                let descriptor = try await link.openPreviewDirectory(path)
                close(descriptor)
            }
            #expect(failure?.code == .invalidRequest)
            #expect(failure?.systemError == EINVAL)
            // The first explicitly requested connection must still be the first
            // generation: rejection must not have entered the transport. Without
            // the guard, send fills a truncated path before making a connection.
            #expect(try service.activeConnection().generation == 1)
        }

        @Test(arguments: ["index.html\u{0}/../outside", "pages/second.htm\u{0}", "\u{0}index.html"])
        func `Resource capture rejects NUL before duplicating the borrowed capability into a request`(_ path: String) async throws {
            let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            try #require(root >= 0)
            defer { close(root) }
            let service = DaemonFileService(streams: FileEventStreams())
            defer { service.invalidate() }
            let link: any LocalFileAccess = service
            let failure = await #expect(throws: FilaFailure.self) {
                let resource = try await link.openPreviewResource(root: root, relativePath: path)
                close(resource.descriptor)
            }
            #expect(failure?.code == .invalidRequest)
            #expect(failure?.systemError == EINVAL)
            #expect(fcntl(root, F_GETFD) >= 0)
            #expect(try service.activeConnection().generation == 1)
        }
    }
#endif
