import Synchronization

/// Held by a row stream or event stream while its statement still owns the connection; gives the
/// connection back when the stream ends or is dropped (then what is left is read away first).
final class MySQLStreamLease: Sendable {
    private let release: @Sendable () async -> Void
    private let released = Mutex(false)

    init(release: @escaping @Sendable () async -> Void) {
        self.release = release
    }

    func end() async {
        guard released.withLock({ done in defer { done = true }; return !done }) else { return }
        await release()
    }

    deinit {
        guard released.withLock({ done in defer { done = true }; return !done }) else { return }
        let release = self.release
        Task(name: "mysql-stream-dropped") { await release() }
    }
}

extension MySQLWireConnection {
    /// Waits for its turn on the connection: calls run one after another, as mysql-nio queued them.
    func acquire() async {
        if !gateHeld {
            gateHeld = true
            return
        }
        await withCheckedContinuation { continuation in gateWaiters.append(continuation) }
    }

    func release() {
        if gateWaiters.isEmpty {
            gateHeld = false
        } else {
            gateWaiters.removeFirst().resume()
        }
    }

    /// A lease for a stream: reads away what the stream left, then lets the next call in.
    func streamLease() -> MySQLStreamLease {
        MySQLStreamLease { [weak self] in
            guard let self else { return }
            await self.finishStream()
        }
    }

    private func finishStream() async {
        if await connection.isBusy { await connection.drain() }
        release()
    }
}
