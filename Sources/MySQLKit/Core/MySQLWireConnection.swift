import Foundation
import Logging
import MDBConnector

/// One connection to a MySQL or MariaDB server, on MariaDB Connector/C (`MDBConnection`).
public actor MySQLWireConnection: MySQLConnectionSession {
    let connection: MDBConnection
    private let setup: MySQLConnectorSetup
    private let logger: Logger
    /// One statement at a time (see `acquire()`).
    var gateHeld = false
    var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private init(connection: MDBConnection, setup: MySQLConnectorSetup, logger: Logger) {
        self.connection = connection
        self.setup = setup
        self.logger = logger
    }

    public static func connect(
        configuration: MySQLConfiguration,
        logger: Logger = Logger(label: "mysql-kit.connection")
    ) async throws -> MySQLWireConnection {
        let setup = try configuration.connectorSetup()
        do {
            let connection = try await MDBConnection.connect(setup.options)
            return MySQLWireConnection(connection: connection, setup: setup, logger: logger)
        } catch let error as MDBError where error.kind == .connectTimedOut {
            throw MySQLWireError.connectTimedOut(host: configuration.host, seconds: configuration.connectTimeoutSeconds)
        } catch {
            throw MySQLError.from(error)
        }
    }

    /// Closed by `close()`, or by the server or network (KILL, a restart, `wait_timeout`).
    public var isClosed: Bool {
        get async { await !connection.isAlive() }
    }

    public var threadID: UInt64 {
        get async { await connection.threadID }
    }

    /// Whether a transaction is open (the server's status after the last statement).
    public var isInTransaction: Bool {
        get async { await connection.isInTransaction }
    }

    public func simpleQuery(_ sql: String) async throws -> [MySQLRow] {
        try await run(sql).rows
    }

    public func query(_ sql: String, binds: [MySQLData] = []) async throws -> MySQLWireQueryResult {
        guard !binds.isEmpty else { return try await run(sql) }
        var literals: [String] = []
        literals.reserveCapacity(binds.count)
        for bind in binds { literals.append(try await literal(for: bind)) }
        return try await run(try MySQLPlaceholders.render(sql, literals: literals))
    }

    public func stream(_ sql: String) async throws -> MySQLRowStream {
        await acquire()
        do {
            try await prepare()
            try await connection.send(sql)
        } catch {
            release()
            throw MySQLError.from(error)
        }
        return MySQLRowStream(connection: connection, lease: streamLease())
    }

    public func changeDatabase(_ database: String) async throws {
        let escaped = database.replacingOccurrences(of: "`", with: "``")
        _ = try await run("USE `\(escaped)`")
    }

    public func currentDatabase() async throws -> String? {
        try await run("SELECT DATABASE()").rows.first?.value(at: 0).string
    }

    public func validate() async throws {
        _ = try await run("SELECT 1")
    }

    public func close() async {
        await connection.close()
    }

    /// The SQL literal for a parameter: NULL, a number, X'…' for bytes, or a string escaped by the
    /// connection.
    func literal(for value: MySQLData) async throws -> String {
        guard let bytes = value.bytes else { return "NULL" }
        if value.isBinary {
            return "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
        }
        let text = String(decoding: bytes, as: UTF8.self)
        switch value.type {
        case .tiny, .short, .long, .longlong, .int24, .double, .float:
            if Double(text) != nil, text.allSatisfy({ "0123456789+-.eE".contains($0) }) { return text }
        default:
            break
        }
        do {
            return "'" + (try await connection.escape(text)) + "'"
        } catch {
            throw MySQLError.from(error)
        }
    }

    /// Runs SQL; the rows and columns are the last result set's, the metadata the last statement's.
    private func run(_ sql: String) async throws -> MySQLWireQueryResult {
        await acquire()
        defer { release() }
        try await prepare()
        do {
            try await connection.send(sql)
            var columns: [MySQLColumn] = [], rows: [MySQLRow] = []
            var currentColumns: [MySQLColumn] = [], currentRows: [MySQLRow] = []
            var metadata: MySQLWireQueryMetadata?
            while let event = try await connection.nextEvent(maxRows: 1024) {
                switch event {
                case .columns(let fields):
                    currentColumns = fields.map(MySQLColumn.init)
                    currentRows = []
                case .rows(let batch):
                    currentRows.append(contentsOf: batch.map { MySQLRow(columns: currentColumns, row: $0) })
                case .done(let result):
                    if result.returnedRows {
                        columns = currentColumns
                        rows = currentRows
                    }
                    var done = MySQLWireQueryMetadata(affectedRows: result.returnedRows ? UInt64(currentRows.count) : result.affectedRows,
                                                      lastInsertID: result.insertID == 0 ? nil : result.insertID)
                    done.warningCount = result.warningCount
                    done.info = result.info
                    metadata = done
                }
            }
            return MySQLWireQueryResult(rows: rows, metadata: metadata, columns: columns)
        } catch {
            throw MySQLError.from(error)
        }
    }

    /// Rows of an earlier statement nobody read are read away first.
    private func prepare() async throws {
        guard await connection.isOpen else { throw MySQLWireError.connectionAlreadyClosed }
        if await connection.isBusy { await connection.drain() }
    }
}

/// The rows of a statement (several statements: every result set's rows, in order), read from
/// the server in batches as they are asked for.
public struct MySQLRowStream: AsyncSequence, Sendable {
    public typealias Element = MySQLRow
    let connection: MDBConnection?
    let fixedRows: [MySQLRow]
    let lease: MySQLStreamLease?

    init(connection: MDBConnection, lease: MySQLStreamLease) {
        self.connection = connection
        self.lease = lease
        fixedRows = []
    }

    /// A stream of rows already in memory (tests, previews).
    public init(rows: [MySQLRow]) {
        connection = nil
        lease = nil
        fixedRows = rows
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(connection: connection, fixedRows: fixedRows, lease: lease) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: MDBConnection?
        var fixedRows: [MySQLRow]
        let lease: MySQLStreamLease?
        var columns: [MySQLColumn] = []
        var pending: [MDBRow] = []
        var index = 0

        public mutating func next() async throws -> MySQLRow? {
            guard let connection else {
                return fixedRows.isEmpty ? nil : fixedRows.removeFirst()
            }
            while true {
                if index < pending.count {
                    defer { index += 1 }
                    return MySQLRow(columns: columns, row: pending[index])
                }
                let event: MDBEvent?
                do {
                    event = try await connection.nextEvent(maxRows: 512)
                } catch {
                    await lease?.end()
                    throw MySQLError.from(error)
                }
                switch event {
                case .none:
                    await lease?.end()
                    return nil
                case .columns(let fields)?: columns = fields.map(MySQLColumn.init)
                case .rows(let rows)?: pending = rows; index = 0
                case .done?: continue
                }
            }
        }
    }
}
