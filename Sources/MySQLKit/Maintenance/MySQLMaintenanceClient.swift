
public struct MySQLMaintenanceClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func analyzeTable(schema: String, table: String) async throws -> MySQLMaintenanceResult {
        try await maintenanceResult(
            operation: "ANALYZE TABLE",
            sql: "ANALYZE TABLE `\(escapedIdentifier(schema))`.`\(escapedIdentifier(table))`"
        )
    }

    public func optimizeTable(schema: String, table: String) async throws -> MySQLMaintenanceResult {
        try await maintenanceResult(
            operation: "OPTIMIZE TABLE",
            sql: "OPTIMIZE TABLE `\(escapedIdentifier(schema))`.`\(escapedIdentifier(table))`"
        )
    }

    public func checkTable(schema: String, table: String) async throws -> MySQLMaintenanceResult {
        try await maintenanceResult(
            operation: "CHECK TABLE",
            sql: "CHECK TABLE `\(escapedIdentifier(schema))`.`\(escapedIdentifier(table))`"
        )
    }

    public func checkTables(schema: String, tables: [String]) async throws -> MySQLMaintenanceResult {
        guard !tables.isEmpty else {
            return MySQLMaintenanceResult(operation: "CHECK TABLE", messages: ["No tables specified."])
        }

        let qualified = tables.map { "`\(escapedIdentifier(schema))`.`\(escapedIdentifier($0))`" }
            .joined(separator: ", ")
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("CHECK TABLE \(qualified)")
        let messages = rows.compactMap { row in
            row.field("Msg_text")?.string ?? row.field("msg_text")?.string
        }
        return MySQLMaintenanceResult(operation: "CHECK TABLE", messages: messages)
    }

    public func repairTable(schema: String, table: String) async throws -> MySQLMaintenanceResult {
        let connection = try await serverConnection.primary()
        let sql = "REPAIR TABLE `\(escapedIdentifier(schema))`.`\(escapedIdentifier(table))`"
        let rows = try await connection.simpleQuery(sql)
        let messages = rows.compactMap { row in
            row.field("Msg_text")?.string ?? row.field("msg_text")?.string
        }
        return MySQLMaintenanceResult(operation: "REPAIR TABLE", messages: messages)
    }

    public func flushTables() async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("FLUSH TABLES")
    }

    private func maintenanceResult(operation: String, sql: String) async throws -> MySQLMaintenanceResult {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery(sql)
        let messages = rows.compactMap { row in
            row.field("Msg_text")?.string ?? row.field("msg_text")?.string
        }
        return MySQLMaintenanceResult(operation: operation, messages: messages)
    }

    func escapedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "``")
    }
}
