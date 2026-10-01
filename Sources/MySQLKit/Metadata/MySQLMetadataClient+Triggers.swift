import MySQLWire

public extension MySQLMetadataClient {
    func listTriggers(in schema: String? = nil) async throws -> [MySQLTriggerInfo] {
        guard let schemaName = try await resolvedSchemaName(schema) else { return [] }

        let sql = """
        SELECT
            trigger_schema,
            trigger_name,
            event_object_table,
            action_timing,
            event_manipulation,
            action_statement
        FROM information_schema.triggers
        WHERE trigger_schema = ?
        ORDER BY trigger_name;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: [MySQLData(string: schemaName)])
        return result.rows.compactMap { row in
            guard
                let schema = row.field("trigger_schema")?.string,
                let name = row.field("trigger_name")?.string,
                let table = row.field("event_object_table")?.string,
                let timing = row.field("action_timing")?.string,
                let event = row.field("event_manipulation")?.string
            else { return nil }

            return MySQLTriggerInfo(
                schema: schema,
                name: name,
                table: table,
                timing: timing,
                event: event,
                statement: row.field("action_statement")?.string
            )
        }
    }
}
