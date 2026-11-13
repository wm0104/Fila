import Foundation

struct FileIdentity: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var modified: Double
}

/// One process-wide turn from fresh identity check through publication.
@MainActor
enum AtomicSaveOperation {
    struct Target {
        var path: String
        var identity: FileIdentity
    }

    enum Outcome: Equatable {
        case saved(FileIdentity?)
        case kept
    }

    private static var turns: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func run(
        path: String,
        expecting loaded: FileIdentity?,
        resolve: @MainActor (String) async throws -> Target,
        confirm: @MainActor () async -> Bool,
        publish: @MainActor (String) async throws -> FileIdentity?,
    ) async throws -> Outcome {
        while true {
            try Task.checkCancellation()
            let key = try await resolve(path).path
            await acquire(key)
            defer { release(key) }
            try Task.checkCancellation()
            let target = try await resolve(path)
            // A link may have changed while queued: never write B under A's turn.
            guard target.path == key else { continue }
            if let loaded, target.identity != loaded {
                guard await confirm() else { return .kept }
            }
            try Task.checkCancellation()
            return .saved(try await publish(target.path))
        }
    }

    private static func acquire(_ path: String) async {
        if turns[path] == nil {
            turns[path] = []
        } else {
            await withCheckedContinuation { turns[path, default: []].append($0) }
        }
    }

    private static func release(_ path: String) {
        guard var waiting = turns[path], !waiting.isEmpty else {
            turns.removeValue(forKey: path)
            return
        }
        let next = waiting.removeFirst()
        turns[path] = waiting
        next.resume()
    }
}
