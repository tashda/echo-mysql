
public struct MySQLMetadataClient: Sendable {
    private static let systemDatabases: Set<String> = [
        "information_schema",
        "mysql",
        "performance_schema",
        "sys"
    ]

    let serverConnection: MySQLServerConnection

    public func listDatabases(includeSystem: Bool = false) async throws -> [String] {
        let connection = try await serverConnection.metadata()
        let rows = try await connection.simpleQuery("SHOW DATABASES")
        return rows.compactMap { row in
            row.field("Database")?.string
        }
        .filter { includeSystem || !Self.systemDatabases.contains($0.lowercased()) }
    }

    public func currentDatabase() async throws -> String? {
        let connection = try await serverConnection.primary()
        return try await connection.currentDatabase()
    }

    public func selectDatabase(_ database: String) async throws {
        let connection = try await serverConnection.primary()
        try await connection.changeDatabase(database)
    }

    func resolvedSchemaName(_ schema: String?) async throws -> String? {
        if let schema, !schema.isEmpty {
            return schema
        }
        return try await currentDatabase()
    }

    static func escapedIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "`", with: "``")
    }
}
