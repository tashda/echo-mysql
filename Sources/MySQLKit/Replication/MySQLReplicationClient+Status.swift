public extension MySQLReplicationClient {
    /// The replica's state (`SHOW REPLICA STATUS`); nil when the server replicates from nothing.
    func replicaStatus() async throws -> MySQLReplicationStatus? {
        let sql = Self.replicaStatusSQL(flavor: try await serverFlavor())
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery(sql)
        guard let row = rows.first else { return nil }

        let values = Dictionary(uniqueKeysWithValues: row.columnDefinitions.map { column in
            (column.name, row.column(column.name)?.string)
        })
        return MySQLReplicationStatus(rawValues: values)
    }

    /// SHOW REPLICA STATUS from MySQL 8.0.22 and MariaDB 10.5.1; SHOW SLAVE STATUS before.
    internal static func replicaStatusSQL(flavor: ServerFlavor) -> String {
        let replica = flavor.isMariaDB ? (flavor.major, flavor.minor, flavor.patch) >= (10, 5, 1)
                                       : (flavor.major, flavor.minor, flavor.patch) >= (8, 0, 22)
        return replica || flavor.major == 0 ? "SHOW REPLICA STATUS" : "SHOW SLAVE STATUS"
    }
}
