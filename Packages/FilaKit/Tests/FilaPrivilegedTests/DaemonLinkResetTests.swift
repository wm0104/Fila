#if canImport(XPC)
    import FilaClient
    @testable import FilaPrivileged
    @testable import FilaProtocol
    import Foundation
    import Testing
    import XPC

    /// What a dead link takes with it when it goes.
    ///
    /// When `filad` exits, every request still in flight on its connection is
    /// answered with an error, each in its own reply block, and a request from
    /// another thread may build the replacement link between two of them. The
    /// daemon cancels every job a peer started when that peer's connection
    /// ends, so a late reply from the old link that cancelled the new one
    /// would stop a paste the user had just started on it.
    ///
    /// There is no daemon on the Mac, and that is enough here: the Mach
    /// service is not registered, so a connection is built and every request
    /// on it fails the way one to a daemon that just exited does.
    @Suite("Daemon link resets")
    struct DaemonLinkResetTests {
        @Test
        func `A stale link's failure leaves its replacement alone`() throws {
            let queue = DispatchQueue(label: "fila.reset-test")
            queue.suspend()
            defer { queue.resume() }
            let service = DaemonFileService(streams: FileEventStreams(), queue: queue)
            let stale = try service.activeConnection()
            // The first failing reply on the old link drops it.
            service.invalidate(generation: stale.generation)
            // Another request builds the replacement.
            let replacement = try service.activeConnection()
            #expect(replacement.connection !== stale.connection)
            // The next failing reply on the old link arrives.
            service.invalidate(generation: stale.generation)
            #expect(try service.activeConnection().connection === replacement.connection)
        }

        /// The old link's own end — the invalid event its cancellation
        /// produces — arrives after the replacement may already be running
        /// jobs, and reporting it would end those jobs' rows as lost.
        @Test
        func `Loss reports its source generation once, not its replacement`() throws {
            let queue = DispatchQueue(label: "fila.reset-test")
            queue.suspend()
            defer { queue.resume() }
            let service = DaemonFileService(streams: FileEventStreams(), queue: queue)
            let losses = LossCount()
            service.onLinkLost = { losses.bump($0) }
            let stale = try service.activeConnection()
            service.invalidate(generation: stale.generation)
            let replacement = try service.activeConnection()
            service.invalidate(generation: stale.generation)
            #expect(losses.generations == [stale.generation])
            #expect(replacement.generation > stale.generation)
            #expect(try service.activeConnection().connection === replacement.connection)
        }

        /// A reply and its own cancellation event retire the same generation;
        /// only the first may report its lost jobs.
        @Test
        func `Retiring a dead link reports exactly one loss`() throws {
            let queue = DispatchQueue(label: "fila.reset-test")
            queue.suspend()
            defer { queue.resume() }
            let service = DaemonFileService(streams: FileEventStreams(), queue: queue)
            let losses = LossCount()
            service.onLinkLost = { losses.bump($0) }
            let stale = try service.activeConnection()
            service.invalidate(generation: stale.generation)
            service.invalidate(generation: stale.generation)
            #expect(losses.generations == [stale.generation])
        }

        @Test
        func `An old cancel never creates or targets a replacement connection`() async throws {
            let queue = DispatchQueue(label: "fila.reset-test")
            queue.suspend()
            defer { queue.resume() }
            let service = DaemonFileService(streams: FileEventStreams(), queue: queue)
            let stale = try service.activeConnection()
            service.invalidate(generation: stale.generation)
            let replacement = try service.activeConnection()
            await #expect(throws: FilaFailure.self) {
                try await service.cancelJob(.init(value: 1, generation: stale.generation))
            }
            #expect(try service.activeConnection().connection === replacement.connection)
        }

        @Test
        func `A request that fails drops the link it was sent on`() async throws {
            let service = DaemonFileService(streams: FileEventStreams())
            let first = try service.activeConnection()
            await #expect(throws: FilaFailure.self) {
                _ = try await service.hello()
            }
            // Dead for good, so the next request has to build a new one.
            #expect(try service.activeConnection().connection !== first.connection)
        }
    }

    private final class LossCount: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64] = []
        func bump(_ generation: UInt64) {
            lock.lock(); values.append(generation); lock.unlock()
        }

        var generations: [UInt64] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }
#endif
