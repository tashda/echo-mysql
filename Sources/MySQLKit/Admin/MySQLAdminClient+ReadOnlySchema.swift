import MySQLWire

public extension MySQLAdminClient {
    /// Makes a schema read-only for everyone, root included (`ALTER SCHEMA … READ ONLY`, MySQL
    /// 8.0.22+; MariaDB has no such option).
    func setSchemaReadOnly(name: String, readOnly: Bool) async throws {
        try await executeDDL(Self.readOnlySchemaSQL(name: name, readOnly: readOnly))
    }

    internal static func readOnlySchemaSQL(name: String, readOnly: Bool) -> String {
        "ALTER SCHEMA `\(name.replacingOccurrences(of: "`", with: "``"))` READ ONLY = \(readOnly ? 1 : 0)"
    }
}

public extension MySQLMetadataClient {
    /// True when the schema was made read-only (`information_schema.SCHEMATA_EXTENSIONS`, MySQL 8.0.22+).
    func isSchemaReadOnly(name: String) async throws -> Bool {
        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            "SELECT OPTIONS FROM information_schema.SCHEMATA_EXTENSIONS WHERE SCHEMA_NAME = ?", binds: [MySQLData(string: name)])
        return result.rows.first?.field("OPTIONS")?.string?.contains("READ ONLY=1") == true
    }
}
