import FilaRemote
import Foundation
import Testing

@Suite("Download addresses")
struct DownloadURLTests {
    @Test(arguments: [
        "http://example.com/file.deb",
        "https://example.com/file.deb?download=1#part",
        "HTTPS://example.com/file.deb",
        "http://localhost:8080/file",
        "https://example.com:443/file",
        "http://127.0.0.1:0/file",
        "http://[::1]:8080/file",
        "https://[2001:db8::1]/file",
        "http://user:password@example.com:8080/file",
        "https://example.com/a%20b?target=https://other.example/path",
    ])
    func `HTTP and HTTPS addresses retain their components`(_ address: String) throws {
        let url = try #require(DownloadURL.parse(address))
        #expect(url == URL(string: address))
    }

    @Test
    func `Surrounding spaces are trimmed without changing the link`() {
        #expect(DownloadURL.parse("  https://example.com/file  ")?.absoluteString == "https://example.com/file")
    }

    @Test(arguments: [
        "", "   ", "https://", "http://", "example.com/file", "/file",
        "file:///etc/hosts", "ftp://example.com/file", "javascript:alert(1)",
        "https://https://github.com/wm0104/Fila",
        "http://https://example.com/file", "HTTPS://HTTP://example.com/file",
        "https://:443/file", "https://example.com:65536/file",
        "https://example.com:-1/file", "https://example.com:abc/file",
        "https://[::1/file", "https://exam ple.com/file", "https://example.com/a b",
        "https://example.com/\nfile", "https://example.com/\rfile",
        "https://example.com/\tfile", "https://example.com/\0file",
        "https://example.com/\u{7F}file", "\nhttps://example.com/file",
    ])
    func `Invalid input is rejected before making a request`(_ address: String) {
        #expect(DownloadURL.parse(address) == nil)
    }

    @Test
    func `Fetch also rejects a repeated scheme before creating staging`() async throws {
        let url = try #require(URL(string: "https://https://example.com/file"))
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-invalid-download-\(UUID().uuidString)")
        await #expect(throws: URLError(.badURL)) {
            try await URLDownload.fetch(url, into: staging) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test
    func `Fetch keeps rejecting non HTTP sources before creating staging`() async {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("fila-invalid-download-\(UUID().uuidString)")
        await #expect(throws: URLDownload.Failure.unsupportedScheme) {
            try await URLDownload.fetch(URL(fileURLWithPath: "/etc/hosts"), into: staging) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
}
