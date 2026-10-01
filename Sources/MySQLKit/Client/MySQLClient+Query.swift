
public extension MySQLClient {
    func simpleQuery(_ sql: String) async throws -> [MySQLRow] {
        let connection = try await serverConnection.primary()
        return try await connection.simpleQuery(sql)
    }

    func query(_ sql: String, binds: [MySQLData] = []) async throws -> MySQLWireQueryResult {
        try await prepared.query(sql, binds: binds)
    }

    func stream(_ sql: String) async throws -> MySQLRowStream {
        let connection = try await serverConnection.primary()
        return try await connection.stream(sql)
    }

    var prepared: MySQLPreparedStatementClient {
        MySQLPreparedStatementClient(serverConnection: serverConnection)
    }
}
