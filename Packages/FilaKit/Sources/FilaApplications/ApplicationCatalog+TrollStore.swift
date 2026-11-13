import FilaBackendKit
import FilaLog
import Foundation
import ObjectiveC

@objc private protocol DocumentOpening {
    @objc(operationToOpenResource:usingApplication:uniqueDocumentIdentifier:userInfo:delegate:)
    func operation(toOpenResource url: URL, usingApplication identifier: String, uniqueDocumentIdentifier: String?, userInfo: [String: Any]?, delegate: NSObject) -> Operation?
}

extension ApplicationCatalog {
    /// A targeted local document payload, not the remote-download URL scheme.
    /// The receiver consumes the copy; the source must never be passed here.
    @MainActor
    public static func openInTrollStore(packageAt url: URL) async -> TrollStoreHandoffOutcome {
        guard url.isFileURL, ["ipa", "tipa"].contains(url.pathExtension.lowercased()),
              let workspaceType = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              workspaceType.responds(to: NSSelectorFromString("defaultWorkspace")),
              let workspace = workspaceType.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
              workspace.responds(to: #selector(DocumentOpening.operation(toOpenResource:usingApplication:uniqueDocumentIdentifier:userInfo:delegate:))) else { return .unavailable }

        return await withCheckedContinuation { continuation in
            let handoff = TrollStoreDocumentHandoff { continuation.resume(returning: $0) }
            let target = unsafeBitCast(workspace, to: DocumentOpening.self)
            guard let operation = target.operation(
                toOpenResource: url, usingApplication: "com.opa334.TrollStore",
                uniqueDocumentIdentifier: nil, userInfo: nil, delegate: handoff
            ) else {
                handoff.finish(.unavailable)
                return
            }
            handoff.start(operation)
        }
    }
}

/// Native document operations report copying separately from the launch result.
final class TrollStoreDocumentHandoff: NSObject {
    private let lock = NSLock()
    private var completion: ((TrollStoreHandoffOutcome) -> Void)?
    private var operation: Operation?

    init(completion: @escaping (TrollStoreHandoffOutcome) -> Void) {
        self.completion = completion
        super.init()
    }

    func start(_ operation: Operation) {
        lock.lock()
        self.operation = operation
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { self.finish(.unanswered) }
        // LaunchServices' document operation may wait synchronously for XPC.
        DispatchQueue.global(qos: .userInitiated).async { operation.start() }
    }

    @objc func openResourceOperation(_ operation: Operation, didFinishCopyingResource url: URL) {}

    @objc func openResourceOperation(_ operation: Operation, didFailWithError error: NSError) {
        FilaLog.warning("TrollStore document handoff refused: \(error.domain) \(error.code): \(error.localizedDescription)")
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            FilaLog.warning("TrollStore handoff underlying error: \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
        }
        finish(.failed(domain: error.domain, code: error.code))
    }

    @objc func openResourceOperationDidComplete(_ operation: Operation) {
        finish(.opened)
    }

    func finish(_ outcome: TrollStoreHandoffOutcome) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        operation = nil
        lock.unlock()
        completion?(outcome)
    }
}
