import Foundation

public extension MySQLClient {
    /// Runs SQL on the primary connection and returns its events (columns, rows in batches, each
    /// statement's end, the last statement's warnings), pulled from the server as read.
    func events(_ sql: String, batchSize: Int = 512) async throws -> MySQLResultEvents {
        guard let connection = try await serverConnection.primary() as? MySQLWireConnection else {
            throw MySQLWireError.connectionAlreadyClosed
        }
        return try await connection.events(sql, batchSize: batchSize)
    }

    /// Stops what the primary connection is running (`KILL QUERY` over a short connection of its
    /// own). The statement ends early; the connection stays usable.
    func cancelRunningStatement() async throws {
        let id = await (try serverConnection.primary()).threadID
        guard id > 0 else { return }
        try await serverConnection.cancelQuery(threadID: UInt32(truncatingIfNeeded: id))
    }

    /// Force Stop: closes the primary connection while its statement runs (for a server that
    /// doesn't answer `KILL QUERY`). Returns whether a connection was closed, and whether a
    /// transaction was open on it (the server rolls it back).
    func closeRunningConnection() async -> (closed: Bool, transactionWasOpen: Bool) {
        await serverConnection.closePrimary()
    }

    /// Whether a transaction is open on the primary connection (as of its last statement); never
    /// opens a connection.
    var isInTransaction: Bool {
        get async { await serverConnection.primaryIsInTransaction() }
    }
}
