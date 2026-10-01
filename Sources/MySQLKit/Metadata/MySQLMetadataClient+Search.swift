import MySQLWire

public extension MySQLMetadataClient {
    func searchObjects(matching pattern: String, schema: String? = nil) async throws -> [MySQLMetadataSearchResult] {
        let predicate: String
        let binds: [MySQLData]

        if let schema, !schema.isEmpty {
            predicate = "AND object_schema = ?"
            binds = [MySQLData(string: pattern), MySQLData(string: pattern), MySQLData(string: pattern), MySQLData(string: schema)]
        } else {
            predicate = ""
            binds = [MySQLData(string: pattern), MySQLData(string: pattern), MySQLData(string: pattern)]
        }

        let sql = """
        SELECT object_schema, object_name, object_type
        FROM (
            SELECT table_schema AS object_schema, table_name AS object_name, table_type AS object_type
            FROM information_schema.tables
            WHERE table_name LIKE ?
            UNION ALL
            SELECT routine_schema AS object_schema, routine_name AS object_name, routine_type AS object_type
            FROM information_schema.routines
            WHERE routine_name LIKE ?
            UNION ALL
            SELECT trigger_schema AS object_schema, trigger_name AS object_name, 'TRIGGER' AS object_type
            FROM information_schema.triggers
            WHERE trigger_name LIKE ?
        ) matches
        WHERE 1 = 1
        \(predicate)
        ORDER BY object_schema, object_name;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: binds)
        return result.rows.compactMap { row in
            guard
                let schema = row.field("object_schema")?.string,
                let name = row.field("object_name")?.string,
                let kind = row.field("object_type")?.string
            else { return nil }

            return MySQLMetadataSearchResult(schema: schema, name: name, kind: kind)
        }
    }
}
