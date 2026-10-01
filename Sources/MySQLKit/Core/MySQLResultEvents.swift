import Foundation
import MDBConnector

/// A warning or note the server raised for a statement (`SHOW WARNINGS`).
public struct MySQLWarning: Sendable, Equatable {
    /// `Warning`, `Note` or `Error`.
    public let level: String
    public let code: Int
    public let message: String

    public init(level: String, code: Int, message: String) {
        self.level = level
        self.code = code
        self.message = message
    }
}

/// What running SQL produced, in order: each result set's columns and rows, each statement's
/// end, and the warnings of the last statement.
public enum MySQLResultEvent: Sendable {
    case columns([MySQLColumn])
    case rows([MySQLRow])
    /// A statement finished: rows affected (or returned), insert id, warning count, info text.
    case done(MySQLWireQueryMetadata, returnedRows: Bool)
    case warnings([MySQLWarning])
}

/// The events of SQL run on one connection, read from the server as they are asked for.
public struct MySQLResultEvents: AsyncSequence, Sendable {
    public typealias Element = MySQLResultEvent
    let connection: MDBConnection
    let batchSize: Int
    let leaseHolder: MySQLStreamLeaseHolder

    init(connection: MDBConnection, batchSize: Int, lease: MySQLStreamLease) {
        self.connection = connection
        self.batchSize = batchSize
        leaseHolder = MySQLStreamLeaseHolder(lease)
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(connection: connection, batchSize: batchSize, lease: leaseHolder.take()) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: MDBConnection
        let batchSize: Int
        let lease: MySQLStreamLease?
        var columns: [MySQLColumn] = []
        var pendingWarnings = 0
        var held: MDBEvent?
        var finished = false

        public mutating func next() async throws -> MySQLResultEvent? {
            guard !finished else { return nil }
            do {
                let event: MDBEvent?
                if let held { event = held; self.held = nil } else { event = try await connection.nextEvent(maxRows: batchSize) }
                guard let event else {
                    finished = true
                    defer { Task { [lease] in await lease?.end() } }
                    // SHOW WARNINGS answers for the last statement, once its batch is over.
                    if pendingWarnings > 0 { return .warnings(try await warnings()) }
                    return nil
                }
                switch event {
                case .columns(let fields):
                    columns = fields.map(MySQLColumn.init)
                    pendingWarnings = 0
                    return .columns(columns)
                case .rows(let rows):
                    let columns = self.columns
                    return .rows(rows.map { MySQLRow(columns: columns, row: $0) })
                case .done(let result):
                    pendingWarnings = Int(result.warningCount)
                    var metadata = MySQLWireQueryMetadata(affectedRows: result.affectedRows, lastInsertID: result.insertID == 0 ? nil : result.insertID)
                    metadata.warningCount = result.warningCount
                    metadata.info = result.info
                    return .done(metadata, returnedRows: result.returnedRows)
                }
            } catch {
                finished = true
                await lease?.end()
                throw MySQLError.from(error)
            }
        }

        private func warnings() async throws -> [MySQLWarning] {
            let events = try await connection.execute("SHOW WARNINGS")
            return events.compactMap { if case .rows(let rows) = $0 { rows } else { nil } }.flatMap { $0 }.map { row in
                MySQLWarning(level: row.string(0) ?? "Warning", code: Int(row.string(1) ?? "") ?? 0, message: row.string(2) ?? "")
            }
        }
    }
}

extension MySQLWireConnection {
    /// Runs SQL (several statements allowed) and returns its events, pulled from the server.
    public func events(_ sql: String, batchSize: Int = 512) async throws -> MySQLResultEvents {
        await acquire()
        do {
            if await connection.isBusy { await connection.drain() }
            guard await connection.isOpen else { throw MySQLWireError.connectionAlreadyClosed }
            try await connection.send(sql)
        } catch {
            release()
            throw MySQLError.from(error)
        }
        return MySQLResultEvents(connection: connection, batchSize: batchSize, lease: streamLease())
    }
}
