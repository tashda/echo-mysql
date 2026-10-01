import Logging

public actor MySQLServerConnection: Sendable {
    private let configuration: MySQLConfiguration
    private let logger: Logger
    private let healthPolicy: MySQLConnectionHealthPolicy
    private let connectionFactory: @Sendable (MySQLConfiguration, Logger) async throws -> any MySQLConnectionSession

    private var primaryConnection: (any MySQLConnectionSession)?
    private var metadataConnection: (any MySQLConnectionSession)?
    private var activityConnection: (any MySQLConnectionSession)?
    private let preparedStatementCache: PreparedStatementCache

    public init(
        configuration: MySQLConfiguration,
        logger: Logger = Logger(label: "mysql-kit.server-connection"),
        healthPolicy: MySQLConnectionHealthPolicy? = nil,
        preparedStatementCache: PreparedStatementCache = PreparedStatementCache(),
        connectionFactory: @escaping @Sendable (MySQLConfiguration, Logger) async throws -> any MySQLConnectionSession = { configuration, logger in
            try await MySQLWireConnection.connect(configuration: configuration, logger: logger)
        }
    ) {
        self.configuration = configuration
        self.logger = logger
        self.healthPolicy = healthPolicy ?? MySQLConnectionHealthPolicy(keepAliveInterval: configuration.keepAliveInterval)
        self.preparedStatementCache = preparedStatementCache
        self.connectionFactory = connectionFactory
    }

    public func primary() async throws -> any MySQLConnectionSession {
        try await shared(.primary)
    }

    public func metadata() async throws -> any MySQLConnectionSession {
        try await shared(.metadata)
    }

    public func activity() async throws -> any MySQLConnectionSession {
        try await shared(.activity)
    }

    private enum Role { case primary, metadata, activity }
    /// Connections being opened, so callers arriving meanwhile wait for the same one.
    private var opening: [Role: Task<any MySQLConnectionSession, any Error>] = [:]

    /// The role's connection, opened once. The actor lets other calls in while one awaits the
    /// connect; without `opening`, two of them each opened a connection and the first, replaced,
    /// was never closed.
    private func shared(_ role: Role) async throws -> any MySQLConnectionSession {
        let cached: (any MySQLConnectionSession)? = switch role {
        case .primary: primaryConnection
        case .metadata: metadataConnection
        case .activity: activityConnection
        }
        if let cached {
            // A session the server ended (KILL, restart, wait_timeout) is replaced, so one lost
            // connection does not fail every later call. Statements are never re-run: a call in
            // flight when the connection was lost fails.
            guard await cached.isClosed else { return cached }
            logger.info("MySQL \(role) connection was closed; opening a new one")
            await cached.close()
            switch role {
            case .primary: if primaryConnection.map({ $0 as AnyObject }) === (cached as AnyObject) { primaryConnection = nil }
            case .metadata: if metadataConnection.map({ $0 as AnyObject }) === (cached as AnyObject) { metadataConnection = nil }
            case .activity: if activityConnection.map({ $0 as AnyObject }) === (cached as AnyObject) { activityConnection = nil }
            }
            return try await shared(role)
        }
        if let pending = opening[role] { return try await pending.value }
        let factory = connectionFactory, configuration = configuration, logger = logger
        let task = Task { try await factory(configuration, logger) }
        opening[role] = task
        defer { opening[role] = nil }
        let connection = try await task.value
        switch role {
        case .primary: primaryConnection = connection
        case .metadata: metadataConnection = connection
        case .activity: activityConnection = connection
        }
        return connection
    }

    public func newDedicatedConnection() async throws -> any MySQLConnectionSession {
        try await connectionFactory(configuration, logger)
    }

    public func cancelQuery(threadID: UInt32) async throws {
        let connection = try await newDedicatedConnection()
        do {
            _ = try await connection.simpleQuery("KILL QUERY \(threadID)")
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    public func ping() async throws {
        if let primaryConnection {
            try await validate(primaryConnection, role: .primary)
        }
        if let metadataConnection {
            try await validate(metadataConnection, role: .metadata)
        }
        if let activityConnection {
            try await validate(activityConnection, role: .activity)
        }
    }

    public func recordPreparedStatement(_ sql: String) async {
        let statementName = "mw_stmt_\(abs(sql.hashValue))"
        _ = await preparedStatementCache.touch(sql, statementName: statementName)
    }

    public func cachedPreparedStatements() async -> [PreparedStatementCache.Entry] {
        await preparedStatementCache.cachedStatements()
    }

    public func resetPreparedStatements() async {
        await preparedStatementCache.removeAll()
    }

    public func failureAction(for error: any Error) -> MySQLConnectionFailureAction {
        healthPolicy.action(for: error)
    }

    public func close() async {
        if let primaryConnection {
            await primaryConnection.close()
            self.primaryConnection = nil
        }
        if let metadataConnection {
            await metadataConnection.close()
            self.metadataConnection = nil
        }
        if let activityConnection {
            await activityConnection.close()
            self.activityConnection = nil
        }
        await preparedStatementCache.removeAll()
    }

    private enum ConnectionRole {
        case primary
        case metadata
        case activity
    }

    private func validate(_ connection: any MySQLConnectionSession, role: ConnectionRole) async throws {
        do {
            try await connection.validate()
        } catch {
            switch healthPolicy.action(for: error) {
            case .reconnectRequired, .closeRequired:
                await connection.close()
                switch role {
                case .primary: primaryConnection = nil
                case .metadata: metadataConnection = nil
                case .activity: activityConnection = nil
                }
            case .noAction:
                break
            }
            throw error
        }
    }
}
