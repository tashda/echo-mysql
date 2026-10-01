import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

public actor MySQLWireConnection: MySQLConnectionSession {
    private let configuration: MySQLWireConfiguration
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private var connection: MySQLConnection?
    private var isClosed = false

    public static func connect(
        configuration: MySQLWireConfiguration,
        logger: Logger = Logger(label: "mysql-wire.connection")
    ) async throws -> MySQLWireConnection {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let address = try SocketAddress.makeAddressResolvingHost(configuration.host, port: configuration.port)
            let connection = try await MySQLConnection.connect(
                to: address,
                username: configuration.username,
                database: configuration.database ?? "",
                password: configuration.password,
                tlsConfiguration: try Self.tlsConfiguration(for: configuration),
                serverHostname: Self.serverName(for: configuration),
                logger: logger,
                on: eventLoopGroup.any()
            ).get()
            return MySQLWireConnection(
                configuration: configuration,
                logger: logger,
                eventLoopGroup: eventLoopGroup,
                connection: connection
            )
        } catch {
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    init(
        configuration: MySQLWireConfiguration,
        logger: Logger,
        eventLoopGroup: MultiThreadedEventLoopGroup,
        connection: MySQLConnection
    ) {
        self.configuration = configuration
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
        self.connection = connection
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
        guard !isClosed else { return }
        isClosed = true

        if let connection {
            do {
                try await connection.close().get()
            } catch {
                logger.warning("Failed to close MySQL connection cleanly: \(error.localizedDescription)")
            }
            self.connection = nil
        }

        do {
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.warning("Failed to shut down MySQL event loop group: \(error.localizedDescription)")
        }
    }

    private func requireConnection() throws -> MySQLConnection {
        guard !isClosed, let connection else {
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
        case .required:
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
