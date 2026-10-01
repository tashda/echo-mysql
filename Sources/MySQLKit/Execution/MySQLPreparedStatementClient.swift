import Foundation
import MySQLWire

/// Statements with bound parameters, through MySQL's binary protocol (COM_STMT_PREPARE and
/// COM_STMT_EXECUTE): the server receives the values typed and separate from the SQL, so nothing
/// is quoted or escaped on the client and concurrent callers cannot see each other's values.
public struct MySQLPreparedStatementClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func query(_ sql: String, binds: [MySQLData]) async throws -> MySQLWireQueryResult {
        await serverConnection.recordPreparedStatement(sql)
        let connection = try await serverConnection.primary()
        return try await connection.query(sql, binds: binds)
    }
}
