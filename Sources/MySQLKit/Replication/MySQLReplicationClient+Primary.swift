public extension MySQLReplicationClient {
    /// The binary log position (`File`, `Position`, `Executed_Gtid_Set`, …); nil when the binary
    /// log is off.
    func primaryStatus() async throws -> MySQLReplicationStatus? {
        let sql = Self.primaryStatusSQL(flavor: try await serverFlavor())
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery(sql)
        guard let row = rows.first else { return nil }

        let values = Dictionary(uniqueKeysWithValues: row.columnDefinitions.map { column in
            (column.name, row.column(column.name)?.string)
        })
        return MySQLReplicationStatus(rawValues: values)
    }

    /// MySQL 8.2 renamed SHOW MASTER STATUS to SHOW BINARY LOG STATUS, and 8.4 removed the old name.
    /// An unreadable version is taken as a current MySQL.
    internal static func primaryStatusSQL(flavor: ServerFlavor) -> String {
        if flavor.isMariaDB { return "SHOW MASTER STATUS" }
        return flavor.major == 0 || (flavor.major, flavor.minor) >= (8, 2) ? "SHOW BINARY LOG STATUS" : "SHOW MASTER STATUS"
    }
}
