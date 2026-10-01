import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

public actor MySQLWireConnection: MySQLConnectionSession {
    private let configuration: MySQLWireConfiguration
    private let logger: Logger
    private var connection: MySQLConnection?
    private var closeRequested = false

    public static func connect(
        configuration: MySQLWireConfiguration,
        logger: Logger = Logger(label: "mysql-wire.connection")
    ) async throws -> MySQLWireConnection {
        // NIO's shared event loop group. A group of its own per connection costs a thread each, and on
        // Linux a connection on a just-started group sometimes stalled in its handshake (about one in
        // twenty under load) until the server gave up.
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let address = try SocketAddress.makeAddressResolvingHost(configuration.host, port: configuration.port)
        let eventLoop = eventLoopGroup.next()
        let connection = try await withDeadline(seconds: configuration.connectTimeoutSeconds, host: configuration.host, on: eventLoop) {
            MySQLConnection.connect(
                to: address,
                username: configuration.username,
                database: configuration.database ?? "",
                password: configuration.password,
                tlsConfiguration: try Self.tlsConfiguration(for: configuration),
                serverHostname: Self.serverName(for: configuration),
                logger: logger,
                on: eventLoop
            )
        }
        // mysql-nio carries on without TLS when the server offers none, whatever the mode; see
        // ConnectionTests.requiredModesFailWhenTheServerHasNoTLS.
        return MySQLWireConnection(
            configuration: configuration,
            logger: logger,
            connection: connection
        )
    }

    /// The connect future, failed after `seconds` (TCP connect, TLS and login together: a server
    /// that accepts the connection and never answers would otherwise hang the caller). A connection
    /// that completes after the deadline is closed.
    private static func withDeadline(
        seconds: Int,
        host: String,
        on eventLoop: any EventLoop,
        _ connect: () throws -> EventLoopFuture<MySQLConnection>
    ) async throws -> MySQLConnection {
        let future = try connect()
        guard seconds > 0 else { return try await future.get() }
        let promise = eventLoop.makePromise(of: MySQLConnection.self)
        let settled = NIOLoopBoundBox.makeBoxSendingValue(false, eventLoop: eventLoop)
        let deadline = eventLoop.scheduleTask(in: .seconds(Int64(seconds))) {
            guard !settled.value else { return }
            settled.value = true
            promise.fail(MySQLWireError.connectTimedOut(host: host, seconds: seconds))
        }
        future.whenComplete { result in
            deadline.cancel()
            guard !settled.value else {
                // Too late: the caller has given up on it.
                if case .success(let connection) = result { _ = connection.close() }
                return
            }
            settled.value = true
            promise.completeWith(result)
        }
        return try await promise.futureResult.get()
    }

    init(
        configuration: MySQLWireConfiguration,
        logger: Logger,
        connection: MySQLConnection
    ) {
        self.configuration = configuration
        self.logger = logger
        self.connection = connection
    }

    /// Closed by `close()`, or by the server or network (KILL, a restart, `wait_timeout`).
    public var isClosed: Bool {
        closeRequested || connection?.isClosed ?? true
    }

    public func simpleQuery(_ sql: String) async throws -> [MySQLRow] {
        let connection = try requireConnection()
        return try await connection.simpleQuery(sql).get()
    }

    public func query(_ sql: String, binds: [MySQLData] = []) async throws -> MySQLWireQueryResult {
        let connection = try requireConnection()
        var rows: [MySQLRow] = []
        var metadata: MySQLWireQueryMetadata?
        try await connection.query(
            sql,
            binds,
            onRow: { row in
                rows.append(row)
            },
            onMetadata: { queryMetadata in
                metadata = MySQLWireQueryMetadata(
                    affectedRows: queryMetadata.affectedRows,
                    lastInsertID: queryMetadata.lastInsertID
                )
            }
        ).get()
        return MySQLWireQueryResult(rows: rows, metadata: metadata)
    }

    public func stream(_ sql: String) async throws -> AsyncThrowingStream<MySQLRow, Error> {
        let connection = try requireConnection()
        return AsyncThrowingStream { continuation in
            let future = connection.simpleQuery(sql) { row in
                continuation.yield(row)
            }
            Task {
                do {
                    try await future.get()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func changeDatabase(_ database: String) async throws {
        let escaped = database.replacingOccurrences(of: "`", with: "``")
        _ = try await simpleQuery("USE `\(escaped)`")
    }

    public func currentDatabase() async throws -> String? {
        let rows = try await simpleQuery("SELECT DATABASE()")
        guard let row = rows.first else { return nil }
        return row.column("DATABASE()")?.string
    }

    public func validate() async throws {
        _ = try await simpleQuery("SELECT 1")
    }

    public func close() async {
        guard !closeRequested else { return }
        closeRequested = true

        if let connection {
            do {
                try await connection.close().get()
            } catch {
                logger.warning("Failed to close MySQL connection cleanly: \(error.localizedDescription)")
            }
            self.connection = nil
        }
    }

    private func requireConnection() throws -> MySQLConnection {
        guard !closeRequested, let connection else {
            throw MySQLWireError.connectionAlreadyClosed
        }
        return connection
    }

    /// The TLS mode's settings plus the client certificate, when one is configured.
    static func tlsConfiguration(for configuration: MySQLWireConfiguration) throws -> TLSConfiguration? {
        guard var tls = tlsConfiguration(for: configuration.tlsMode) else { return nil }
        if let certificatePath = configuration.clientCertificatePath, let keyPath = configuration.clientKeyPath {
            tls.certificateChain = try NIOSSLCertificate.fromPEMFile(certificatePath).map { .certificate($0) }
            tls.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyPath, format: .pem))
        }
        return tls
    }

    /// NIOSSL settings for a TLS mode; nil when TLS is disabled.
    static func tlsConfiguration(for mode: MySQLWireTLSMode) -> TLSConfiguration? {
        var tls = TLSConfiguration.makeClientConfiguration()
        switch mode {
        case .disabled:
            return nil
        case .preferred, .required:
            tls.certificateVerification = .none
        case .verifyCA(let path):
            tls.certificateVerification = .noHostnameVerification
            tls.trustRoots = .file(path)
        case .verifyIdentity(let path):
            tls.certificateVerification = .fullVerification
            if let path { tls.trustRoots = .file(path) }
        }
        TLSKeyLog.apply(to: &tls)
        return tls
    }

    /// The name sent as SNI and checked against the certificate. An IP address cannot be sent as
    /// SNI (NIOSSL refuses it); the certificate's IP entries are checked without it.
    static func serverName(for configuration: MySQLWireConfiguration) -> String? {
        guard configuration.useTLS else { return nil }
        let isAddress = (try? SocketAddress(ipAddress: configuration.host, port: 0)) != nil
        return isAddress ? nil : configuration.host
    }
}
