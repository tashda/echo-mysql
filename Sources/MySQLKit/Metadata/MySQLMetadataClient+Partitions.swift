
/// A partition of a partitioned table (`information_schema.PARTITIONS`).
public struct MySQLPartitionInfo: Sendable, Hashable {
    public let name: String
    /// `RANGE`, `RANGE COLUMNS`, `LIST`, `HASH`, `KEY`, …
    public let method: String
    public let expression: String?
    /// The bound: `2025`, `MAXVALUE`, `1,2`.
    public let description: String?
    public let ordinalPosition: Int
    /// InnoDB's estimate.
    public let estimatedRows: Int
}

public extension MySQLMetadataClient {
    func listPartitions(schema: String, table: String) async throws -> [MySQLPartitionInfo] {
        let connection = try await serverConnection.metadata()
        let result = try await connection.query("""
            SELECT PARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, PARTITION_ORDINAL_POSITION, TABLE_ROWS
            FROM information_schema.PARTITIONS
            WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND PARTITION_NAME IS NOT NULL
            ORDER BY PARTITION_ORDINAL_POSITION
            """, binds: [MySQLData(string: schema), MySQLData(string: table)])
        return result.rows.compactMap { row in
            guard let name = row.field("PARTITION_NAME")?.string else { return nil }
            return MySQLPartitionInfo(name: name, method: row.field("PARTITION_METHOD")?.string ?? "",
                                      expression: row.field("PARTITION_EXPRESSION")?.string,
                                      description: row.field("PARTITION_DESCRIPTION")?.string,
                                      ordinalPosition: row.field("PARTITION_ORDINAL_POSITION")?.int ?? 0,
                                      estimatedRows: row.field("TABLE_ROWS")?.int ?? 0)
        }
    }

    /// Sequences in a schema (MariaDB 10.3+).
    func listSequences(schema: String) async throws -> [String] {
        try await tableNames(schema: schema, type: "SEQUENCE")
    }

    /// System-versioned tables in a schema (MariaDB).
    func listSystemVersionedTables(schema: String) async throws -> [String] {
        try await tableNames(schema: schema, type: "SYSTEM VERSIONED")
    }

    private func tableNames(schema: String, type: String) async throws -> [String] {
        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = ? ORDER BY TABLE_NAME",
            binds: [MySQLData(string: schema), MySQLData(string: type)])
        return result.rows.compactMap { $0.field("TABLE_NAME")?.string }
    }
}
