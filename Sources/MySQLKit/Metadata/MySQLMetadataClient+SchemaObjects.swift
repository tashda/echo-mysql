
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
        let qualified = "`\(Self.escapedIdentifier(schema))`.`\(Self.escapedIdentifier(objectName))`"
        // Every object is named with its schema: the metadata connection has no current database.
        let (sql, definitionColumn): (String, String) = switch kind {
        case .table: ("SHOW CREATE TABLE \(qualified)", "Create Table")
        case .view: ("SHOW CREATE VIEW \(qualified)", "Create View")
        case .function: ("SHOW CREATE FUNCTION \(qualified)", "Create Function")
        case .procedure: ("SHOW CREATE PROCEDURE \(qualified)", "Create Procedure")
        case .trigger: ("SHOW CREATE TRIGGER \(qualified)", "SQL Original Statement")
        case .event: ("SHOW CREATE EVENT \(qualified)", "Create Event")
        }

        let connection = try await serverConnection.metadata()
        let rows = try await connection.simpleQuery(sql)
        // The row also has the name, sql_mode, character sets and collations: read the definition by name.
        return rows.first?.field(definitionColumn)?.string ?? ""
    }
}
