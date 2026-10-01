import MySQLWire

public extension MySQLMetadataClient {
    func listTablesAndViews(in schema: String? = nil) async throws -> [MySQLSchemaObject] {
        guard let schemaName = try await resolvedSchemaName(schema) else {
            return []
        }

        let sql = """
        SELECT
            table_name,
            table_type
        FROM information_schema.tables
        WHERE table_schema = ?
        ORDER BY table_name;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: [MySQLData(string: schemaName)])
        return result.rows.compactMap { row in
            guard
                let name = row.field("table_name")?.string,
                let tableType = row.field("table_type")?.string,
                let kind = MySQLSchemaObjectKind(tableType: tableType)
            else {
                return nil
            }

            return MySQLSchemaObject(name: name, schema: schemaName, kind: kind)
        }
    }

    func objectDefinition(
        named objectName: String,
        schema: String,
        kind: MySQLSchemaObjectKind
    ) async throws -> String {
        let escapedSchema = Self.escapedIdentifier(schema)
        let escapedName = Self.escapedIdentifier(objectName)
        let sql: String

        switch kind {
        case .table:
            sql = "SHOW CREATE TABLE `\(escapedSchema)`.`\(escapedName)`"
        case .view:
            sql = "SHOW CREATE VIEW `\(escapedSchema)`.`\(escapedName)`"
        case .function:
            sql = "SHOW CREATE FUNCTION `\(escapedName)`"
        case .procedure:
            sql = "SHOW CREATE PROCEDURE `\(escapedName)`"
        case .trigger:
            sql = "SHOW CREATE TRIGGER `\(escapedName)`"
        case .event:
            sql = "SHOW CREATE EVENT `\(escapedName)`"
        }

        let connection = try await serverConnection.metadata()
        let rows = try await connection.simpleQuery(sql)
        guard let row = rows.first else {
            return ""
        }

        for column in row.columnDefinitions.reversed() {
            if let value = row.column(column.name)?.string, !value.isEmpty {
                return value
            }
        }

        return ""
    }
}
