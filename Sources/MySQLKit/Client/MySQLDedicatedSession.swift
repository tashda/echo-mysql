import Logging

public struct MySQLDedicatedSession: Sendable {
    private let connection: any MySQLConnectionSession
    private let configuration: MySQLConfiguration?

    init(connection: any MySQLConnectionSession, configuration: MySQLConfiguration? = nil) {
        self.connection = connection
        self.configuration = configuration
    }

    public static func open(
        configuration: MySQLConfiguration,
        logger: Logger = Logger(label: "mysql-kit.dedicated-session")
    ) async throws -> MySQLDedicatedSession {
        let connection = try await MySQLWireConnection.connect(configuration: configuration, logger: logger)
        return MySQLDedicatedSession(connection: connection, configuration: configuration)
    }

    public func simpleQuery(_ sql: String) async throws -> [MySQLRow] {
        try await connection.simpleQuery(sql)
    }

    public func query(_ sql: String, binds: [MySQLData] = []) async throws -> MySQLWireQueryResult {
        try await connection.query(sql, binds: binds)
    }

    public func stream(_ sql: String) async throws -> MySQLRowStream {
        try await connection.stream(sql)
    }

    public func close() async {
        await connection.close()
    }

    /// Runs SQL (several statements allowed) and returns its events: columns, rows in batches,
    /// each statement's end, the last statement's warnings.
    public func events(_ sql: String, batchSize: Int = 512) async throws -> MySQLResultEvents {
        guard let wire = connection as? MySQLWireConnection else {
            throw MySQLWireError.unsupportedBindParameter("events need a server connection")
        }
        return try await wire.events(sql, batchSize: batchSize)
    }

    /// The server's id for this session's connection.
    public var threadID: UInt64 { get async { await connection.threadID } }

    /// Whether a transaction is open on this session.
    public var isInTransaction: Bool {
        get async { await (connection as? MySQLWireConnection)?.isInTransaction ?? false }
    }

    /// Whether the session is closed (by `close()`, the server, or the network).
    public var isClosed: Bool { get async { await connection.isClosed } }

    /// Stops the statement this session is running (`KILL QUERY`, sent over a short connection of
    /// its own). The statement ends with error 1317 (MariaDB) or returns early (MySQL's SLEEP).
    public func cancelRunningStatement() async throws {
        guard let configuration else { return }
        let id = await connection.threadID
        guard id > 0 else { return }
        let side = try await MySQLWireConnection.connect(configuration: configuration)
        defer { Task { await side.close() } }
        _ = try await side.simpleQuery("KILL QUERY \(id)")
    }
}
