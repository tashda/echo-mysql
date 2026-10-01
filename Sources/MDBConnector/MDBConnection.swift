#if canImport(CMariaDB)
internal import CMariaDB
#else
internal import CMariaDBSystem
#endif
import Dispatch
import Foundation

/// One MariaDB Connector/C connection (MySQL and MariaDB servers).
///
/// The actor runs on its own serial queue (decision D10) and every Connector/C call happens
/// there. Connector/C's non-blocking API (`*_start` / `*_cont`) says what it waits for; the actor
/// waits for the socket with `MDBSocketWait` instead of blocking a thread.
public actor MDBConnection {
    private let queue: DispatchSerialQueue
    var handle: UnsafeMutablePointer<MYSQL>?
    /// The result set being read (`mysql_use_result`), until its rows are all read or dropped.
    var result: UnsafeMutablePointer<MYSQL_RES>?
    /// A statement was sent and its results haven't all been read.
    public internal(set) var isBusy = false
    /// Socket waits in progress (a closing connection ends them first).
    var activeWaits: [ObjectIdentifier: MDBSocketWait] = [:]
    /// Column descriptions of the result set being read.
    var currentFields: [MDBField] = []
    /// Where reading the results of the statement(s) sent stands.
    var phase: Phase = .idle
    /// The data `LOAD DATA LOCAL INFILE` may read (decision D17).
    let localInfile = MDBLocalInfileSlot()
    /// Whether a transaction was open when the connection closed (the server rolls it back).
    public private(set) var closedWithTransactionOpen = false

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(label: String = "MDBConnection") {
        queue = DispatchSerialQueue(label: label)
    }

    isolated deinit {
        if let result { mysql_free_result(result) }
        if let handle { mysql_close(handle) }
    }

    /// Opens a connection; the whole attempt (DNS, TCP, TLS, sign-in) must finish within the
    /// options' connect timeout.
    public static func connect(_ options: MDBConnectOptions) async throws -> MDBConnection {
        let connection = MDBConnection()
        try await connection.open(options)
        return connection
    }

    // MARK: Server facts

    /// The server's connection id (for `KILL QUERY`).
    public var threadID: UInt64 { handle.map { UInt64(mysql_thread_id($0)) } ?? 0 }
    /// "8.4.3", "11.4.5-MariaDB-ubu2404" …
    public var serverInfo: String { handle.flatMap { mysql_get_server_info($0) }.map { String(cString: $0) } ?? "" }
    /// 80403, 110405 …
    public var serverVersion: Int { handle.map { Int(mysql_get_server_version($0)) } ?? 0 }
    /// Whether a transaction is open (the server's `SERVER_STATUS_IN_TRANS`).
    public var isInTransaction: Bool { handle.map { $0.pointee.server_status & UInt32(SERVER_STATUS_IN_TRANS) != 0 } ?? false }
    /// The TLS cipher in use; nil without TLS.
    public var tlsCipher: String? { handle.flatMap { mysql_get_ssl_cipher($0) }.map { String(cString: $0) } }

    public var isOpen: Bool { handle != nil }

    /// Whether the connection is still usable, checked without waiting: an idle socket that is
    /// readable with nothing to read means the server closed it.
    public func isAlive() -> Bool {
        guard let handle else { return false }
        guard !isBusy, activeWaits.isEmpty else { return true }
        let socket = Int32(mysql_get_socket(handle))
        guard socket >= 0 else { return false }
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return true }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
        var byte: UInt8 = 0
        return recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
    }

    /// The string escaped for a quoted literal with this connection's character set and
    /// `NO_BACKSLASH_ESCAPES` setting.
    public func escape(_ text: String) throws -> String {
        guard let handle else { throw MDBError(.notReady, message: "The connection is closed.") }
        let source = Array(text.utf8)
        var target = [CChar](repeating: 0, count: source.count * 2 + 1)
        let length = source.withUnsafeBufferPointer { from in
            from.withMemoryRebound(to: CChar.self) { from in
                mysql_real_escape_string(handle, &target, from.baseAddress, UInt(source.count))
            }
        }
        guard length != UInt.max else { throw MDBError(.server, message: "The text cannot be escaped for this connection") }
        return String(decoding: target.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Closes the connection, also while a statement waits on the socket (that wait ends with
    /// `connectionLost`). Safe to call twice.
    public func close() async {
        let waits = Array(activeWaits.values)
        activeWaits.removeAll()
        for wait in waits { await wait.abort(with: MDBError(.connectionLost, message: "The connection was closed.")) }
        if let result { mysql_free_result(result) }
        result = nil
        if let handle {
            if isInTransaction { closedWithTransactionOpen = true }
            mysql_close(handle)
        }
        handle = nil
        isBusy = false
        phase = .idle
    }

    // MARK: Internals

    func error(_ kind: MDBError.Kind? = nil) -> MDBError {
        guard let handle else { return MDBError(.connectionLost, message: "The connection is closed.") }
        let code = UInt32(mysql_errno(handle))
        let message = String(cString: mysql_error(handle))
        let state = String(cString: mysql_sqlstate(handle))
        let resolved = kind ?? (MDBError.connectionLostCodes.contains(code) ? .connectionLost : .server)
        return MDBError(resolved, code: code, sqlState: state == "00000" || state.isEmpty ? nil : state, message: message)
    }

    func waitForSocket(_ events: MDBSocketReadiness, deadline: ContinuousClock.Instant?) async throws -> MDBSocketReadiness {
        guard let handle else { throw MDBError(.connectionLost, message: "The connection is closed.") }
        let socket = Int32(mysql_get_socket(handle))
        let wait = MDBSocketWait()
        let id = ObjectIdentifier(wait)
        activeWaits[id] = wait
        defer { activeWaits[id] = nil }
        let ready = try await wait.run(socket: socket, for: events, on: queue, deadline: deadline)
        guard self.handle != nil else { throw MDBError(.connectionLost, message: "The connection was closed.") }
        return ready
    }

    /// Runs a non-blocking operation to its end: `start` returns what Connector/C waits for
    /// (`MYSQL_WAIT_*`), the actor waits for it, `resume` continues with what happened, until 0.
    func drive(
        deadline: ContinuousClock.Instant? = nil,
        start: () -> Int32,
        resume: (Int32) -> Int32
    ) async throws {
        var status = start()
        while status != 0 {
            var events: MDBSocketReadiness = []
            if status & Int32(MYSQL_WAIT_READ) != 0 || status & Int32(MYSQL_WAIT_EXCEPT) != 0 { events.insert(.readable) }
            if status & Int32(MYSQL_WAIT_WRITE) != 0 { events.insert(.writable) }
            var waitUntil = deadline
            let wantsTimeout = status & Int32(MYSQL_WAIT_TIMEOUT) != 0
            if wantsTimeout, let handle {
                let library = ContinuousClock.now + .milliseconds(Int(mysql_get_timeout_value_ms(handle)))
                waitUntil = waitUntil.map { min($0, library) } ?? library
            }
            var happened: Int32 = 0
            do {
                let ready = try await waitForSocket(events, deadline: waitUntil)
                if ready.contains(.readable) { happened |= Int32(MYSQL_WAIT_READ) }
                if ready.contains(.writable) { happened |= Int32(MYSQL_WAIT_WRITE) }
            } catch is MDBSocketTimeout where deadline.map({ ContinuousClock.now < $0 }) ?? true {
                happened = Int32(MYSQL_WAIT_TIMEOUT)
            } catch {
                // The call stays suspended inside Connector/C: the next call would start over its
                // context, mid-packet. Nothing can resume or abandon it, so the connection closes
                // (a cancelled task or a passed deadline ends the connection, not just the call).
                await close()
                throw error
            }
            status = resume(happened)
        }
    }
}
