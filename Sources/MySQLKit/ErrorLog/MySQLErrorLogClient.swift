
public struct MySQLErrorLogClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func logDestinations() async throws -> [MySQLLogDestination] {
        let variables = try await MySQLServerConfigClient(serverConnection: serverConnection).globalVariables()
        let targetNames = ["log_error", "slow_query_log_file", "general_log_file", "log_output"]
        return variables
            .filter { targetNames.contains($0.name.lowercased()) }
            .map { MySQLLogDestination(kind: $0.name, value: $0.value) }
    }

    /// Newest first: the general log orders by `event_time`, the slow log by `start_time`.
    static func tableLogSQL(named tableName: String, limit: Int) -> String {
        let order = tableName == "slow_log" ? "start_time" : "event_time"
        return "SELECT * FROM mysql.`\(tableName.replacingOccurrences(of: "`", with: "``"))` ORDER BY \(order) DESC LIMIT \(max(0, limit))"
    }

    public func readTableLog(named tableName: String, limit: Int = 100) async throws -> [[String: String?]] {
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery(Self.tableLogSQL(named: tableName, limit: limit))
        return rows.map { row in
            Dictionary(uniqueKeysWithValues: row.columnDefinitions.map { column in
                (column.name, row.column(column.name)?.string)
            })
        }
    }
}
