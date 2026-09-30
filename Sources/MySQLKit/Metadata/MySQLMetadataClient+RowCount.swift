import MySQLWire

public extension MySQLMetadataClient {
    /// The exact number of rows (`COUNT(*)`), unlike `information_schema.TABLES.TABLE_ROWS`, which
    /// InnoDB only estimates.
    func exactRowCount(schema: String, table: String) async throws -> Int {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery(
            "SELECT COUNT(*) AS row_count FROM `\(Self.escapedIdentifier(schema))`.`\(Self.escapedIdentifier(table))`"
        )
        return rows.first?.column("row_count")?.int ?? 0
    }
}
