import MySQLWire

public extension MySQLMetadataClient {
    func listColumns(in table: String, schema: String? = nil) async throws -> [MySQLColumnInfo] {
        guard let schemaName = try await resolvedSchemaName(schema) else {
            return []
        }

        let sql = """
        SELECT
            column_name,
            data_type,
            column_type,
            is_nullable,
            column_key,
            character_maximum_length,
            column_default,
            generation_expression,
            extra,
            collation_name,
            character_set_name,
            column_comment,
            ordinal_position
        FROM information_schema.columns
        WHERE table_schema = ? AND table_name = ?
        ORDER BY ordinal_position;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            sql,
            binds: [
                MySQLData(string: schemaName),
                MySQLData(string: table)
            ]
        )
        return result.rows.compactMap { row in
            guard
                let name = row.field("column_name")?.string,
                let dataType = row.field("data_type")?.string,
                let nullable = row.field("is_nullable")?.string
            else {
                return nil
            }

            let key = row.field("column_key")?.string
            let maxLength = row.field("character_maximum_length")?.string.flatMap(Int.init)
            let fullDataType = row.field("column_type")?.string ?? dataType
            let generationExpression = row.field("generation_expression")?.string?.nilIfEmpty
            let extra = row.field("extra")?.string?.lowercased() ?? ""
            let ordinalPosition = row.field("ordinal_position")?.string.flatMap(Int.init) ?? 0

            return MySQLColumnInfo(
                name: name,
                dataType: dataType,
                fullDataType: fullDataType,
                isNullable: nullable.uppercased() != "NO",
                isPrimaryKey: key == "PRI",
                maxLength: maxLength,
                defaultValue: row.field("column_default")?.string,
                generationExpression: generationExpression,
                isAutoIncrement: extra.contains("auto_increment"),
                collation: row.field("collation_name")?.string,
                characterSet: row.field("character_set_name")?.string,
                comment: row.field("column_comment")?.string?.nilIfEmpty,
                ordinalPosition: ordinalPosition
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
