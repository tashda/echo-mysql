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

/// Holds a stream's lease until its first iterator takes it: the connection is then released
/// when that iterator goes away (a `for` loop that ended or broke out), even if the stream
/// itself is still around. A stream never iterated releases when it goes away.
final class MySQLStreamLeaseHolder: Sendable {
    private let lease: Mutex<MySQLStreamLease?>

    init(_ lease: MySQLStreamLease?) { self.lease = Mutex(lease) }

    func take() -> MySQLStreamLease? { lease.withLock { held in defer { held = nil }; return held } }
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
