import Dispatch
import Synchronization

/// What a connection waits for on its socket.
struct MDBSocketReadiness: OptionSet, Sendable {
    let rawValue: UInt8
    static let readable = MDBSocketReadiness(rawValue: 1)
    static let writable = MDBSocketReadiness(rawValue: 2)
}

/// The deadline passed before the socket was ready.
struct MDBSocketTimeout: Error {}

/// One wait for socket readiness (decision D10): DispatchSources on the connection's own queue, so
/// Connector/C is only touched there, and no thread blocks while the socket is quiet.
///
/// The wait resumes only after every source's cancel handler has run: Dispatch must have let go of
/// the descriptor before Connector/C may close it.
final class MDBSocketWait: Sendable {
    private struct State {
        var continuation: CheckedContinuation<MDBSocketReadiness, any Error>?
        var outcome: Result<MDBSocketReadiness, any Error>?
        var sources: [any DispatchSourceProtocol] = []
        var pendingCancels = 0
        var released = false
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Waits until the socket is ready for `events`, the deadline passes (`MDBSocketTimeout`), or the
    /// task is cancelled (`CancellationError`).
    static func wait(
        socket: Int32,
        for events: MDBSocketReadiness,
        on queue: DispatchSerialQueue,
        deadline: ContinuousClock.Instant?
    ) async throws -> MDBSocketReadiness {
        try await MDBSocketWait().run(socket: socket, for: events, on: queue, deadline: deadline)
    }

    func run(
        socket: Int32,
        for events: MDBSocketReadiness,
        on queue: DispatchSerialQueue,
        deadline: ContinuousClock.Instant?
    ) async throws -> MDBSocketReadiness {
        let wait = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.start(continuation, socket: socket, events: events, queue: queue, deadline: deadline)
            }
        } onCancel: {
            wait.finish(.failure(CancellationError()))
        }
    }

    private func start(
        _ continuation: CheckedContinuation<MDBSocketReadiness, any Error>,
        socket: Int32,
        events: MDBSocketReadiness,
        queue: DispatchSerialQueue,
        deadline: ContinuousClock.Instant?
    ) {
        // The sources live only inside the lock; making, starting and cancelling them never
        // blocks, and their handlers run later, on the connection's queue.
        state.withLock { state in
            if events.contains(.readable) {
                let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
                source.setEventHandler { [self] in finish(.success(.readable)) }
                state.sources.append(source)
            }
            if events.contains(.writable) {
                let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
                source.setEventHandler { [self] in finish(.success(.writable)) }
                state.sources.append(source)
            }
            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                let nanoseconds = max(0, remaining.components.seconds * 1_000_000_000 + remaining.components.attoseconds / 1_000_000_000)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .nanoseconds(Int(nanoseconds)))
                timer.setEventHandler { [self] in finish(.failure(MDBSocketTimeout())) }
                state.sources.append(timer)
            }
            state.continuation = continuation
            state.pendingCancels = state.sources.count
            let cancelledAlready = state.outcome != nil
            for source in state.sources {
                source.setCancelHandler { [self] in cancelled() }
                // Cancelled before the sources existed: cancel them unstarted; their cancel
                // handlers resume the continuation.
                if cancelledAlready { source.cancel() }
                source.resume()
            }
        }
    }

    /// Records the first outcome and cancels the sources; resuming waits for their cancel handlers.
    private func finish(_ outcome: Result<MDBSocketReadiness, any Error>) {
        state.withLock { state in
            guard state.outcome == nil else { return }
            state.outcome = outcome
            for source in state.sources { source.cancel() }
        }
    }

    /// Ends the wait with `error` (the connection is closing) and returns once Dispatch has let go
    /// of the descriptor, so it can be closed.
    func abort(with error: any Error) async {
        finish(.failure(error))
        await withCheckedContinuation { continuation in
            let releasedAlready = state.withLock { state -> Bool in
                if state.released || state.sources.isEmpty && state.continuation == nil { return true }
                state.releaseWaiters.append(continuation)
                return false
            }
            if releasedAlready { continuation.resume() }
        }
    }

    private func cancelled() {
        let ready = state.withLock { state -> (CheckedContinuation<MDBSocketReadiness, any Error>, Result<MDBSocketReadiness, any Error>, [CheckedContinuation<Void, Never>])? in
            state.pendingCancels -= 1
            guard state.pendingCancels == 0, let continuation = state.continuation, let outcome = state.outcome else { return nil }
            state.continuation = nil
            state.sources = []
            state.released = true
            defer { state.releaseWaiters.removeAll() }
            return (continuation, outcome, state.releaseWaiters)
        }
        if let (continuation, outcome, waiters) = ready {
            continuation.resume(with: outcome)
            waiters.forEach { $0.resume() }
        }
    }
}
