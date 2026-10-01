
public extension MySQLMetadataClient {
    func tableOptions(for table: String, schema: String? = nil) async throws -> MySQLTableOptionsInfo? {
        guard let schemaName = try await resolvedSchemaName(schema) else {
            return nil
        }

        let sql = """
        SELECT
            engine,
            SUBSTRING_INDEX(table_collation, '_', 1) AS character_set_name,
            table_collation,
            auto_increment,
            row_format,
            table_comment,
            table_rows,
            data_length,
            index_length
        FROM information_schema.tables
        WHERE table_schema = ? AND table_name = ?;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            sql,
            binds: [
                MySQLData(string: schemaName),
                MySQLData(string: table)
            ]
        )
        guard let row = result.rows.first else {
            return nil
        }

        return MySQLTableOptionsInfo(
            engine: row.field("engine")?.string,
            characterSet: row.field("character_set_name")?.string,
            collation: row.field("table_collation")?.string,
            autoIncrement: row.field("auto_increment")?.string.flatMap(Int.init),
            rowFormat: row.field("row_format")?.string,
            comment: row.field("table_comment")?.string?.nilIfEmpty,
            estimatedRowCount: row.field("table_rows")?.string.flatMap(Int64.init),
            dataLength: row.field("data_length")?.string.flatMap(Int64.init),
            indexLength: row.field("index_length")?.string.flatMap(Int64.init)
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
