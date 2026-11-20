import FilaFormats
import FilaLog
import FilaProtocol
import Foundation
import WebKit

/// No filesystem URL is exposed to WebKit. The handler can serve only a regular
/// resource under its immutable directory; the daemon sees opens, never bytes.
@MainActor
final class HTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    let policy: HTMLPreviewPolicy
    private let directory: HTMLPreviewDirectory
    private let document: HTMLPreviewDocument
    private let permissions: HTMLPreviewPermissions
    private let queue = DispatchQueue(label: "wiki.qaq.fila.html-reader", qos: .userInitiated)
    private var loads: [ObjectIdentifier: Load] = [:]
    private var invalidated = false
    var onFailure: (() -> Void)?

    init(directory: HTMLPreviewDirectory, document: HTMLPreviewDocument, policy: HTMLPreviewPolicy, permissions: HTMLPreviewPermissions) {
        self.directory = directory
        self.document = document
        self.policy = policy
        self.permissions = permissions
    }

    func invalidate() {
        invalidated = true
        for load in loads.values { load.stop() }
        loads.removeAll()
        onFailure = nil
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard !invalidated else { task.didFailWithError(URLError(.cancelled)); return }
        do {
            guard let url = task.request.url, task.request.httpMethod == nil || task.request.httpMethod == "GET" else {
                throw HTMLPreviewPolicy.Failure.invalidResource
            }
            let path = try policy.relativePath(for: url)
            guard let mime = HTMLPreviewPolicy.mimeType(for: path), loads.count < 64 else {
                throw HTMLPreviewPolicy.Failure.invalidResource
            }
            let key = ObjectIdentifier(task)
            let load = Load()
            loads[key] = load
            let directory = directory
            let document = document
            load.opening = Task { [weak self] in
                do {
                    let file: DescriptorFile
                    if path == document.relativePath {
                        // Detection, menu identity and the main response all use
                        // the opened inode, even if its name was replaced meanwhile.
                        file = try DescriptorFile(descriptor: document.file.duplicate())
                    } else {
                        file = try await directory.open(path).file
                    }
                    guard let self, !load.isStopped, !invalidated, loads[key] === load else {
                        file.close()
                        return
                    }
                    try PreviewLimits.validate(byteCount: file.byteCount, format: .html)
                    var headers = [
                        // Bytes are not transcoded. An invented charset would
                        // override HTML meta/CSS @charset declarations.
                        "Content-Type": mime,
                        "Content-Length": String(file.byteCount),
                        "Content-Security-Policy": permissions.contentSecurityPolicy,
                        "X-Content-Type-Options": "nosniff",
                        "Cache-Control": "no-store",
                        "Referrer-Policy": "no-referrer",
                    ]
                    headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), display-capture=()"
                    guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
                        throw HTMLPreviewPolicy.Failure.invalidResource
                    }
                    task.didReceive(response)
                    stream(file, load: load, task: task)
                } catch {
                    self?.fail(task, load: load, error: error)
                }
            }
        } catch {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            FilaLog.info("HTML resource rejected: URL, method, type or concurrency limit")
            onFailure?()
        }
    }

    func webView(_: WKWebView, stop task: WKURLSchemeTask) {
        loads.removeValue(forKey: ObjectIdentifier(task))?.stop()
    }

    private func fail(_ task: WKURLSchemeTask, load: Load, error: Error) {
        guard !load.isStopped, loads.removeValue(forKey: ObjectIdentifier(task)) === load else { return }
        load.stop()
        // Never log supplied URLs, private paths, script text or credentials.
        let code = (error as? FilaFailure)?.systemError ?? Int32(clamping: (error as NSError).code)
        FilaLog.info("HTML resource open/read failed code=\(code)")
        task.didFailWithError(URLError(.cannotLoadFromNetwork))
        onFailure?()
    }

    private func stream(_ file: DescriptorFile, load: Load, task: WKURLSchemeTask) {
        queue.async { [weak self] in
            defer { file.close() }
            let slots = DispatchSemaphore(value: 4)
            var offset: Int64 = 0
            while !load.isStopped {
                slots.wait()
                guard !load.isStopped else { slots.signal(); return }
                let result: Result<Data, Error>
                do {
                    let bytes = try file.read(at: offset, count: 256 * 1024)
                    if bytes.isEmpty, offset < file.byteCount { throw ViewerFailure.readFailed(EIO) }
                    result = .success(bytes)
                    offset += Int64(bytes.count)
                } catch {
                    result = .failure(error)
                }
                let last = offset >= file.byteCount
                DispatchQueue.main.async {
                    defer { slots.signal() }
                    let key = ObjectIdentifier(task)
                    guard let self, !load.isStopped, self.loads[key] === load else { return }
                    switch result {
                    case let .success(bytes):
                        if !bytes.isEmpty { task.didReceive(bytes) }
                        // A receive callback may synchronously stop this task.
                        guard !load.isStopped, self.loads[key] === load else { return }
                        if last {
                            self.loads.removeValue(forKey: key)
                            load.stop()
                            task.didFinish()
                        }
                    case let .failure(error): self.fail(task, load: load, error: error)
                    }
                }
                if last { return }
                if case .failure = result { return }
            }
        }
    }

    private final class Load: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var opening: Task<Void, Never>?
        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            opening?.cancel()
            opening = nil
        }
    }
}
